import Foundation

/// File overview:
/// Gathers what memory knows for one rewrite: up to 6 facts about the person or thread, and up to 3
/// of the user's own messages there as style.
///
/// Where it looks, in order, never wider:
/// 1. The conversation the focused window names, within the focused app's own memory sources
///    (`ConversationScopeResolver`, the same rule autocomplete uses). Style examples come only from
///    here, so a chat is never styled after mail.
/// 2. The same title in the user's other enabled sources (a WhatsApp chat named "Richard" finds
///    Richard's mail thread). Facts only.
/// Nil when neither finds anything: the popup then says "No memory for this person".
/// Built by `CotabbyAppEnvironment`; used by `SelectionRewriteCoordinator`.
@MainActor
protocol RewriteMemorySearching: AnyObject {
    func search(query: String, scope: MemoryEngine.Scope) async -> MemorySearchResult?
    func latestMessages(source: String, conversationID: String, limit: Int) async -> [MemoryStore.StoredMessage]
}

/// The live adapter: runs `MemoryEngine` off the main actor like `MemoryRetriever` does.
@MainActor
final class MemoryEngineRewriteSearch: RewriteMemorySearching {
    private let engine: @MainActor () -> MemoryEngine?

    init(engine: @escaping @MainActor () -> MemoryEngine?) { self.engine = engine }
    nonisolated deinit {}

    func search(query: String, scope: MemoryEngine.Scope) async -> MemorySearchResult? {
        guard let engine = engine() else { return nil }
        return await Task.detached(priority: .userInitiated) { engine.search(query: query, scope: scope) }.value
    }

    func latestMessages(source: String, conversationID: String, limit: Int) async -> [MemoryStore.StoredMessage] {
        guard let engine = engine() else { return [] }
        return await Task.detached(priority: .userInitiated) {
            engine.latestMessages(source: source, conversationID: conversationID, limit: limit)
        }.value
    }
}

@MainActor
final class RewriteMemoryGatherer {
    static let maximumFacts = 6
    static let maximumStyleExamples = 3

    private let search: RewriteMemorySearching
    private let sourcesByBundle: @MainActor () -> [String: [String]]

    init(search: RewriteMemorySearching, sourcesByBundle: @escaping @MainActor () -> [String: [String]]) {
        self.search = search
        self.sourcesByBundle = sourcesByBundle
    }

    nonisolated deinit {}

    func gather(for input: FocusedInputSnapshot, selection: String) async -> RewriteMemoryContext? {
        let map = sourcesByBundle()
        if let own = ConversationScopeResolver.scope(
            bundleIdentifier: input.bundleIdentifier, conversationTitle: input.featureScopeWindowTitle,
            trailingText: input.trailingText, sourcesByBundle: map
        ), let result = await search.search(query: selection, scope: Self.scope(own)), !result.hits.isEmpty {
            let style = await styleExamples(in: result.conversation)
            return RewriteMemoryContext(facts: Self.facts(result), styleExamples: style)
        }
        let ownSources = Set(map[input.bundleIdentifier] ?? [])
        let otherSources = Array(Set(map.values.flatMap { $0 }).subtracting(ownSources)).sorted()
        guard !otherSources.isEmpty,
              let other = ConversationScopeResolver.scope(
                  bundleIdentifier: input.bundleIdentifier, conversationTitle: input.featureScopeWindowTitle,
                  trailingText: input.trailingText, sourcesByBundle: [input.bundleIdentifier: otherSources]
              ),
              let result = await search.search(query: selection, scope: Self.scope(other)), !result.hits.isEmpty
        else { return nil }
        return RewriteMemoryContext(facts: Self.facts(result), styleExamples: [])
    }

    private static func scope(_ conversation: ConversationScope) -> MemoryEngine.Scope {
        var scope = MemoryEngine.Scope()
        scope.title = conversation.title
        scope.sources = conversation.sources
        return scope
    }

    private static func facts(_ result: MemorySearchResult) -> [RewriteMemoryContext.Fact] {
        result.hits.prefix(maximumFacts).map { .init(text: $0.text, source: $0.source, sender: $0.isFromMe ? "Me" : $0.sender) }
    }

    private func styleExamples(in conversation: MemoryConversation?) async -> [String] {
        guard let conversation else { return [] }
        let messages = await search.latestMessages(source: conversation.source, conversationID: conversation.conversationId, limit: 20)
        return Array(messages.filter(\.isFromMe).map(\.text).filter { !$0.isEmpty }.prefix(Self.maximumStyleExamples))
    }
}
