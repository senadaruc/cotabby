import Foundation

/// File overview:
/// Turns a model's raw rewrite into text that can replace the selection, or rejects it. Strips the
/// wrappers models add (a preface such as "Here is the rewritten text:", a code fence, quotes
/// around the whole answer), keeps the selection's own leading and trailing whitespace so a
/// replaced line keeps its spacing, and refuses empty output or output too long to be a rewrite.
nonisolated enum RewriteOutputCleaner {
    /// A rewrite at most this many times the selection's length; Shorter may not grow at all.
    static let maximumGrowth = 3

    static func clean(_ raw: String, selection: String, action: RewriteAction) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripCodeFence(text)
        // A preface is a wrapper the model added. When the user's own selection opens the same way
        // ("Here is my address: ..."), the model may be echoing it, so the opening stays.
        if case .translate = action {
            // A translation's selection is in another language, so "selection opens the same way" can
            // never protect real text; translations use the stricter pattern below instead.
            text = stripTranslatePreface(text)
        } else if !startsWithPreface(selection.trimmingCharacters(in: .whitespacesAndNewlines)) {
            text = stripPreface(text)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !startsWithQuote(selection.trimmingCharacters(in: .whitespacesAndNewlines)) {
            text = stripWrappingQuotes(text)
        }
        guard !text.isEmpty else { return nil }
        let core = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit: Int
        switch action {
        case .shorter: limit = core.count
        // Longer expands a short draft into a full message, so a few words may become a paragraph.
        case .longer: limit = core.count * 8 + 400
        // A 3-character Chinese selection can become a 25-character English sentence, so translations
        // are not held to the 3x rewrite rule.
        case .translate: limit = core.count * 4 + 80
        default: limit = core.count * maximumGrowth + 40
        }
        guard text.count <= limit else { return nil }
        let leading = String(selection.prefix(while: { $0.isWhitespace }))
        let trailing = String(selection.reversed().prefix(while: { $0.isWhitespace }).reversed())
        return leading + text + trailing
    }

    /// Cuts the output at the first stop sequence it contains. The in-process llama runtime stops
    /// decoding once the text *contains* a stop sequence but hands back the text with that sequence
    /// still on the end, so a base-model translation came through as "…delivery person\n\nDraft"
    /// and the strip showed a stray "Draft" line. Servers (llama-server, Ollama, MLX) exclude the
    /// stop themselves; running this on their output is a no-op.
    static func cutAtStopSequence(_ text: String, stops: [String]) -> String {
        var cut = text
        for stop in stops {
            if let range = cut.range(of: stop) { cut = String(cut[..<range.lowerBound]) }
        }
        return cut
    }

    private static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// "Here is…:", "Here's a friendlier version:", "Sure! …:", "Rewritten text:", "Rewritten:",
    /// "Translation:", "Translated text:".
    /// Anchored at the start, so only an opening preface matches.
    private static let prefacePattern = #"^(?:(?:sure|certainly|of course)[!.,]?\s*)?(?:here(?:'s| is)[^:\n]{0,60}:|rewritten(?: text| version)?:|translation(?: text)?:|translated text:)\s*"#

    /// The translate-only pattern. Bare labels ("Translation:", "Translated text:") are never part of a
    /// translated sentence, so they go with or without a newline. Sentence-like prefaces ("Here is the
    /// translation:") go only when they end their own line: "Here's what happened: the server crashed."
    /// and "Here is the link: https://example.com" are legitimate translations of a German sentence.
    /// Tradeoff: a one-line "Here is the translation: Hello there." is indistinguishable from a
    /// translated sentence that happens to start that way, so it is left as is.
    private static let translatePrefacePattern =
        #"^(?:(?:sure|certainly|of course)[!.,]?\s*)?"#
        + #"(?:(?:translation(?: text)?|translated text):\s*|here(?:'s| is)[^:\n]{0,60}:[ \t]*\n\s*)"#

    private static func stripTranslatePreface(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: translatePrefacePattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func stripPreface(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: prefacePattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Whether the (trimmed) selection itself opens with a preface-like phrase, using the same pattern.
    private static func startsWithPreface(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: prefacePattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("«", "»")]

    private static func startsWithQuote(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return quotePairs.contains { $0.0 == first }
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        guard let first = text.first, let last = text.last, text.count >= 2,
              quotePairs.contains(where: { $0.0 == first && $0.1 == last }) else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
