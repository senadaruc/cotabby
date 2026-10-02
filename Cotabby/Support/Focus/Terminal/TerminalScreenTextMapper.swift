import Foundation

/// File overview:
/// Turns a cursor found in a terminal's pixels into an offset in the terminal's Accessibility text.
///
/// Ghostty's text is its whole scrollback, one line per screen row (no line is longer than the grid's
/// columns, measured 2026-10-02), and the screen shows its last rows. The lowest inked row on screen
/// is therefore the last non-blank line of the text, and the cursor's line is that many rows above
/// it as the pixels show (`TerminalCursorDetector.Measurement.rowsFromCursorToLastInk`). Counting
/// rows from the bottom of the *text* instead was off by one in a live window: the screen keeps
/// blank rows at the bottom that the text does not end with.
///
/// Pure: the resolver reads the tail of the text and the tracker supplies the measurement.
nonisolated enum TerminalScreenTextMapper {
    /// The UTF-16 offset in `tail` of the cell `column` on the line `rowsAboveLastInk` lines above
    /// `tail`'s last non-blank line. The column is clamped to its line: the text drops a row's
    /// trailing blanks, so a cursor after typed spaces sits past the line's end. `nil` when that line
    /// is not wholly inside `tail` (its first line may have been cut mid-way) or the tail is blank.
    ///
    /// A column counts one UTF-16 unit per cell, exact for the single-width characters prompt lines
    /// are made of; wide glyphs (CJK, emoji) before the cursor put it a little off.
    static func caretOffset(in tail: String, rowsAboveLastInk: Int, column: Int) -> Int? {
        let lines = (tail as NSString).components(separatedBy: "\n")
        guard let lastInked = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        let cursorLine = lastInked - max(0, rowsAboveLastInk)
        guard cursorLine >= 1 else { return nil }
        let lineStart = lines[..<cursorLine].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let lineLength = (lines[cursorLine] as NSString).length
        return lineStart + min(max(0, column), lineLength)
    }
}
