import Combine
import Foundation
import Logging

/// File overview:
/// Feeds memory from the stores only Cotabby may read (WhatsApp, Apple Mail).
///
/// Why Cotabby does this rather than the memory service: those stores are protected by macOS, and
/// the service deliberately runs without any of Cotabby's permissions (it is spawned with
/// responsibility disclaimed). So Cotabby's own signed code reads them, a page at a time on a
/// background task, and pushes the messages to the service with `records.ingest`; the service then
/// scrubs, encrypts and indexes them exactly as it does for the sources it reads itself.
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
        readers: [any MemoryHistoryReading] = [WhatsAppHistoryReader(), AppleMailHistoryReader()],
        isServiceRunning: @escaping @MainActor () -> Bool,
        isOnACPower: @escaping @MainActor () -> Bool
    ) {
        self.client = client
        self.readers = Dictionary(uniqueKeysWithValues: readers.map { ($0.sourceID, $0) })
        self.isServiceRunning = isServiceRunning
        self.isOnACPower = isOnACPower
    }

    var pushedSourceIDs: [String] { readers.keys.sorted() }

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
        Task {
            let results = await Task.detached(priority: .utility) {
                readers.mapValues { $0.readiness() }
            }.value
            if readiness != results { readiness = results }
        }
    }

    // MARK: - Syncing

    /// Reads everything new from `sourceID` and pushes it. Safe to call repeatedly: a sync already
    /// running for the source makes later calls no-ops.
    func sync(_ sourceID: String, retentionDays: Int) async {
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
                    for source in sources where self.readers[source] != nil {
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
