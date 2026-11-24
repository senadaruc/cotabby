import Foundation

/// File overview:
/// Recovers the body of one WhatsApp message from the accessibility sentence the WhatsApp Mac app (a
/// Catalyst app, `net.whatsapp.WhatsApp`) gives each chat bubble. WhatsApp exposes no text selection
/// through Accessibility at all: no element answers `kAXSelectedText`, a selected range or a text marker
/// range, so Translate on Select cannot read what the user dragged across. What it does expose is the
/// bubble itself, an `AXStaticText` whose `AXValue` is empty and whose `AXDescription` is one sentence
/// written for VoiceOver. `ReadOnlySelectionReader` finds the bubble under the pointer and hands that
/// sentence here, and the whole message is translated (partial selection is not recoverable).
///
/// Measured shapes (English UI; the words are localised, so nothing below keys on them):
///
/// - Plain incoming bubble, one line:
///   `‎Message from ‎<sender>, <body>, <24 November at 10:19>, ‎Received in <chat>`
/// - Reply bubble, four lines: `‎Replying to ‎<name>.`, then the plain sentence above (holding the
///   reply's own body, ending in "."), then `‎Quoted message.`, then the quoted text.
///
/// The `‎` above is U+200E LEFT-TO-RIGHT MARK (confirmed by code point in a live probe). WhatsApp puts
/// one in front of the prefix, the sender and every trailing status field, never in front of the body
/// or the timestamp, so the marks are the language-independent field markers this parser relies on:
///
/// 1. Find the sentence: a line that starts with a mark, runs through any continuation lines that do
///    not (a multi-line body), and ends on a line whose last ", " field starts with a mark. The reply
///    header and the "quoted message" label hold no ", " field, and the quoted text does not start
///    with a mark, so neither is mistaken for it.
/// 2. Split it on ", ". The first field is the "message from"/"your message" prefix. Every trailing
///    field that starts with a mark (received in, sent to, read) is dropped, then a "." left on the last
///    field. The last remaining field is the timestamp and is dropped only when it holds a digit, a
///    guard against a shape without a timestamp losing the end of its body.
/// 3. The rest, re-joined with ", " (bodies contain commas), is the body, with any marks inside it
///    removed.
///
/// Not yet sampled live and therefore guessed: the user's own outgoing bubbles (assumed to be
/// `‎Your message, <body>, <date>, ‎Sent to <chat>, ‎Read`), 1:1 chats, media, voice and sticker
/// bubbles, multi-line bodies, and UI languages other than English. Any sentence that does not fit
/// the shape yields nil by design: nil means no strip, the safe failure, while a wrong guess would
/// translate a sender name or a date as if it were the message. Pure and deterministic.
nonisolated enum WhatsAppMessageDescriptionParser {
    /// The separator between the sentence's fields. A body containing ", " is re-joined with it.
    static let fieldSeparator = ", "

    /// The body of the message the description describes, or nil when the description does not have
    /// the measured sentence shape.
    static func messageBody(fromDescription description: String) -> String? {
        guard let sentence = sentence(in: description) else { return nil }
        var fields = sentence.components(separatedBy: fieldSeparator)
        // `count > 1` keeps the prefix, which starts with a mark as well.
        while fields.count > 1, let last = fields.last, startsWithMarker(last) {
            fields.removeLast()
        }
        guard fields.count >= 2 else { return nil }
        if fields[fields.count - 1].hasSuffix(".") {
            fields[fields.count - 1].removeLast()
        }
        if fields[fields.count - 1].contains(where: \.isNumber) {
            fields.removeLast()
        }
        guard fields.count >= 2 else { return nil }
        let body = String(fields.dropFirst().joined(separator: fieldSeparator).unicodeScalars.filter { !isFieldMarker($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// True for the invisible bidirectional marks and embeddings WhatsApp (or another locale's build
    /// of it) uses to start a field: LRM and RLM, the LRE/RLE/PDF/LRO/RLO embeddings, and the
    /// LRI/RLI/FSI/PDI isolates.
    static func isFieldMarker(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// The message sentence inside a possibly multi-line description, its lines re-joined with "\n".
    /// Lines are split on any newline (`Character.isNewline` treats "\r\n" as one), and leading and
    /// trailing spaces are ignored so a stray space cannot hide a leading mark.
    private static func sentence(in description: String) -> String? {
        let lines = description
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for start in lines.indices where startsWithMarker(lines[start]) && lines[start].contains(fieldSeparator) {
            var end = start
            while true {
                // On the start line the last field is never the prefix (the line holds a separator);
                // a continuation line does not start with a mark, so without a separator it never closes.
                if let last = lines[end].components(separatedBy: fieldSeparator).last, startsWithMarker(last) {
                    return lines[start...end].joined(separator: "\n")
                }
                end += 1
                // A line starting with a mark begins a new sentence or label (the "quoted message"
                // line), so the sentence that started at `start` never closed: try the next start.
                guard end < lines.count, !startsWithMarker(lines[end]) else { break }
            }
        }
        return nil
    }

    private static func startsWithMarker(_ text: String) -> Bool {
        text.unicodeScalars.first.map(isFieldMarker) ?? false
    }
}
