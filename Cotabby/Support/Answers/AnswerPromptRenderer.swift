import Foundation

/// File overview:
/// Builds the prompt that drafts the user's answer to a question from facts found in memory.
///
/// Two shapes, because the two on-device engines take instructions differently:
/// - Apple Intelligence (Foundation Models) has a real instructions channel, so it gets a task:
///   draft the reply using only the listed facts, in the question's language, briefly, and say
///   `NONE` when the facts do not answer it. Autocomplete's own instructions forbid replying to
///   anyone, so drafting uses this separate set (and therefore its own session).
/// - The local llama models are base models: they continue documents and do not follow commands.
///   They get a document that ends where the user's reply begins: dated, attributed facts, then the
///   question as the last line of a transcript, then `You:`. Decoding stops at the next speaker's
///   label (`stopSequences`).
///
/// Facts are bounded (count and characters) so the prompt stays small and fast.
nonisolated enum AnswerPromptRenderer {
    struct Fact: Equatable, Sendable {
        let sender: String
        let isFromMe: Bool
        let conversationTitle: String
        let timestamp: Date
        let text: String
    }

    static let maximumFacts = 6
    static let maximumFactCharacters = 320
    static let maximumAnswerWords = 60
    /// What Apple Intelligence answers when the facts do not answer the question.
    static let abstainMarker = "NONE"

    static let appleInstructions = """
    You draft a short reply that the user will send to someone who asked them a question.
    Use only the facts listed in the prompt; they are messages from the user's own mail and chats.
    Answer in the same language as the question, as the user, in the first person, plainly and briefly \
    (at most \(maximumAnswerWords) words), with no greeting and no sign-off.
    Never invent names, numbers, dates or commitments that are not in the facts.
    If the facts do not answer the question, reply with exactly: \(abstainMarker)
    """

    static func applePrompt(question: String, asker: String?, facts: [Fact]) -> String {
        var lines = ["Facts:"]
        lines += factLines(facts).map { "- " + $0 }
        lines.append("")
        lines.append("\(asker ?? "Someone") asked: \(question)")
        lines.append("Draft the user's reply.")
        return lines.joined(separator: "\n")
    }

    /// The base-model document: facts, then a transcript whose last turn is the user's.
    static func basePrompt(question: String, asker: String?, facts: [Fact]) -> String {
        var lines = ["Notes from earlier messages:"]
        lines += factLines(facts)
        lines.append("")
        lines.append("\(speaker(asker)): \(question)")
        lines.append("You:")
        return lines.joined(separator: "\n")
    }

    /// Where a base model's reply ends: the next speaker, a blank line, or another notes block.
    static func stopSequences(asker: String?) -> [String] {
        ["\n\n", "\n\(speaker(asker)):", "\nYou:", "\nNotes from"]
    }

    /// The model's output reduced to the reply itself: cut at the first stop sequence, labels and
    /// quotes removed, nil for an abstention or nothing usable.
    static func cleanedAnswer(_ raw: String, asker: String?) -> String? {
        var text = raw
        for stop in stopSequences(asker: asker) {
            if let range = text.range(of: stop) { text = String(text[..<range.lowerBound]) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["You:", "Reply:", "Answer:", "Yanıt:", "Cevap:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        if text.count >= 2, text.first == "\"", text.last == "\"" { text = String(text.dropFirst().dropLast()) }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, !text.uppercased().hasPrefix(abstainMarker) else { return nil }
        if words.count > maximumAnswerWords * 2 { return nil }  // Rambling, not a reply.
        return text
    }

    static func factLines(_ facts: [Fact], calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return facts.prefix(maximumFacts).map { fact in
            let text = fact.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            let clipped = text.count > maximumFactCharacters ? String(text.prefix(maximumFactCharacters)) + "…" : text
            let who = fact.isFromMe ? "You" : (fact.sender.isEmpty ? "Someone" : fact.sender)
            let place = fact.conversationTitle.isEmpty ? "" : " (\(fact.conversationTitle))"
            return "\(formatter.string(from: fact.timestamp)) · \(who)\(place): \(clipped)"
        }
    }

    private static func speaker(_ asker: String?) -> String {
        let name = asker?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Them" : name
    }
}

/// Whether a drafted answer may be shown.
///
/// An answer card puts words in the user's mouth to another person, so it must be supported by
/// what memory found: there has to be a fact relevant enough to the question, and every specific in
/// the draft (a number, a date, a proper name) must appear in those facts or in the question.
/// Anything else is the model guessing, and no answer is better than a confident wrong one.
nonisolated enum AnswerGroundingPolicy {
    /// Whether retrieval found something worth drafting from: the best fact's similarity reaches
    /// the user's threshold, or keyword search found an exact match for the question's words.
    static func shouldDraft(bestSimilarity: Double, minimumSimilarity: Double, hasKeywordMatch: Bool) -> Bool {
        bestSimilarity >= minimumSimilarity || hasKeywordMatch
    }

    /// The specifics of `draft` that neither the facts nor the question contain (empty = grounded).
    static func unsupportedSpecifics(in draft: String, facts: [String], question: String) -> [String] {
        let source = normalized(facts.joined(separator: " ") + " " + question)
        let sourceDigits = Set(numbers(in: facts.joined(separator: " ") + " " + question))
        var unsupported: [String] = []
        for number in numbers(in: draft) where !sourceDigits.contains(number) {
            unsupported.append(number)
        }
        for name in properNames(in: draft) where !source.contains(normalized(name)) {
            unsupported.append(name)
        }
        return unsupported
    }

    /// Digit runs with their separators removed ("4,000" → "4000", "3.5" → "35"), so a fact's
    /// "4.000 EUR" supports a draft's "4000".
    static func numbers(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"\d[\d.,:]*\d|\d"#) else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { text[$0].filter(\.isNumber) }
        }
    }

    /// Capitalized words that are not the first word of a sentence and not common sentence words:
    /// names of people, companies, places and products.
    static func properNames(in text: String) -> [String] {
        var names: [String] = []
        for sentence in QuestionDetector.sentences(text) {
            let words = sentence.split(whereSeparator: { $0.isWhitespace })
            for word in words.dropFirst() {
                let core = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                guard let first = core.first, first.isUppercase, core.count > 1,
                      !commonCapitalized.contains(core.lowercased()) else { continue }
                // The part before an apostrophe: Turkish suffixes ("Karaköy'de") follow names.
                names.append(String(core.split(separator: "'").first ?? Substring(core)))
            }
        }
        return names
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Words commonly capitalized mid-sentence that are not facts to verify.
    private static let commonCapitalized: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "ok", "okay", "pm", "am", "eur", "usd", "tl", "try",
    ]
}
