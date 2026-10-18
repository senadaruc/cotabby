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
    ///
    /// `fieldText` is the focused field's text. Its words are the user's own typing rendered on
    /// screen, so they are left out of the comparison: in a document or compose window the draft
    /// is most of the excerpt, and a few typed words otherwise read as a different screen. A screen
    /// word that is the start of a field word counts as typing too, because a capture can catch a
    /// word the user was still in the middle of.
    ///
    /// A different screen must also differ in content lines (`VisualContextChangePolicy`). A
    /// window whose excerpt is only its title bar and toolbar, such as TextEdit's, reads as a
    /// handful of short words, so one split or stray glyph ("BIUS" as "BI US") would otherwise
    /// cross the similarity threshold on every refresh.
    static func isMeaningfulChange(from previous: String?, to current: String, fieldText: String = "") -> Bool {
        guard let previous else { return true }
        if previous == current { return false }
        guard VisualContextChangePolicy.isMaterialChange(previous: previous, next: current, fieldText: fieldText) else {
            return false
        }
        let typed = typedWordPrefixes(fieldText)
        guard !typed.isEmpty else {
            return similarity(previous, current) < sameScreenSimilarity
        }
        return similarity(wordCounts(previous, excluding: typed), wordCounts(current, excluding: typed))
            < sameScreenSimilarity
    }

    /// Dice coefficient over the two word multisets: twice the shared word count over the total.
    /// A multiset (not a set) keeps repeated words meaningful, so a screen of short repeated
    /// tokens such as timestamps cannot look identical to a different one.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        similarity(wordCounts(lhs, excluding: []), wordCounts(rhs, excluding: []))
    }

    private static func similarity(_ left: [Substring: Int], _ right: [Substring: Int]) -> Double {
        let total = left.values.reduce(0, +) + right.values.reduce(0, +)
        guard total > 0 else { return 1 }
        let shared = left.reduce(0) { sum, entry in sum + min(entry.value, right[entry.key] ?? 0) }
        return Double(2 * shared) / Double(total)
    }

    /// Whitespace-separated words with their counts, leaving out the ones whose letters and digits
    /// are in `excluded`.
    private static func wordCounts(_ text: String, excluding excluded: Set<String>) -> [Substring: Int] {
        var counts: [Substring: Int] = [:]
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            if !excluded.isEmpty, excluded.contains(normalized(word)) { continue }
            counts[word, default: 0] += 1
        }
        return counts
    }

    /// Every prefix of two or more characters of the field's words. Single characters stay in the
    /// comparison: they are mostly OCR debris, which the threshold already absorbs.
    private static func typedWordPrefixes(_ fieldText: String) -> Set<String> {
        var prefixes: Set<String> = []
        for word in fieldText.split(whereSeparator: { $0.isWhitespace }) {
            let letters = normalized(word)
            guard letters.count >= 2 else { continue }
            var prefix = ""
            for character in letters {
                prefix.append(character)
                if prefix.count >= 2 { prefixes.insert(prefix) }
            }
        }
        return prefixes
    }

    /// Lowercased letters and digits, so `onboarding.` on screen matches `onboarding` typed.
    private static func normalized(_ word: Substring) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
