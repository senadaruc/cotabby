import Foundation

/// Bounds what a terminal screen field (`TerminalAppDetector.isTerminalScreenField`) puts into the
/// prompt.
///
/// Such a field's text is the whole visible screen. Above the caret it scrolls whenever output
/// arrives (an agent printing while the user types); after the caret it is the input box's chrome
/// and the status lines below it, which redraw on their own. In Ghostty both changed on nearly every
/// keystroke, so each request re-decoded about 1,230 of its 1,525 prompt tokens and was cancelled by
/// the next key before any text appeared. The prompt therefore keeps only the last lines before the
/// caret, starting at a line so its start moves a line at a time rather than with every character,
/// and none of the text after the caret. The screen excerpt still carries the wider context.
nonisolated enum TerminalPromptWindow {
    /// Characters of screen text kept before the caret, about 150 tokens.
    static let maxPrecedingCharacters = 600

    /// The last `maxPrecedingCharacters` of `text`, cut forward to the start of a line.
    static func precedingText(_ text: String) -> String {
        guard text.count > maxPrecedingCharacters else { return text }
        let tail = text.suffix(maxPrecedingCharacters)
        guard let newline = tail.firstIndex(of: "\n") else { return String(tail) }
        return String(tail[tail.index(after: newline)...])
    }
}
