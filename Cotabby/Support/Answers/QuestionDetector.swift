import Foundation

/// File overview:
/// Decides whether a message someone sent the user asks them something, and which sentences ask it.
///
/// Why heuristics and not a model: this runs every time a reply field is focused, must cost nothing,
/// and its mistakes are cheap in one direction only (a missed question just means no card; a false
/// one means a card the user dismisses with a keystroke, and the grounding check usually drops it
/// anyway because memory holds no answer to a statement). It covers the user's two languages:
///
/// - English: a question mark; or, in a sentence without a closing period (chat style), an
///   interrogative opener ("what", "when", "can you", "do we", "any update on", …); or a request
///   ("let me know", "please confirm", "could you send").
/// - Turkish: a question mark; the question particles (`mı mi mu mü` and their personal forms,
///   written apart from the word as Turkish spelling requires); question words ("ne zaman",
///   "nerede", "nasıl", "kaç", …); or a request ("haber ver", "bilgi verir").
///
/// Returns the asking sentences (at most two, the latest ones), so the answer is drafted for what
/// was asked, not for the greeting around it.
nonisolated enum QuestionDetector {
    static let maximumSentences = 2

    static func question(in message: String) -> String? {
        let sentences = Self.sentences(message)
        let asking = sentences.filter(isQuestion)
        guard !asking.isEmpty else { return nil }
        return asking.suffix(maximumSentences).joined(separator: " ")
    }

    static func isQuestion(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        guard words.count >= 2 else { return false }
        if let last = trimmed.last, "?؟".contains(last) { return true }
        if trimmed.hasPrefix("¿") { return true }
        if words.contains(where: turkishParticles.contains) { return true }
        let text = " " + words.joined(separator: " ") + " "
        if turkishPhrases.contains(where: { text.contains(" \($0) ") }) { return true }
        if requestPhrases.contains(where: { text.contains(" \($0) ") }) { return true }
        // An English opener counts only without a closing period: "Can you send it" is a question
        // in chat, "Can is coming tomorrow." is a statement about Can.
        if !trimmed.hasSuffix("."), let first = words.first, englishOpeners.contains(first) {
            return !(first == "can" && words.count > 1 && !englishSubjects.contains(words[1]))
        }
        return false
    }

    /// Sentences, split after `.`, `!`, `?` and line breaks, keeping their punctuation.
    static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            if character.isNewline {
                sentences.append(current)
                current = ""
                continue
            }
            current.append(character)
            if ".!?؟".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)
        return sentences.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static let turkishParticles: Set<String> = [
        "mı", "mi", "mu", "mü",
        "mısın", "misin", "musun", "müsün", "mısınız", "misiniz", "musunuz", "müsünüz",
        "mıyız", "miyiz", "muyuz", "müyüz", "mıydı", "miydi", "muydu", "müydü",
        "mıdır", "midir", "mudur", "müdür", "mıyım", "miyim", "muyum", "müyüm",
    ]

    private static let turkishPhrases: [String] = [
        "ne zaman", "nerede", "nereye", "neden", "niye", "nasıl", "hangi", "kaç", "kim", "kime", "kimin",
        "ne oldu", "ne durumda", "haber ver", "haber verir", "bilgi ver", "bilgi verir", "bilgi verebilir",
        "dönüş yap", "dönüş yapabilir",
    ]

    private static let requestPhrases: [String] = [
        "let me know", "please confirm", "please advise", "please share", "please send", "please let",
        "could you", "can you", "would you", "will you", "do you know", "any update", "any news",
        "any idea", "any thoughts", "what about", "how about",
    ]

    private static let englishOpeners: Set<String> = [
        "what", "when", "where", "who", "whom", "whose", "why", "how", "which",
        "can", "could", "would", "will", "shall", "should", "do", "does", "did",
        "is", "are", "was", "were", "have", "has", "had", "may", "any",
    ]

    /// Words that follow "can" in a question ("can you", "can we"), as opposed to the name Can.
    private static let englishSubjects: Set<String> = ["i", "you", "we", "they", "he", "she", "it", "someone", "anyone", "this", "that", "the"]
}

/// Whether a reply field is still empty, for drafting an answer into it.
///
/// A chat composer is empty when it holds no text. A mail reply never is: below the caret sit the
/// user's signature and the quoted message being answered. So: nothing before the caret, and after
/// it only whitespace, or a short signature followed by the quote.
nonisolated enum ReplyFieldEmptiness {
    static let maximumSignatureLines = 8
    static let maximumSignatureCharacters = 400

    static func isEmpty(precedingText: String, trailingText: String) -> Bool {
        guard precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let trailing = trailingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trailing.isEmpty { return true }
        guard let headerStart = QuotedReplyParser.headerRange(in: trailing)?.lowerBound else { return false }
        let beforeQuote = trailing[..<headerStart].trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = beforeQuote.split(whereSeparator: \.isNewline)
        return lines.count <= maximumSignatureLines && beforeQuote.count <= maximumSignatureCharacters
    }
}
