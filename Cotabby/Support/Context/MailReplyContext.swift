import Foundation

/// Pure rules for writing a reply in a mail app (Outlook, Mail, Spark, Airmail).
///
/// A reply is the one surface where the most relevant context sits *after* the caret: the quoted
/// thread being answered. Three parts of the pipeline treated a reply like any other field and
/// missed that thread:
/// - the prompt passed ~200 characters of text after the caret, which in a reply is only the quoted
///   header's From/Date/To lines, never what was said;
/// - conversation memory looked the thread up by the window title, and Outlook's inline reply lives
///   in its main window, titled "Inbox • All Accounts", so memory found nothing;
/// - the screen excerpt drops lines under the caret (the composer), which in a reply is the thread,
///   and kept the message list beside it, whose previews of other mail the model then copied.
///
/// The thread's own header names the conversation ("Subject: Re: AFAD Use Case 3"), and its text
/// already arrives through Accessibility as the field's trailing text, so these rules read both from
/// there; the header itself is parsed by `QuotedReplyParser`, which the answers feature shares. Kept pure so each rule is pinned by tests without AX, OCR or the memory engine.
nonisolated enum MailReplyContext {
    /// Characters after the caret a mail prompt carries: the quoted header plus the start of the
    /// message being answered. Other surfaces keep the configured default, where text after the
    /// caret is the rest of the user's own paragraph.
    static let trailingCharacters = 1500

    static func isMail(bundleIdentifier: String?) -> Bool {
        AppSurfaceClassifier.classify(bundleIdentifier: bundleIdentifier) == .email
    }

    /// The trailing-text budget for a field: `trailingCharacters` in a mail app, else the default.
    static func trailingBudget(bundleIdentifier: String?, defaultBudget: Int) -> Int {
        isMail(bundleIdentifier: bundleIdentifier) ? max(defaultBudget, trailingCharacters) : defaultBudget
    }

    // MARK: - The thread, as the prompt reads it

    /// Text after the caret as a mail prompt should carry it: the rest of the user's own draft, then
    /// each quoted message as "Sender: what they wrote", newest first. Raw, a quoted thread is mostly
    /// From/To/Cc lines with every address, signatures, phone numbers and footers; measured on a real
    /// Outlook reply, the 1500 characters held two sentences of actual message. A base model reads
    /// all of it as the passage it continues, so the noise displaced the words that matter and drew
    /// the completion toward boilerplate. Text with no quote header comes back unchanged.
    static func condensedThread(_ trailingText: String) -> String {
        guard let first = QuotedReplyParser.headerRange(in: trailingText) else { return trailingText }
        var parts: [String] = []
        let ownText = cleanedLines(trailingText[..<first.lowerBound])
        if !ownText.isEmpty { parts.append(ownText) }
        var rest = String(trailingText[first.lowerBound...])
        while parts.count <= maximumQuotedMessages, let header = QuotedReplyParser.headerRange(in: rest) {
            guard let message = QuotedReplyParser.quotedMessage(in: String(rest[header.lowerBound...])) else { break }
            let body = cleanedLines(Substring(message.body))
            if !body.isEmpty { parts.append("\(message.sender ?? "They"): \(String(body.prefix(maximumMessageCharacters)))") }
            // Continue after this header line; the next header found is the next, older message.
            rest = String(rest[header.upperBound...])
        }
        return parts.joined(separator: "\n\n")
    }

    static let maximumQuotedMessages = 4
    static let maximumMessageCharacters = 500

    /// The message's own lines, ending where its signature starts: at a closing ("Best regards",
    /// "Saygılarımla"), or, once the message has said something, at the first short line that is not
    /// a sentence ("ALTAY", "CO-FOUNDER, COO", "Arnaud"). Lines that are only contact details (an
    /// address, a link, a phone number) are dropped wherever they appear.
    private static func cleanedLines(_ text: Substring) -> String {
        var kept: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Blank lines and rules ("________") carry nothing.
            guard line.contains(where: \.isLetter) else { continue }
            let bare = line.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            if signOffs.contains(bare) { break }
            if isContactDetail(line) { continue }
            if kept.contains(where: isSentence), isSignatureLine(line) { break }
            kept.append(line)
        }
        return kept.joined(separator: " ")
    }

    /// A line that ends like a sentence or a salutation, or is a list item: message content.
    private static func isSentence(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return ".?!:,;؟".contains(last) || ["-", "•", "*"].contains(line.first.map(String.init) ?? "")
    }

    /// A name, a title or a label: a few words that do not form a sentence.
    private static func isSignatureLine(_ line: String) -> Bool {
        !isSentence(line) && line.split(whereSeparator: \.isWhitespace).count <= 4
    }

    private static func isContactDetail(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("@") || lower.contains("http") || lower.contains("www.") || lower.contains("linkedin") { return true }
        let digits = line.filter(\.isNumber).count
        return digits >= 7 && Double(digits) / Double(line.count) > 0.4
    }

    /// Closings after which a message's signature starts, in the user's mail languages.
    private static let signOffs: Set<String> = [
        "best regards", "kind regards", "warm regards", "regards", "best", "cheers", "thanks", "thank you",
        "many thanks", "sincerely", "yours sincerely", "met vriendelijke groet", "groeten",
        "saygılarımla", "saygılar", "iyi çalışmalar", "teşekkürler", "sevgiler",
    ]

    /// The subject of the message being replied to, from the quoted header after the caret
    /// ("Subject: Re: AFAD Use Case 3"). Nil when the field holds no Outlook-style header (a new
    /// message, or Mail's "On …, X wrote:" quote, whose compose window title already is the subject).
    static func quotedSubject(in trailingText: String) -> String? {
        QuotedReplyParser.quotedSubject(in: trailingText)
    }

    /// Outlook titles its main window after the open folder ("Inbox • All Accounts", "Sent Items •
    /// senad@imperum.io"). An inline reply there has no window of its own, so that title names a
    /// mailbox, not a conversation, and must not be matched against conversation titles.
    static func isMailboxWindowTitle(_ title: String, bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.lowercased() == "com.microsoft.outlook" && title.contains(" • ")
    }
}
