import Foundation

/// Pure decision on whether a refreshed screen excerpt shows a different screen or the same one.
///
/// `VisualContextCoordinator` re-reads the window every few seconds, and `SuggestionCoordinator`
/// treats changed screen text as a navigation signal (a host can expose the same URL, title and
/// geometry for two chats). OCR of the same window is not byte-stable, though: a busy window such
/// as Outlook's or Mail's came back 2261, 2259, 2268 and 2262 characters long on consecutive passes
/// with nothing on screen changing but a caret blink or a re-rendered glyph. Comparing the raw text
/// retired the visible suggestion on every pass. This compares the excerpts word by word instead,
/// so a reading jitter of a few words counts as the same screen and a switch to another
/// conversation, which replaces most of the text, still counts as a change.
///
/// Kept apart from the coordinator so the threshold is unit-testable without screenshots or timers.
nonisolated enum ScreenTextChangePolicy {
    /// Share of words two excerpts must have in common to be the same screen. A new conversation
    /// keeps only the window's chrome (sidebar, toolbar) and scores far below this; OCR jitter and
    /// one newly arrived message change a few words in hundreds and score far above it.
    static let sameScreenSimilarity = 0.9

    /// True when `current` shows a different screen than `previous`.
    ///
    /// A first excerpt for the field (`previous == nil`) is a change: the field had no screen text
    /// before, and the caller decides what a first reading means.
    static func isMeaningfulChange(from previous: String?, to current: String) -> Bool {
        guard let previous else { return true }
        if previous == current { return false }
        return similarity(previous, current) < sameScreenSimilarity
    }

    /// Dice coefficient over the two word multisets: twice the shared word count over the total.
    /// A multiset (not a set) keeps repeated words meaningful, so a screen of short repeated
    /// tokens such as timestamps cannot look identical to a different one.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = wordCounts(lhs)
        let right = wordCounts(rhs)
        let total = left.values.reduce(0, +) + right.values.reduce(0, +)
        guard total > 0 else { return 1 }
        let shared = left.reduce(0) { sum, entry in sum + min(entry.value, right[entry.key] ?? 0) }
        return Double(2 * shared) / Double(total)
    }

    private static func wordCounts(_ text: String) -> [Substring: Int] {
        var counts: [Substring: Int] = [:]
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            counts[word, default: 0] += 1
        }
        return counts
    }
}
