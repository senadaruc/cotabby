import Foundation

/// File overview:
/// Names the open conversation in chat apps whose window title never changes between chats, so
/// per-window choices (Autocomplete, Translate) and the translation language memory can follow the
/// chat rather than the whole app. WhatsApp's window is always titled "WhatsApp"; the open chat's
/// name is the title of its navigation-bar header button (`NavigationBar_HeaderViewButton`, measured
/// 2026-10-02: "Ayse Cagin Kocaman", "Dominique Meurisse").
///
/// Pure: which element names the chat, and how its text is cleaned. The bounded Accessibility read
/// lives in `AXHelper.titleOfElement(withIdentifier:near:)`.
nonisolated enum ConversationHeaderPolicy {
    private static let headerIdentifiers: [String: String] = [
        "net.whatsapp.WhatsApp": "NavigationBar_HeaderViewButton"
    ]

    /// The `AXIdentifier` of the element whose title names the open chat, for apps that have one.
    static func headerIdentifier(forBundleIdentifier bundleIdentifier: String?) -> String? {
        bundleIdentifier.flatMap { headerIdentifiers[$0] }
    }

    /// The chat name without the bidirectional marks WhatsApp wraps its strings in (U+200E before
    /// "WhatsApp"), so one chat always yields the same key; nil when nothing readable is left.
    static func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bidiMarks: Set<Unicode.Scalar> = [
            "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"
        ]
        let scalars = raw.unicodeScalars.filter { !bidiMarks.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
