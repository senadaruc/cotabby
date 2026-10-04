import Combine
import Foundation
import Logging

/// File overview:
/// Feeds memory from the stores only Cotabby may read (WhatsApp, Apple Mail, Outlook, Teams).
///
/// Why Cotabby does this rather than the memory service: those stores are protected by macOS, and
/// the service deliberately runs without any of Cotabby's permissions (it is spawned with
/// responsibility disclaimed). So Cotabby's own signed code reads them, a page at a time on a
/// background task, and pushes the messages to the service with `records.ingest`; the service then
/// scrubs, encrypts and indexes them exactly as it does for the sources it reads itself.
///
/// Teams is the exception to paging: its cache is Chromium IndexedDB, which only the service
/// parses, so it is copied into the service's private staging folder and imported as one job
/// (`TeamsCacheStager`, `records.import_staged`); the copy is deleted when the job ends.
///
/// When it runs: when a source is switched on or "Sync Now" is pressed, once the service becomes
/// ready, and then every 15 minutes while the Mac is on AC power (reading tens of thousands of
/// mails on battery would cost more than a slightly older memory is worth). Built once by
/// `CotabbyAppEnvironment`; the Memory pane observes `readiness` and `syncing`.
@MainActor
final class MemoryHistorySync: ObservableObject {
    /// Whether each pushed source can be read right now (shown in the pane instead of the
    /// service's own check, which cannot see macOS permissions).
    @Published private(set) var readiness: [String: MemorySourceReadiness] = [:]
    /// Sources being read and pushed right now.
    @Published private(set) var syncing: Set<String> = []
    /// One line per source about the last sync, for the pane.
    @Published private(set) var lastOutcome: [String: String] = [:]
    /// Whether Cotabby has Full Disk Access (nil until first checked). The protected sources need it.
    @Published private(set) var hasFullDiskAccess: Bool?

    private let client: MemoryServiceClient
    private let readers: [String: any MemoryHistoryReading]
    private let stagers: [String: any MemoryCacheStaging]
    private let stagingRoot: URL
    /// The cache signature last imported per staged source, so an unchanged cache is not copied
    /// again every 15 minutes. In memory only: the first sync after launch always imports, and the
    /// service's cursor keeps that cheap.
    private var importedSignatures: [String: String] = [:]
    private let isServiceRunning: @MainActor () -> Bool
    private let isOnACPower: @MainActor () -> Bool
    private var periodicTask: Task<Void, Never>?

    static let periodicInterval: UInt64 = 15 * 60
    /// Records per read page, and the approximate bytes per `records.ingest` request (the service
    /// refuses requests over 1 MB).
    static let pageSize = 400
    static let batchBytes = 600_000

    init(
        client: MemoryServiceClient,
        readers: [any MemoryHistoryReading] = [WhatsAppHistoryReader(), AppleMailHistoryReader(), OutlookHistoryReader()],
        stagers: [any MemoryCacheStaging] = [TeamsCacheStager()],
        stagingRoot: URL = MemoryServicePaths.standard().dataDirectory.appendingPathComponent("staging", isDirectory: true),
        isServiceRunning: @escaping @MainActor () -> Bool,
        isOnACPower: @escaping @MainActor () -> Bool
    ) {
        self.client = client
        self.readers = Dictionary(uniqueKeysWithValues: readers.map { ($0.sourceID, $0) })
        self.stagers = Dictionary(uniqueKeysWithValues: stagers.map { ($0.sourceID, $0) })
        self.stagingRoot = stagingRoot
        self.isServiceRunning = isServiceRunning
        self.isOnACPower = isOnACPower
    }

    var pushedSourceIDs: [String] { (Array(readers.keys) + Array(stagers.keys)).sorted() }

    // MARK: - Readiness

