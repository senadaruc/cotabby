import Combine
import Foundation

/// File overview:
/// The Memory settings pane's view of the running memory service: its status, settings, sources,
/// background jobs and logs, plus the actions the pane offers (sync, rebuild, forget, search).
///
/// Why separate from `MemoryServiceSupervisor`: the supervisor owns the *process* (install, start,
/// restart) and must keep working with no window open. This model owns what a person looks at and
/// asks for through the socket, and only polls while the pane is visible (`beginObserving` /
/// `endObserving`), so a closed Settings window costs nothing. Built once by
/// `CotabbyAppEnvironment`; the pane observes it and calls its actions, never the client directly.
@MainActor
final class MemoryControlModel: ObservableObject {
    @Published private(set) var status: MemoryServiceStatus?
    @Published private(set) var configuration: MemoryConfiguration?
    @Published private(set) var sources: [MemorySource] = []
    @Published private(set) var jobs: [MemoryJob] = []
    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastError: String?
    /// Keys the service refused in the last settings change, shown next to the controls.
    @Published private(set) var rejectedSettings: [String] = []
    @Published private(set) var playgroundResult: MemorySearchResult?
    @Published private(set) var isSearching = false

    private let client: MemoryServiceClient
    private let supervisor: MemoryServiceSupervisor
    /// Reads and pushes the sources only Cotabby may read; the pane observes it directly too.
    let historySync: MemoryHistorySync
    private var observers = 0
    private var pollTask: Task<Void, Never>?

    init(client: MemoryServiceClient, supervisor: MemoryServiceSupervisor, historySync: MemoryHistorySync) {
        self.client = client
        self.supervisor = supervisor
        self.historySync = historySync
    }

    private var retentionDays: Int { configuration?.privacy.retentionDays ?? 365 }

    private func isPushed(_ id: String) -> Bool {
        sources.first { $0.id == id }?.pushed ?? historySync.pushedSourceIDs.contains(id)
    }

    /// The pushed sources the user switched on, and the retention window, as the periodic sync
    /// needs them (read fresh from the service, since the pane may be closed).
    func enabledPushedSources() async -> (sources: [String], retentionDays: Int) {
        guard let config = try? await client.call("config.get", as: MemoryConfiguration.self) else {
            return ([], 365)
        }
        let enabled = historySync.pushedSourceIDs.filter { config.sources[$0]?.enabled == true }
        return (enabled, config.privacy.retentionDays)
    }

    // MARK: - Observation

    func beginObserving() {
        observers += 1
        guard observers == 1 else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Poll fast while work is running so progress bars move, slowly otherwise.
                let interval: UInt64 = self.jobs.contains(where: \.isActive) ? 1 : 5
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    func endObserving() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reloads everything the pane shows. Quietly does nothing while the service is not running.
    func refresh() async {
        guard supervisor.state == .running else {
            status = nil
            return
        }
        do {
            async let status = client.call("status", as: MemoryServiceStatus.self)
            async let configuration = client.call("config.get", as: MemoryConfiguration.self)
            async let sources = client.call("sources.list", as: [MemorySource].self)
            async let jobs = client.call("jobs.list", as: [MemoryJob].self)
            let loaded = try await (status, configuration, sources, jobs)
            self.status = loaded.0
            if self.configuration != loaded.1 { self.configuration = loaded.1 }
            if self.sources != loaded.2 { self.sources = loaded.2 }
            if self.jobs != loaded.3 { self.jobs = loaded.3 }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadLogs() async {
        struct Tail: Decodable { let lines: [String] }
        if let tail = try? await client.call("logs.tail", params: ["lines": 300], as: Tail.self) {
            logLines = tail.lines
        }
    }

    // MARK: - Actions

    func setSourceEnabled(_ id: String, enabled: Bool) {
        perform("sources.configure", ["id": id, "enabled": enabled]) {
            if enabled {
                self.historySync.refreshReadiness()
                await self.sync(id)
            }
        }
    }

    func setSourceOption(_ id: String, key: String, value: String) {
        perform("sources.configure", ["id": id, "options": [key: value]])
    }

    /// Syncs one source, or every enabled one. Sources Cotabby reads itself go through
    /// `MemoryHistorySync`; the rest are synced by the service.
    func sync(_ id: String? = nil) async {
        if let id {
            if isPushed(id) {
                await historySync.sync(id, retentionDays: retentionDays)
                await refresh()
            } else {
                await run("sources.sync", ["id": id])
            }
            return
        }
        await run("sources.sync", [:])
        for source in sources where source.pushed && source.enabled {
            await historySync.sync(source.id, retentionDays: retentionDays)
        }
        await refresh()
    }

    func forget(_ id: String) {
        perform("sources.forget", ["id": id])
    }

    func rebuildIndex() {
        perform("index.rebuild", [:])
    }

    func removeIndex() {
        perform("index.remove", [:])
    }

    func cancelJob(_ id: Int) {
        perform("jobs.cancel", ["id": id])
    }

    /// Sends changed index settings. The service validates ranges and reports what it refused.
    func updateIndexSettings(_ settings: MemoryIndexSettings) {
        guard let data = try? MemoryServiceClient.encoder.encode(settings),
              let patch = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        updateConfiguration(["index": patch])
    }

    func updatePrivacy(_ privacy: MemoryPrivacySettings) {
        guard let data = try? MemoryServiceClient.encoder.encode(privacy),
              let patch = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        updateConfiguration(["privacy": patch]) {
            await self.run("privacy.purge", [:])
        }
    }

    func deleteAllMemory() {
        perform("privacy.delete_all", [:])
    }

    private func updateConfiguration(_ patch: [String: Any], then: (@MainActor () async -> Void)? = nil) {
        struct Reply: Decodable {
            let config: MemoryConfiguration
            let rejected: [String]
        }
        Task {
            do {
                let reply = try await client.call("config.set", params: ["patch": patch], as: Reply.self)
                configuration = reply.config
                rejectedSettings = reply.rejected
                await then?()
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Playground

    /// Recently active conversations of one source, for the Playground's picker.
    @Published private(set) var playgroundConversations: [MemoryConversation] = []

    func loadConversations(source: String) {
        Task {
            playgroundConversations = (try? await client.call(
                "conversations.list", params: ["sources": [source], "limit": 300], as: [MemoryConversation].self
            )) ?? []
        }
    }

    /// Searches one exact conversation (by id, so duplicate names cannot get in the way), the way a
    /// suggestion written there would.
    func search(query: String, conversation: MemoryConversation) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                playgroundResult = try await client.call(
                    "search",
                    params: ["query": trimmed, "scope": ["source": conversation.source, "conversation_id": conversation.conversationId]],
                    as: MemorySearchResult.self
                )
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Runs one search the way a suggestion would (scoped to a conversation title within the
    /// app's sources), or across all of memory when `global` is set.
    func search(query: String, title: String, sources: [String], global: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            playgroundResult = nil
            return
        }
        var scope: [String: Any] = global ? ["global": true] : ["title": title, "sources": sources]
        if global { scope["sources"] = sources }
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                playgroundResult = try await client.call(
                    "search", params: ["query": trimmed, "scope": scope], as: MemorySearchResult.self
                )
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Plumbing

    private func perform(_ method: String, _ params: [String: Any], then: (@MainActor () async -> Void)? = nil) {
        Task {
            await run(method, params)
            await then?()
        }
    }

    private func run(_ method: String, _ params: [String: Any]) async {
        do {
            try await client.send(method, params: params, timeout: 30)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }
}
