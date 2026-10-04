import Foundation

/// File overview:
/// Pure rules for conversation memory on the Swift side: which conversation the focused field
/// belongs to, what to search memory for, and how retrieved messages read in a prompt.
///
/// Why pure and separate: these decide what private history may reach a prompt, so each rule is
/// stated once here, without AppKit, the socket or the service, and pinned by tests. The retriever
/// (`MemoryRetriever`) only applies them.

/// The conversation a field belongs to: what memory's search is scoped to.
nonisolated struct ConversationScope: Equatable, Hashable, Sendable {
    /// The chat name or mail subject as the app shows it; memory matches it within `sources`.
    let title: String
    /// The memory sources that serve the focused app (`whatsapp` for WhatsApp, `apple_mail` for
    /// Mail). Title matching never crosses into other apps' history.
    let sources: [String]

}

nonisolated enum ConversationScopeResolver {
    /// The scope for a focused field, or nil when memory has nothing to say about it: the app has no
    /// enabled memory source, or the window does not name a conversation.
    ///
    /// The title is the one per-window feature choices already use (`featureScopeWindowTitle`): the
    /// open chat's name in WhatsApp (read from its header), the window title elsewhere. In Mail a
    /// compose window's title is the message subject ("Re: POC results"), which memory matches
    /// to the thread with reply prefixes removed.
    static func scope(
        bundleIdentifier: String,
        conversationTitle: String?,
        sourcesByBundle: [String: [String]]
    ) -> ConversationScope? {
        let raw = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let named = teamsBundleIdentifiers.contains(bundleIdentifier) ? teamsConversationTitle(raw) : raw
        guard let sources = sourcesByBundle[bundleIdentifier], !sources.isEmpty,
              let title = named, !title.isEmpty,
              !genericTitles.contains(title.lowercased()) else { return nil }
        return ConversationScope(title: title, sources: sources)
    }

    static let teamsBundleIdentifiers: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams"]

    /// The chat or meeting name in a Teams window title. Teams titles its window
    /// "<view> | <conversation> | <organization> | <account> | Microsoft Teams"
    /// ("Chat | Ali Pakkan | imperum.io | senad@imperum.io | Microsoft Teams"); the conversation is
    /// the first part that is not the view, the app, or the signed-in account. Nil when the window
    /// shows no conversation (only a view such as "Activity").
    static func teamsConversationTitle(_ windowTitle: String) -> String? {
        var parts = windowTitle.components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("@") && $0.lowercased() != "microsoft teams" }
        if let first = parts.first, teamsViews.contains(first.lowercased()) {
            parts.removeFirst()
        }
        // A lone remaining part with a dot and no space is the organization's domain, not a chat.
        guard let title = parts.first, !(title.contains(".") && !title.contains(" ")) else { return nil }
        return title
    }

    /// Teams' left-rail views, as they prefix the window title (English and Turkish).
    static let teamsViews: Set<String> = [
        "chat", "activity", "teams", "calendar", "calls", "files", "meet", "apps", "onedrive",
        "sohbet", "etkinlik", "ekipler", "takvim", "aramalar", "dosyalar", "uygulamalar"
    ]

    /// Window titles that name an app or an empty compose window, not a conversation.
    static let genericTitles: Set<String> = [
        "whatsapp", "mail", "new message", "yeni ileti", "untitled", "slack", "microsoft teams", "outlook"
    ]

    /// The search text for a field: complete 8-word blocks of what has been typed (so the query, and
    /// with it the cached result, stays the same while a block is being typed), or the conversation
    /// title alone before the first block exists, which already finds the conversation's recent
    /// context.
    static func query(precedingText: String, scope: ConversationScope) -> String {
        let stable = TypingHistoryQuery.stableText(from: precedingText)
        return stable.isEmpty ? scope.title : stable
    }
}

/// Turns retrieved messages into prompt lines.
nonisolated enum MemorySnippetFormatter {
    /// Characters per message line, and for the whole section (the renderer's budget).
    static let maximumLineCharacters = 240
    static let maximumTotalCharacters = 900

    struct Message: Equatable, Sendable {
        let sender: String
        let isFromMe: Bool
        let timestamp: Date
        let text: String
    }

    /// Oldest first, so the lines read like the conversation they came from; each line dated and
    /// attributed ("12 Sep · Ayşe: the invoice is paid") so the model can tell who said what.
    static func lines(_ messages: [Message], calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM"
        var lines: [String] = []
        var total = 0
        for message in messages.sorted(by: { $0.timestamp < $1.timestamp }) {
            let text = message.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let clipped = text.count > maximumLineCharacters ? String(text.prefix(maximumLineCharacters)) + "…" : text
            let speaker = message.isFromMe ? "You" : message.sender
            let line = "\(formatter.string(from: message.timestamp)) · \(speaker): \(clipped)"
            guard total + line.count <= maximumTotalCharacters else { continue }
            total += line.count + 1
            lines.append(line)
        }
        return lines
    }
}
