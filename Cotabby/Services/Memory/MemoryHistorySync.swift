import Combine
import Foundation
import Logging

/// File overview:
/// Feeds conversation memory from the message stores on this Mac (WhatsApp, Apple Mail, Outlook,
/// Teams, a documents folder).
///
/// Each source has a reader (`Services/Memory/Readers`) that opens its store read-only and returns
/// messages after a cursor, a page at a time, on a background task. This type runs those readers
/// and hands each page to `MemoryEngine.ingest`, which scrubs, encrypts, stores and (in the
/// background) indexes it. The protected stores need Full Disk Access, which Cotabby holds; nothing
/// is copied anywhere on the way.
///
/// When it runs: when a source is switched on or "Sync Now" is pressed, when memory starts, and then
/// every 15 minutes while the Mac is on AC power (reading tens of thousands of mails on battery
/// would cost more than a slightly older memory is worth). Built once by `CotabbyAppEnvironment`;
/// the Memory pane observes `readiness`, `syncing` and `lastOutcome`.
@MainActor
final class MemoryHistorySync: ObservableObject {
    /// Whether each source can be read right now (permission, files present).
    @Published private(set) var readiness: [String: MemorySourceReadiness] = [:]
    /// Sources being read right now.
    @Published private(set) var syncing: Set<String> = []
    /// One line per source about the last sync, for the pane.
    @Published private(set) var lastOutcome: [String: String] = [:]
    /// Whether Cotabby has Full Disk Access (nil until first checked). The protected sources need it.
    @Published private(set) var hasFullDiskAccess: Bool?

    private let readers: [String: any MemoryHistoryReading]
    private let engine: @MainActor () -> MemoryEngine?
    private let isOnACPower: @MainActor () -> Bool
    private var periodicTask: Task<Void, Never>?

    nonisolated static let periodicInterval: UInt64 = 15 * 60
    /// Records read per page.
    nonisolated static let pageSize = 400
    /// The longest one source reads per sync run before the next source's turn.
    nonisolated static let runBudget: TimeInterval = 5 * 60
    /// Sources whose reader is not available in this version; already remembered messages stay.
    static let pausedSources: [String: String] = [:]

    init(
        readers: [any MemoryHistoryReading] = [
            WhatsAppHistoryReader(), AppleMailHistoryReader(), OutlookHistoryReader(), TeamsCacheReader(),
            CalendarHistoryReader()
        ] + CloudDriveReader.all.map { CloudDriveReader(drive: $0) },
        engine: @escaping @MainActor () -> MemoryEngine?,
        isOnACPower: @escaping @MainActor () -> Bool
    ) {
        self.readers = Dictionary(uniqueKeysWithValues: readers.map { ($0.sourceID, $0) })
        self.engine = engine
        self.isOnACPower = isOnACPower
    }

    /// The reader for a source; the documents folder comes from the source's settings.
    private func reader(for sourceID: String) -> (any MemoryHistoryReading)? {
        if sourceID == DocumentsHistoryReader.id {
            guard let folder = engine()?.configuration.sources[sourceID]?.options["folder"], !folder.isEmpty else { return nil }
            return DocumentsHistoryReader(folder: folder)
        }
        return readers[sourceID]
    }

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
        var readers = readers
        if let documents = reader(for: DocumentsHistoryReader.id) { readers[DocumentsHistoryReader.id] = documents }
        Task {
            var results = await Task.detached(priority: .utility) {
                readers.mapValues { $0.readiness() }
            }.value
            for (source, reason) in Self.pausedSources { results[source] = .failed(reason) }
            if readiness != results { readiness = results }
        }
    }

    // MARK: - Syncing

    /// Reads everything new from `sourceID` and stores it. Safe to call repeatedly: a sync already
    /// running for the source makes later calls no-ops.
    func sync(_ sourceID: String) async {
        guard let engine = engine(), let reader = reader(for: sourceID), !syncing.contains(sourceID) else { return }
        syncing.insert(sourceID)
        defer { syncing.remove(sourceID) }

        let started = Date()
        let retentionDays = engine.configuration.privacy.retentionDays
        do {
            let stored = try await Task.detached(priority: .utility) { () throws -> Int in
                var cursor = engine.cursor(source: sourceID)
                let since = retentionDays > 0 ? Date().addingTimeInterval(-Double(retentionDays) * 86_400) : nil
                var stored = 0
                var hasMore = true
                // One run reads for at most `runBudget`, then yields to the other sources; the next
                // round resumes at the saved cursor. A first pass over a large drive takes hours
                // (each online-only file is downloaded to be read) and must not hold up mail.
                let deadline = Date().addingTimeInterval(Self.runBudget)
                while hasMore, Date() < deadline {
                    let page = try reader.read(after: cursor, since: since, limit: Self.pageSize)
                    hasMore = page.hasMore
                    cursor = page.nextCursor ?? cursor
                    // The cursor is saved with the page it ends, so an interrupted sync resumes at a
                    // page boundary and never skips messages.
                    stored += try engine.ingest(source: sourceID, records: page.records, cursor: page.nextCursor,
                                                completeConversations: page.completeConversations).stored
                }
                // Read through to the end: what the source no longer has (deleted documents) goes too.
                if !hasMore, let live = reader.liveConversationIDs() {
                    try engine.forget(source: sourceID, conversationsNotIn: live)
                }
                return stored
            }.value
            lastOutcome[sourceID] = stored == 0 ? "Up to date" : "Added \(stored) messages"
            readiness[sourceID] = .ready
            CotabbyLogger.app.info("Memory sync finished", metadata: [
                "source": .string(sourceID),
                "stored": .stringConvertible(stored),
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

    // MARK: - Schedule

    /// Starts the periodic sync of the enabled sources.
    func startPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let engine = self.engine(), self.isOnACPower() {
                    for source in engine.configuration.enabledSourceIDs where Self.pausedSources[source] == nil {
                        await self.sync(source)
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