    /// Files that only Full Disk Access opens, in the order memory needs them: Mail's index,
    /// WhatsApp's database, then common ones every Mac with those apps has. The system privacy
    /// database is deliberately not used: newer macOS versions protect it beyond Full Disk Access,
    /// so it reported "not granted" while the sources were readable.
    nonisolated static var fullDiskAccessProbePaths: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Mail/V10/MailData/Envelope Index",
            WhatsAppHistoryReader.defaultDatabasePath,
            home + "/Library/Messages/chat.db",
            home + "/Library/Safari/Bookmarks.plist"
        ]
    }

    /// True when any protected file opens, false when one exists but macOS refuses it, nil when none
    /// of them exist (nothing to test against). Each file is opened read-only and closed at once;
    /// nothing is read.
    nonisolated static func probeFullDiskAccess(paths: [String] = fullDiskAccessProbePaths) -> Bool? {
        var refused = false
        for path in paths {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            if errno == EPERM || errno == EACCES { refused = true }
        }
        return refused ? false : nil
    }

    /// Re-checks Full Disk Access, and the sources' readiness when it changed (granting it in System
    /// Settings takes effect without restarting Cotabby).
    func checkFullDiskAccess() {
        let granted = Self.probeFullDiskAccess()
        guard granted != hasFullDiskAccess else { return }
        hasFullDiskAccess = granted
        refreshReadiness()
    }

    func refreshReadiness() {
        let readers = readers
        let stagers = stagers
        Task {
            let results = await Task.detached(priority: .utility) {
                readers.mapValues { $0.readiness() }.merging(stagers.mapValues { $0.readiness() }) { first, _ in first }
            }.value
            if readiness != results { readiness = results }
        }
    }

    // MARK: - Syncing

    /// Reads everything new from `sourceID` and pushes it. Safe to call repeatedly: a sync already
    /// running for the source makes later calls no-ops.
    func sync(_ sourceID: String, retentionDays: Int) async {
        if let stager = stagers[sourceID] {
            await importStaged(stager)
            return
        }
        guard let reader = readers[sourceID], !syncing.contains(sourceID), isServiceRunning() else { return }
        syncing.insert(sourceID)
        defer { syncing.remove(sourceID) }

        struct CursorReply: Decodable { let cursor: String? }
        let started = Date()
        var pushed = 0
        do {
            var cursor = try await client.call("sources.cursor", params: ["id": sourceID], as: CursorReply.self).cursor
            let since = retentionDays > 0 ? Date().addingTimeInterval(-Double(retentionDays) * 86_400) : nil
            var hasMore = true
            while hasMore {
                let page = try await Task.detached(priority: .utility) { [cursor] in
                    try reader.read(after: cursor, since: since, limit: Self.pageSize)
                }.value
                hasMore = page.hasMore
                cursor = page.nextCursor ?? cursor
                let batches = Self.batches(page.records)
                if batches.isEmpty, page.nextCursor != nil || !hasMore {
                    try await ingest(sourceID, [], cursor: page.nextCursor, final: !hasMore)
                }
                for (index, batch) in batches.enumerated() {
                    let isLast = index == batches.count - 1
                    // The cursor is stored with the page's last batch, so an interrupted sync resumes
                    // at a page boundary and never skips messages.
                    try await ingest(sourceID, batch, cursor: isLast ? page.nextCursor : nil, final: isLast && !hasMore)
                    pushed += batch.count
                }
            }
            lastOutcome[sourceID] = pushed == 0 ? "Up to date" : "Added \(pushed) messages"
            readiness[sourceID] = .ready
            CotabbyLogger.app.info("Memory sync finished", metadata: [
                "source": .string(sourceID),
                "pushed": .stringConvertible(pushed),
                "seconds": .stringConvertible(Int(Date().timeIntervalSince(started)))
            ])
        } catch let error as ReadOnlySQLiteDatabase.DatabaseError {
            readiness[sourceID] = error.readiness
            lastOutcome[sourceID] = error.localizedDescription
        } catch {
            lastOutcome[sourceID] = error.localizedDescription
            CotabbyLogger.app.warning("Memory sync failed: \(error.localizedDescription)", metadata: ["source": .string(sourceID)])
        }
    }

    /// Copies a cache only the service can parse into its staging folder, has the service import
    /// it, and deletes the copy when the job has ended (the service deletes it first; this is the
    /// second line of defence for a job that was cancelled or never ran).
    private func importStaged(_ stager: any MemoryCacheStaging) async {
        let sourceID = stager.sourceID
        guard !syncing.contains(sourceID), isServiceRunning() else { return }
        syncing.insert(sourceID)
        defer { syncing.remove(sourceID) }

        let root = stagingRoot
        let signature = await Task.detached(priority: .utility) { stager.signature() }.value
        if let signature, importedSignatures[sourceID] == signature {
            lastOutcome[sourceID] = "Up to date"
            return
        }
        let started = Date()
        var staged: URL?
        do {
            let readiness = await Task.detached(priority: .utility) { stager.readiness() }.value
            self.readiness[sourceID] = readiness
            guard readiness == .ready else {
                lastOutcome[sourceID] = readiness.message
                return
            }
            let copy = try await Task.detached(priority: .utility) { try stager.stage(into: root) }.value
            staged = copy
            let job = try await client.call(
                "records.import_staged", params: ["source": sourceID, "path": copy.path], as: MemoryJob.self, timeout: 30
            )
            let outcome = await waitForJob(job.id, sourceID: sourceID)
            lastOutcome[sourceID] = outcome.message
            if outcome.succeeded, let signature { importedSignatures[sourceID] = signature }
            self.readiness[sourceID] = .ready
            CotabbyLogger.app.info("Memory import finished", metadata: [
                "source": .string(sourceID),
                "outcome": .string(outcome.message),
                "seconds": .stringConvertible(Int(Date().timeIntervalSince(started)))
            ])
        } catch {
            lastOutcome[sourceID] = error.localizedDescription
            CotabbyLogger.app.warning("Memory import failed: \(error.localizedDescription)", metadata: ["source": .string(sourceID)])
        }
        if let staged { try? FileManager.default.removeItem(at: staged) }
    }

    /// Polls `jobs.list` until the job has ended. There is no deadline: the copy may only be deleted
    /// here once the service is done with it, and an import queued behind a long index rebuild
    /// waits as long as the rebuild takes (the import itself takes seconds). If the service stops
    /// answering, it is gone, and the copy is no one's to read any more.
    private func waitForJob(_ id: Int, sourceID: String) async -> (succeeded: Bool, message: String) {
        while true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let data = try? await client.callRaw("jobs.list", params: [:], timeout: 10),
                  let jobs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                return (false, "The memory service stopped during the import.")
            }
            guard let job = jobs.first(where: { ($0["id"] as? Int) == id }) else {
                return (false, "The import was interrupted.")
            }
            switch job["status"] as? String {
            case "done":
                return (true, Self.importSummary(job["result"], sourceID: sourceID))
            case "failed":
                return (false, (job["error"] as? String) ?? "The import failed.")
            case "cancelled":
                return (false, "The import was cancelled.")
            default:
                if (job["status"] as? String) == "queued" { lastOutcome[sourceID] = "Waiting for indexing to finish" }
                continue
            }
        }
    }

    /// "Added 120 messages" / "Up to date" / the reader's error, from an import job's result.
    nonisolated static func importSummary(_ result: Any?, sourceID: String) -> String {
        guard let source = (result as? [String: Any])?[sourceID] as? [String: Any] else { return "Imported" }
        if let error = source["error"] as? String { return error }
        let stored = (source["stored"] as? Int) ?? 0
        return stored == 0 ? "Up to date" : "Added \(stored) messages"
    }

    private func ingest(_ sourceID: String, _ records: [MemoryIngestRecord], cursor: String?, final: Bool) async throws {
        var params: [String: Any] = [
            "source": sourceID,
            "records": records.map(\.jsonObject),
            "final": final
        ]
        if let cursor { params["cursor"] = cursor }
        try await client.send("records.ingest", params: params, timeout: 60)
    }

    /// Splits records into requests under `batchBytes`.
    nonisolated static func batches(_ records: [MemoryIngestRecord]) -> [[MemoryIngestRecord]] {
        var batches: [[MemoryIngestRecord]] = []
        var current: [MemoryIngestRecord] = []
        var size = 0
        for record in records {
            if !current.isEmpty, size + record.approximateBytes > batchBytes {
                batches.append(current)
                current = []
                size = 0
            }
            current.append(record)
            size += record.approximateBytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    // MARK: - Schedule

    /// Starts the periodic sync of `enabledSources()` (pushed sources the user switched on).
    func startPeriodicSync(enabledSources: @escaping @MainActor () async -> (sources: [String], retentionDays: Int)) {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isServiceRunning(), self.isOnACPower() {
                    let (sources, retention) = await enabledSources()
                    for source in sources where self.readers[source] != nil || self.stagers[source] != nil {
                        await self.sync(source, retentionDays: retention)
                    }
                }
                try? await Task.sleep(nanoseconds: Self.periodicInterval * 1_000_000_000)
            }
        }
    }

    func stopPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = nil
    }
}
