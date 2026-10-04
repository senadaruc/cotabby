import Foundation

/// File overview:
/// Finds the latest message the user received in the conversation whose reply field is focused.
///
/// Where it comes from, freshest source first:
/// - **Mail replies** (Apple Mail, Outlook): the quoted original below the caret, read through
///   Accessibility as the field's trailing text (`QuotedReplyParser`). No sync is needed.
/// - **Chats with a memory source** (WhatsApp, Teams): the conversation is found by the window's
///   chat name, as memory's search finds it (`ConversationScopeResolver`), the source is synced
///   (a delta read, throttled), and its newest messages are read from memory. Consecutive incoming
///   messages at the end are taken together, so "Hi!" followed by the actual question counts as one.
///   If the newest message is the user's own, they have already replied and there is nothing to
///   answer.
///
/// Which conversation a question is read from is independent of which sources may supply facts for
/// the answer: WhatsApp can be off as an answer source and still be where a question arrives.
/// Owned by `AnswerCoordinator`.
@MainActor
final class IncomingMessageResolver {
    nonisolated struct IncomingMessage: Equatable, Sendable {
        let text: String
        let sender: String?
        /// The conversation in memory, when it is known (always for chats, sometimes for mail).
        let conversation: MemoryConversation?
        /// The incoming messages' own records, never to be offered as facts for their own answer.
        let recordIDs: Set<String>

        /// Identifies the message for caching and dismissal: the same question gets one draft.
        var key: String {
            "\(conversation?.source ?? "")|\(conversation?.conversationId ?? "")|\(text.hashValue)"
        }
    }

    private let engine: @MainActor () -> MemoryEngine?
    private let historySync: MemoryHistorySync
    private let sourcesByBundle: @MainActor () -> [String: [String]]
    private var lastSync: [String: Date] = [:]

    /// Sources whose newest messages are read from memory (synced on demand).
    nonisolated static let chatSources: Set<String> = ["whatsapp", "teams"]
    /// A chat source is synced at most this often for answers (the periodic sync covers the rest).
    nonisolated static let syncInterval: TimeInterval = 20
    /// Incoming messages taken together at the end of a chat.
    nonisolated static let maximumIncomingRun = 3

    init(engine: @escaping @MainActor () -> MemoryEngine?, historySync: MemoryHistorySync,
         sourcesByBundle: @escaping @MainActor () -> [String: [String]]) {
        self.engine = engine
        self.historySync = historySync
        self.sourcesByBundle = sourcesByBundle
    }

    func latestIncoming(for context: FocusedInputSnapshot) async -> IncomingMessage? {
        let scope = ConversationScopeResolver.scope(
            bundleIdentifier: context.bundleIdentifier, conversationTitle: context.featureScopeWindowTitle,
            sourcesByBundle: sourcesByBundle()
        )
        if let quoted = QuotedReplyParser.quotedMessage(in: context.trailingText) {
            let conversation = scope.flatMap { scope in
                engine().flatMap { engine in
                    let found = engine.findConversations(title: scope.title, sources: scope.sources)
                    return found.count == 1 ? found[0] : nil
                }
            }
            return IncomingMessage(text: quoted.body, sender: quoted.sender, conversation: conversation, recordIDs: [])
        }
        guard let scope, let engine = engine() else { return nil }
        for source in scope.sources where Self.chatSources.contains(source) {
            if Date().timeIntervalSince(lastSync[source] ?? .distantPast) > Self.syncInterval {
                lastSync[source] = Date()
                await historySync.sync(source)
            }
        }
        let found = engine.findConversations(title: scope.title, sources: scope.sources)
        guard found.count == 1, let conversation = found.first else { return nil }
        let latest = await Task.detached(priority: .userInitiated) {
            engine.latestMessages(source: conversation.source, conversationID: conversation.conversationId, limit: Self.maximumIncomingRun + 1)
        }.value
        return Self.incomingRun(latest, conversation: conversation)
    }

    /// The incoming messages at the end of a conversation (newest first in `latest`), or nil when
    /// the newest message is the user's own.
    nonisolated static func incomingRun(_ latest: [MemoryStore.StoredMessage], conversation: MemoryConversation) -> IncomingMessage? {
        guard let newest = latest.first, !newest.isFromMe else { return nil }
        let run = latest.prefix { !$0.isFromMe }.prefix(maximumIncomingRun)
        // Messages of one burst only: older than an hour before the newest is a different exchange.
        let burst = run.filter { newest.timestamp - $0.timestamp < 3600 }
        return IncomingMessage(
            text: burst.reversed().map(\.text).joined(separator: "\n"),
            sender: newest.sender.isEmpty ? nil : newest.sender,
            conversation: conversation,
            recordIDs: Set(burst.map(\.recordID))
        )
    }
}
