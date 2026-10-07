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
