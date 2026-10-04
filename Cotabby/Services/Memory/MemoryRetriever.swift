import Foundation
import Logging

/// File overview:
/// Gives the suggestion pipeline the earlier messages of the conversation being written in, from
/// the local memory service, without ever making a suggestion wait for them.
///
/// How a request gets memory:
/// 1. `ConversationScopeResolver` turns the focused app and window into a scope (the chat name or
///    mail subject, within the app's enabled memory sources), and builds a stable query.
/// 2. If the cache already holds the answer for that scope and query, it is returned. Otherwise the
///    cached answer for the same conversation (an earlier query) is returned, or nothing, and a
///    lookup starts in the background, bounded by `lookupTimeout`.
/// 3. When the lookup lands for the conversation still in focus, `onMemoryReady` lets the
///    coordinator offer a suggestion that uses it.
///
/// Gates, all checked here so the coordinator stays unaware of them: memory switched on and its
/// service running, an engine other than the endpoint, a non-secure field, the window not switched
/// off for memory in the field icon's popup, and the performance tuner allowing it. Built once by
/// `CotabbyAppEnvironment`.
@MainActor
final class MemoryRetriever: SuggestionMemoryProviding {
    var onMemoryReady: (@MainActor () -> Void)?

    private let client: MemoryServiceClient
    private let isServiceRunning: @MainActor () -> Bool
    /// The window's own memory choice from the field icon (nil: follow the app), by window key.
    var windowMemoryOverride: @MainActor (_ windowKey: String?) -> Bool? = { _ in nil }
    /// Whether the performance tuner allows memory lookups right now.
    var isAllowedByTuning: @MainActor () -> Bool = { true }

    /// Enabled memory sources per app bundle id, from the service's source list.
    private(set) var sourcesByBundle: [String: [String]] = [:]

    private struct CacheKey: Hashable {
        let scope: ConversationScope
        let query: String
    }

    private var cache: [CacheKey: [String]] = [:]
    /// The newest answer per conversation, served while a lookup for a newer query is in flight.
    private var latestByScope: [ConversationScope: [String]] = [:]
    private var inFlight: CacheKey?
    private var lastRequested: CacheKey?

    static let lookupTimeout: TimeInterval = 0.4
    static let maximumCacheEntries = 64

    init(client: MemoryServiceClient, isServiceRunning: @escaping @MainActor () -> Bool) {
        self.client = client
        self.isServiceRunning = isServiceRunning
    }

    /// Replaces the app -> sources map (from `sources.list`): only enabled sources serve memory.
    func updateSources(_ sources: [MemorySource]) {
        var map: [String: [String]] = [:]
        for source in sources where source.enabled {
            for bundle in source.appBundleIds {
                map[bundle, default: []].append(source.id)
            }
        }
        if map != sourcesByBundle {
            sourcesByBundle = map
            cache.removeAll()
            latestByScope.removeAll()
        }
    }

    /// Fetches the source list from the service and updates the map. Called when the service
    /// becomes ready and after source changes.
    func reloadSources() async {
        guard isServiceRunning(),
              let sources = try? await client.call("sources.list", as: [MemorySource].self) else { return }
        updateSources(sources)
    }

    /// Whether the focused app has memory at all (the field icon's popup shows its Memory row then).
    func hasMemory(forApplication bundleIdentifier: String) -> Bool {
        !(sourcesByBundle[bundleIdentifier] ?? []).isEmpty
    }

    // MARK: - SuggestionMemoryProviding

    func memorySnippets(for context: FocusedInputContext, engine: SuggestionEngineKind) -> [String] {
        guard engine != .openAICompatible, !context.isSecure, isServiceRunning(), isAllowedByTuning(),
              let scope = ConversationScopeResolver.scope(
                  bundleIdentifier: context.bundleIdentifier,
                  conversationTitle: context.featureScopeWindowTitle,
                  sourcesByBundle: sourcesByBundle
              ) else { return [] }
        let windowKey = WindowFeatureScope.windowKey(
            bundleIdentifier: context.bundleIdentifier, windowTitle: context.featureScopeWindowTitle
        )
        if windowMemoryOverride(windowKey) == false { return [] }

        let key = CacheKey(scope: scope, query: ConversationScopeResolver.query(precedingText: context.precedingText, scope: scope))
        lastRequested = key
        if let cached = cache[key] { return cached }
        startLookup(key)
        return latestByScope[scope] ?? []
    }

    private func startLookup(_ key: CacheKey) {
        guard inFlight != key else { return }
        inFlight = key
        let client = client
        let started = Date()
        Task { [weak self] in
            let result = try? await client.call(
                "search",
                params: ["query": key.query, "scope": key.scope.jsonObject],
                as: MemorySearchResult.self,
                timeout: Self.lookupTimeout
            )
            guard let self else { return }
            if self.inFlight == key { self.inFlight = nil }
            let lines = MemorySnippetFormatter.lines((result?.hits ?? []).map {
                MemorySnippetFormatter.Message(
                    sender: $0.sender, isFromMe: $0.isFromMe,
                    timestamp: Date(timeIntervalSince1970: $0.timestamp), text: $0.text
                )
            })
            CotabbyLogger.suggestion.debug("Memory lookup", metadata: [
                "stage": "memory",
                "memory_ms": .stringConvertible(Int(Date().timeIntervalSince(started) * 1000)),
                "memory_hits": .stringConvertible(result?.hits.count ?? -1),
                "memory_scope": .string(result?.scope ?? "failed")
            ])
            guard result != nil else { return }  // Timed out or failed: try again on the next request.
            if self.cache.count >= Self.maximumCacheEntries { self.cache.removeAll() }
            self.cache[key] = lines
            let changed = self.latestByScope[key.scope] != lines
            self.latestByScope[key.scope] = lines
            // Offer a suggestion that uses it only if it is new for the conversation still in focus.
            if changed, !lines.isEmpty, self.lastRequested?.scope == key.scope {
                self.onMemoryReady?()
            }
        }
    }
}
