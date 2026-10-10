import Foundation

/// Pure memory of the words Cotabby fixed automatically after Space, so a fix the user undid is not
/// applied again.
///
/// The reproduction: the user typed "cribl" (a product name) in LinkedIn's search box, Space turned it
/// into "crib", and they pressed Backspace, typed "l" and Space five times in a row; each time the
/// typo gate saw a fresh misspelling and replaced it again. A word that comes back at the very place
/// Cotabby just replaced it, in the same field, is the user's answer that the original was intended,
/// whether they retyped it, pressed Backspace into it, or used the host's Undo. The same misspelling
/// typed somewhere else ("teh" later in the same email) has different text before it and is still
/// fixed, which is why the position is part of the match rather than the word alone.
///
/// Owned by `SuggestionCoordinator` for the app's lifetime; it holds only the last few corrections
/// and never persists. What happens to a restored word (keeping it out of the typo gate) is
/// `CurrentWordSpellChecker.keepWord`'s job.
nonisolated struct AutomaticCorrectionRevertMemory {
    private struct Entry {
        let fieldKey: String
        let textBeforeWord: String
        let typo: String
    }

    /// Corrections remembered at once. A user undoes a fix right away or not at all, so a short
    /// list is enough and keeps lookups trivial.
    static let capacity = 8
    /// Text before the word compared at most this far back: enough to pin the position, bounded so
    /// a long draft does not cost a long comparison on every Space.
    private static let anchorLength = 256

    private var entries: [Entry] = []

    /// Records an automatic fix of `typo` in the field `fieldKey`, at the position `textBeforeWord`
    /// describes (everything before the replaced word).
    mutating func recordCorrection(of typo: String, textBeforeWord: String, fieldKey: String) {
        let anchor = String(textBeforeWord.suffix(Self.anchorLength))
        entries.removeAll { $0.fieldKey == fieldKey && $0.textBeforeWord == anchor }
        entries.append(Entry(fieldKey: fieldKey, textBeforeWord: anchor, typo: typo))
        entries = Array(entries.suffix(Self.capacity))
    }

    /// True when `word` is a typo Cotabby already fixed at this same position in this same field:
    /// the user brought it back.
    func isRestoration(of word: String, textBeforeWord: String, fieldKey: String) -> Bool {
        let anchor = String(textBeforeWord.suffix(Self.anchorLength))
        return entries.contains {
            $0.fieldKey == fieldKey && $0.typo == word && $0.textBeforeWord == anchor
        }
    }

    /// The text before `word` when `precedingText` ends with `word` followed by `delimiter`, or
    /// `nil` when it does not (a stale snapshot), so callers never compare against a wrong position.
    static func textBeforeWord(_ word: String, delimiter: String, in precedingText: String) -> String? {
        let committed = word + delimiter
        guard precedingText.hasSuffix(committed) else { return nil }
        return String(precedingText.dropLast(committed.count))
    }
}
