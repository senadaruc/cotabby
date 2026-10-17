import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import Cotabby

/// Pins the upgrade of a memory store and settings written by earlier builds of this fork, before
/// record ids were keyed and before mail conversations split by audience:
/// - the store opens with its key, nothing is deleted, and the sources whose conversations changed
///   are read again once (their cursors reset; the cloud drives' are not);
/// - a re-read message is renamed in place from its legacy id (no duplicate), keeps its vectors when
///   it did not move, and moves to its new conversation when it did, leaving no empty conversation
///   or stray participant behind;
/// - a message the source no longer has (an old Teams month) stays, and is renamed if read later;
/// - the memory switch moves from `cotabbyMemoryServiceEnabled` to `cotabbyMemoryEnabled`, the
///   settings file keeps every answer setting, and the store's paths are the ones earlier builds used.
///
/// The fixture is a store written through `MemoryStore` and then given the shape the earlier code
/// left on disk with plain SQL (its record ids, `legacyRecordID`, and no `record_ids` mark), since
/// the earlier code differs from today's only in those ids and in what its readers produced, which
/// the records here reproduce. Everything lives in a temporary folder with a fixed test key.
final class MemoryLegacyMigrationTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(data: Data(0..<32))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("messages.sqlite") }

    private func openStore() throws -> MemoryStore {
        try MemoryStore(path: storeURL, vault: MemoryVault(rootKey: key))
    }

    private func record(
        _ id: String, _ conversation: String, _ text: String, sender: String = "Ayşe", me: Bool = false,
        title: String, participants: [String], subject: String? = nil, at seconds: TimeInterval = 1_790_000_000
    ) -> MemoryIngestRecord {
        MemoryIngestRecord(
            sourceMessageID: id, conversationID: conversation, conversationTitle: title, sender: sender, isFromMe: me,
            timestamp: Date(timeIntervalSince1970: seconds), text: text, participants: participants, subject: subject
        )
    }

    // MARK: - The earlier build's data

    /// What the earlier readers produced: Mail's thread id alone, a WhatsApp group without its
    /// marker, a Teams chat, and an old Teams message the cache no longer holds.
    private var oldMail: [MemoryIngestRecord] {
        [
            record("101", "7", "The invoice for September is attached", sender: "Ayşe Yılmaz", title: "Invoice",
                   participants: ["ayse@example.com"], subject: "Invoice"),
            record("102", "7", "Thanks, paid today", sender: "Alex", me: true, title: "Invoice",
                   participants: ["ayse@example.com"], subject: "Invoice")
        ]
    }

    private var oldWhatsApp: [MemoryIngestRecord] {
        [
            record("w1", "ayse@s.whatsapp.net", "see you at the station", title: "Ayşe", participants: ["ayse@s.whatsapp.net"]),
            record("w2", "trip@g.us", "the train leaves at nine", title: "Trip", participants: ["ayse@s.whatsapp.net"])
        ]
    }

    private var teams: [MemoryIngestRecord] {
        [
            record("chat/1", "chat", "the release moved to Friday", sender: "Sam Archer", title: "Sam Archer",
                   participants: ["8:orgid:sam"]),
            record("chat/0", "chat", "kick-off notes from the spring", sender: "Sam Archer", title: "Sam Archer",
                   participants: ["8:orgid:sam"], at: 1_760_000_000)
        ]
    }

    /// Writes the earlier build's store: its records, a vector per message, cursors for every
    /// source, and then the earlier record ids, the earlier participant rule for mail (the
    /// sender's display name was a participant), and no `record_ids` mark.
    private func writeEarlierBuildStore() throws {
        do {
            let store = try openStore()
            try store.upsert(source: "apple_mail", records: oldMail)
            try store.upsert(source: "whatsapp", records: oldWhatsApp)
            try store.upsert(source: "teams", records: teams)
            try store.upsert(source: "icloud_drive", records: [
                record("notes.txt#0", "notes.txt", "The office opens at eight", sender: "notes", me: true,
                       title: "notes", participants: [])
            ])
            let pending = try store.unindexedMessages(sources: ["apple_mail", "whatsapp", "teams", "icloud_drive"], limit: 100)
            try store.saveIndexEntries(pending.map { message in
                (message, [(passageID: message.recordID, vector: [UInt16](repeating: 15360, count: 4)),
                           (passageID: message.recordID + "#1", vector: [UInt16](repeating: 15360, count: 4))])
            }, model: "model@1")
            for source in ["apple_mail", "whatsapp", "teams", "icloud_drive", "outlook"] {
                try store.setCursor("cursor-\(source)", source: source)
            }
        }
        let database = try RawDatabase(storeURL)
        defer { database.close() }
        let all = [("apple_mail", oldMail), ("whatsapp", oldWhatsApp), ("teams", teams),
                   ("icloud_drive", [record("notes.txt#0", "notes.txt", "", title: "", participants: [])])]
        let store = try openStore()
        for (source, records) in all {
            for record in records {
                let keyed = store.recordID(source: source, sourceMessageID: record.sourceMessageID)
                let legacy = MemoryStore.legacyRecordID(source: source, sourceMessageID: record.sourceMessageID)
                try database.exec("UPDATE messages SET record_id = '\(legacy)' WHERE record_id = '\(keyed)'")
                try database.exec("""
                    UPDATE vectors SET record_id = '\(legacy)', passage_id = '\(legacy)' || substr(passage_id, \(keyed.count + 1))
                    WHERE record_id = '\(keyed)'
                    """)
                try database.exec("UPDATE terms SET record_id = '\(legacy)' WHERE record_id = '\(keyed)'")
                try database.exec("UPDATE term_documents SET record_id = '\(legacy)' WHERE record_id = '\(keyed)'")
            }
        }
        // The earlier rule also made a mail sender's display name a participant of the thread.
        let thread = store.conversationKey(source: "apple_mail", conversationID: "7")
        let name = ParticipantNormalizer.normalize("Ayşe Yılmaz")
        let sealed = try store.vault.seal(name).map { String(format: "%02x", $0) }.joined()
        try database.exec("""
            INSERT INTO participants(source, conv_key, participant_tag, participant)
            VALUES ('apple_mail', '\(thread)', '\(store.participantTag(name))', x'\(sealed)')
            """)
        try database.exec("DELETE FROM meta WHERE key = 'record_ids'")
    }

    // MARK: - Tests

    /// The id earlier builds derived, as their own known-answer test pinned it.
    func test_theLegacyRecordIDIsTheOneEarlierBuildsWrote() throws {
        XCTAssertEqual(MemoryStore.legacyRecordID(source: "whatsapp", sourceMessageID: "A1"), "whatsapp:86da5e534dac21b0e09b")
        let keyed = try openStore().recordID(source: "whatsapp", sourceMessageID: "A1")
        XCTAssertEqual(keyed.count, "whatsapp:".count + 32, "keyed ids are longer, so the two shapes never collide")
    }

    func test_anEarlierBuildsStoreOpensWithItsKeyAndRereadsOnlyTheSourcesThatChanged() throws {
        try writeEarlierBuildStore()
        let before = try RawDatabase(storeURL)
        let messagesBefore = try before.count("SELECT COUNT(*) FROM messages")
        let vectorsBefore = try before.count("SELECT COUNT(*) FROM vectors")
        before.close()

        let store = try openStore()
        XCTAssertEqual(store.openingMigration.rereadSources, ["apple_mail", "whatsapp", "teams"],
                       "outlook has no legacy rows here, and the cloud drives are never re-read")
        XCTAssertEqual(store.openingMigration.legacyRecords, 7)
        XCTAssertNil(try store.cursor(source: "apple_mail"))
        XCTAssertNil(try store.cursor(source: "whatsapp"))
        XCTAssertNil(try store.cursor(source: "teams"))
        XCTAssertEqual(try store.cursor(source: "icloud_drive"), "cursor-icloud_drive", "no download of every cloud file")
        XCTAssertEqual(try store.cursor(source: "outlook"), "cursor-outlook")

        let after = try RawDatabase(storeURL)
        defer { after.close() }
        XCTAssertEqual(try after.count("SELECT COUNT(*) FROM messages"), messagesBefore, "opening deletes nothing")
        XCTAssertEqual(try after.count("SELECT COUNT(*) FROM vectors"), vectorsBefore)
        XCTAssertEqual(try after.count("SELECT COUNT(*) FROM meta WHERE key = 'record_ids'"), 1)

        // A second open is not a second migration: the cursors the re-read writes stay.
        try store.setCursor("12", source: "apple_mail")
        let reopened = try openStore()
        XCTAssertEqual(reopened.openingMigration.rereadSources, [])
        XCTAssertEqual(try reopened.cursor(source: "apple_mail"), "12")
    }

    func test_rereadingRenamesInPlaceKeepsVectorsAndMovesMailWithoutDuplicatesOrOrphans() throws {
        try writeEarlierBuildStore()
        let store = try openStore()
        // Before: the group and the 1:1 chat had the same people, so each could stand for the other.
        let ayse = ["ayse@s.whatsapp.net", "Ayşe"]
        XCTAssertEqual(try store.conversationsSeenBy(audience: ayse, excluding: nil).count, 2)

        // Today's readers: mail split by audience, the WhatsApp group with its marker. The old Teams
        // month is gone from the cache, so only the newer message is read.
        let audience = MailAudience.conversationID(thread: "7", people: ["ayse@example.com"])
        let newMail = oldMail.map {
            record($0.sourceMessageID, audience, $0.text, sender: $0.sender, me: $0.isFromMe, title: $0.conversationTitle,
                   participants: $0.participants, subject: $0.subject)
        }
        let newWhatsApp = [
            oldWhatsApp[0],
            record("w2", "trip@g.us", "the train leaves at nine", title: "Trip",
                   participants: ["ayse@s.whatsapp.net", WhatsAppHistoryReader.groupMarker + "trip@g.us"])
        ]
        let mail = try store.upsert(source: "apple_mail", records: newMail)
        let chats = try store.upsert(source: "whatsapp", records: newWhatsApp)
        let work = try store.upsert(source: "teams", records: [teams[0]])

        // Renamed, never duplicated.
        let database = try RawDatabase(storeURL)
        defer { database.close() }
        XCTAssertEqual(try database.count("SELECT COUNT(*) FROM messages"), 7)
        XCTAssertEqual(mail.legacyRecordIDs.count, 2)
        XCTAssertEqual(Set(mail.adoptedRecordIDs), Set(newMail.map { store.recordID(source: "apple_mail", sourceMessageID: $0.sourceMessageID) }))
        XCTAssertEqual(try database.count(
            "SELECT COUNT(*) FROM messages WHERE length(record_id) = length(source) + 21"), 2,
            "left with legacy ids: the Teams message the cache no longer has, and the cloud file not read again")

        // Unmoved chats keep their vectors (renamed with their passages) and stay indexed.
        XCTAssertEqual(chats.changed, 0)
        XCTAssertEqual(work.changed, 0)
        let teamsID = store.recordID(source: "teams", sourceMessageID: "chat/1")
        XCTAssertEqual(Set(try store.vectors(model: "model@1", recordIDs: [teamsID]).map(\.passageID)), [teamsID, teamsID + "#1"])
        XCTAssertEqual(try store.sourceStats("teams").pending, 0)
        XCTAssertEqual(try store.sourceStats("whatsapp").pending, 0)

        // Mail moved to its audience conversation: indexed again there, and the old thread (with the
        // display-name participant the earlier rule added) is gone.
        XCTAssertEqual(Set(mail.replacedRecordIDs), Set(mail.adoptedRecordIDs))
        XCTAssertEqual(try store.sourceStats("apple_mail").pending, 2)
        XCTAssertEqual(try store.sourceStats("apple_mail").conversations, 1)
        XCTAssertNil(try store.conversation(source: "apple_mail", conversationID: "7"))
        XCTAssertEqual(try store.conversation(source: "apple_mail", conversationID: audience)?.participants, ["ayse@example.com"])
        XCTAssertEqual(try database.count("SELECT COUNT(*) FROM participants WHERE source = 'apple_mail'"), 1)
        XCTAssertEqual(try database.count("""
            SELECT COUNT(*) FROM conversations c WHERE NOT EXISTS
            (SELECT 1 FROM messages m WHERE m.source = c.source AND m.conv_key = c.conv_key)
            """), 0, "no empty conversation left anywhere")

        // The group now has its marker, so it never stands for the 1:1 chat with Ayşe.
        let seen = try store.conversationsSeenBy(audience: ayse, excluding: nil)
        XCTAssertEqual(seen.map(\.conversationKey), [store.conversationKey(source: "whatsapp", conversationID: "ayse@s.whatsapp.net")])

        // The old Teams month stays searchable, and is renamed when it is read again.
        XCTAssertEqual(try store.keywordSearch(query: "kick-off notes", conversations: [
            ("teams", store.conversationKey(source: "teams", conversationID: "chat"))
        ], limit: 5).map(\.text), ["kick-off notes from the spring"])
        let late = try store.upsert(source: "teams", records: [teams[1]])
        XCTAssertEqual(late.adoptedRecordIDs, [store.recordID(source: "teams", sourceMessageID: "chat/0")])
        XCTAssertEqual(try database.count("SELECT COUNT(*) FROM messages WHERE source = 'teams'"), 2)
    }

    /// The engine's side: a store from an earlier build ingests through `MemoryEngine` without a
    /// duplicate, and a lookup by meaning keeps finding the renamed rows' vectors.
    func test_theEngineIngestsAnEarlierStoreWithoutDuplicates() throws {
        try writeEarlierBuildStore()
        let paths = MemoryEngine.Paths(dataDirectory: directory)
        XCTAssertEqual(paths.store, storeURL)
        let engine = try MemoryEngine(
            paths: paths, rootKey: key, modelURL: directory.appendingPathComponent("none.gguf"),
            conditions: {
                EmbeddingSchedulePolicy.Conditions(isOnACPower: true, isLowPowerMode: false, thermalState: .nominal,
                                                   userIdleSeconds: 60, isGenerating: false, pendingPassages: 0)
            }
        )
        try engine.updateConfiguration {
            $0.sources["whatsapp"] = MemorySourceSettings(enabled: true)
            $0.privacy.retentionDays = 0
        }
        XCTAssertNil(engine.cursor(source: "whatsapp"), "read again from the start")
        try engine.ingest(source: "whatsapp", records: oldWhatsApp, cursor: "2")
        try engine.ingest(source: "whatsapp", records: oldWhatsApp, cursor: "2")
        XCTAssertEqual(engine.sources().first { $0.id == "whatsapp" }?.stats.messages, 2)
        var scope = MemoryEngine.Scope()
        scope.title = "Ayşe"
        scope.sources = ["whatsapp"]
        XCTAssertEqual(engine.search(query: "station", scope: scope).hits.map(\.text), ["see you at the station"])
    }

    /// A never-remember entry saved under a mail thread's earlier id keeps covering the audience
    /// conversations the thread is split into now, so a re-read never brings that mail back.
    func test_aNeverRememberedThreadStaysForgottenAfterItSplitsByAudience() throws {
        XCTAssertTrue(MemoryEngine.isExcluded(conversationID: "7|ayse@example.com", by: ["7"]))
        XCTAssertTrue(MemoryEngine.isExcluded(conversationID: "thread-7|ayse@example.com", by: ["thread-7"]))
        XCTAssertTrue(MemoryEngine.isExcluded(conversationID: "hx-topic:invoice|ayse@example.com", by: ["hx-topic:invoice"]))
        XCTAssertTrue(MemoryEngine.isExcluded(conversationID: "ayse@s.whatsapp.net", by: ["ayse@s.whatsapp.net"]))
        XCTAssertFalse(MemoryEngine.isExcluded(conversationID: "17|ayse@example.com", by: ["7"]))
        XCTAssertFalse(MemoryEngine.isExcluded(conversationID: "ayse@s.whatsapp.net", by: []))
        // "|" is legal in an address's local part and in a sender someone else chose: the thread
        // entry must still cover the conversation, whichever "|" ends the thread.
        XCTAssertTrue(MemoryEngine.isExcluded(conversationID: "7|a|b@example.com,c@example.org", by: ["7"]))
        XCTAssertTrue(MemoryEngine.isExcluded(
            conversationID: MailAudience.conversationID(thread: "7", people: ["x|y@example.com"]), by: ["7"]
        ))
        XCTAssertTrue(MemoryEngine.isExcluded(conversationID: "hx-topic:invoice|evil|ayse@example.com", by: ["hx-topic:invoice"]))
        // A thread or topic that itself contains "|".
        XCTAssertTrue(MemoryEngine.isExcluded(conversationID: "hx-topic:q3|budget|ayse@example.com", by: ["hx-topic:q3|budget"]))
        XCTAssertTrue(MemoryEngine.isExcluded(conversationID: "thread|7|ayse@example.com", by: ["thread|7"]))
        XCTAssertFalse(MemoryEngine.isExcluded(conversationID: "hx-topic:q3|budget|ayse@example.com", by: ["hx-topic:q3|b"]))

        let engine = try MemoryEngine(
            paths: MemoryEngine.Paths(dataDirectory: directory), rootKey: key,
            modelURL: directory.appendingPathComponent("none.gguf"),
            conditions: {
                EmbeddingSchedulePolicy.Conditions(isOnACPower: true, isLowPowerMode: false, thermalState: .nominal,
                                                   userIdleSeconds: 60, isGenerating: false, pendingPassages: 0)
            }
        )
        try engine.updateConfiguration {
            $0.sources["apple_mail"] = MemorySourceSettings(enabled: true)
            $0.privacy.excludedConversations = ["7"]
            $0.privacy.retentionDays = 0
        }
        let audience = MailAudience.conversationID(thread: "7", people: ["ayse@example.com"])
        let result = try engine.ingest(source: "apple_mail", records: [
            record("101", audience, "The invoice for September is attached", title: "Invoice",
                   participants: ["ayse@example.com"], subject: "Invoice")
        ], cursor: nil)
        XCTAssertEqual(result.stored, 0)
        XCTAssertEqual(result.dropped, 1)
        let spoofed = MailAudience.conversationID(thread: "7", people: ["mallory|x@example.org"])
        let second = try engine.ingest(source: "apple_mail", records: [
            record("102", spoofed, "Please resend the invoice", title: "Invoice",
                   participants: ["mallory|x@example.org"], subject: "Invoice")
        ], cursor: nil)
        XCTAssertEqual(second.stored, 0, "a \"|\" in a participant does not get excluded mail stored")
    }

    /// Two rows for one message (the legacy one and a keyed one) leave one, and no empty
    /// conversation behind.
    func test_aLegacyDuplicateIsDroppedWithItsEmptyConversation() throws {
        do {
            let store = try openStore()
            try store.upsert(source: "teams", records: [teams[0]])
        }
        // Give the same message a second, legacy row in a conversation of its own.
        let database = try RawDatabase(storeURL)
        defer { database.close() }
        let probe = try openStore()
        let keyed = probe.recordID(source: "teams", sourceMessageID: "chat/1")
        let legacy = MemoryStore.legacyRecordID(source: "teams", sourceMessageID: "chat/1")
        let oldKey = probe.conversationKey(source: "teams", conversationID: "old-chat")
        try database.exec("""
            INSERT INTO messages SELECT '\(legacy)', source, '\(oldKey)', sender, is_from_me, timestamp, subject, text,
            text_tag, indexed FROM messages WHERE record_id = '\(keyed)'
            """)
        try database.exec("""
            INSERT INTO conversations SELECT source, '\(oldKey)', conversation_id, title, title_tag, last_timestamp
            FROM conversations WHERE source = 'teams'
            """)
        try database.exec("DELETE FROM meta WHERE key = 'record_ids'")
        XCTAssertEqual(try database.count("SELECT COUNT(*) FROM conversations"), 2)

        let store = try openStore()
        let result = try store.upsert(source: "teams", records: [teams[0]])
        XCTAssertEqual(result.legacyRecordIDs, [legacy])
        XCTAssertEqual(result.adoptedRecordIDs, [])
        XCTAssertEqual(try database.count("SELECT COUNT(*) FROM messages"), 1)
        XCTAssertEqual(try database.count("SELECT COUNT(*) FROM conversations"), 1)
    }

    // MARK: - Settings and paths

    func test_theMemorySwitchMovesToItsNewKeyAndKeepsTheUsersValue() throws {
        let suite = "cotabby-memory-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: MemoryEngineController.legacyEnabledDefaultsKey)
        MemoryEngineController.migrateEnabledFlag(in: defaults)
        XCTAssertEqual(defaults.object(forKey: MemoryEngineController.enabledDefaultsKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: MemoryEngineController.legacyEnabledDefaultsKey) as? Bool, true,
                       "kept for going back to an earlier build")

        // The new key, once written, wins.
        defaults.set(false, forKey: MemoryEngineController.enabledDefaultsKey)
        MemoryEngineController.migrateEnabledFlag(in: defaults)
        XCTAssertEqual(defaults.object(forKey: MemoryEngineController.enabledDefaultsKey) as? Bool, false)

        // Never set: stays unset (off).
        let fresh = "cotabby-memory-migration-\(UUID().uuidString)"
        let empty = try XCTUnwrap(UserDefaults(suiteName: fresh))
        defer { empty.removePersistentDomain(forName: fresh) }
        MemoryEngineController.migrateEnabledFlag(in: empty)
        XCTAssertNil(empty.object(forKey: MemoryEngineController.enabledDefaultsKey))
    }

    @MainActor
    func test_theControllerReadsTheSwitchAnEarlierBuildSaved() throws {
        let suite = "cotabby-memory-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "cotabbyMemoryServiceEnabled")
        let controller = MemoryEngineController(
            paths: MemoryPaths(root: directory), userDefaults: defaults, keyStore: FixedKeyStore(key: key),
            isOnACPower: { true }
        )
        Self.retained.append(controller)
        XCTAssertTrue(controller.isEnabled)
    }

    func test_thePathsAreTheOnesEarlierBuildsUsed() {
        let paths = MemoryPaths(root: URL(fileURLWithPath: "/Users/someone/Library/Application Support/Cotabby Dev/Memory"))
        XCTAssertEqual(paths.dataDirectory.path, "/Users/someone/Library/Application Support/Cotabby Dev/Memory/data")
        XCTAssertEqual(paths.modelsDirectory.path, "/Users/someone/Library/Application Support/Cotabby Dev/Memory/Models")
        XCTAssertEqual(MemoryEngine.Paths(dataDirectory: paths.dataDirectory).store.lastPathComponent, "messages.sqlite")
        XCTAssertEqual(MemoryEngine.Paths(dataDirectory: paths.dataDirectory).configuration.lastPathComponent, "config.json")
        XCTAssertTrue(MemoryPaths.standard().root.path.hasSuffix("/Memory"))
        // The Python leftovers never include the store, its settings or the model.
        let doomed = Set(paths.obsoleteItems.map(\.path))
        XCTAssertFalse(doomed.contains { $0.hasPrefix(paths.modelsDirectory.path) })
        XCTAssertFalse(doomed.contains(MemoryEngine.Paths(dataDirectory: paths.dataDirectory).store.path))
        XCTAssertFalse(doomed.contains(paths.dataDirectory.path))
    }

    /// A settings file as the earlier build wrote it, with answer settings and per-source choices:
    /// everything survives a load and save by this build.
    func test_anEarlierSettingsFileKeepsEveryChoice() throws {
        let file = directory.appendingPathComponent("config.json")
        try Data("""
        {
          "answers": { "disabled_apps": ["com.apple.mail"], "enabled": true, "minimum_confidence": 0.6 },
          "index": { "chunk_overlap": 20, "chunk_size": 120, "top_k": 5, "vector_weight": 0.5 },
          "privacy": { "excluded_conversations": ["x@s.whatsapp.net"], "excluded_participants": ["bob"], "retention_days": 90 },
          "sources": {
            "teams": { "answer_source": true, "enabled": true, "options": {} },
            "whatsapp": { "enabled": true, "options": {} },
            "documents": { "answer_source": false, "enabled": false, "options": { "folder": "/tmp/notes" } }
          }
        }
        """.utf8).write(to: file)
        let loaded = MemoryEngine.loadConfiguration(file)
        try MemoryEngine.saveConfiguration(loaded, to: file)
        let saved = MemoryEngine.loadConfiguration(file)
        XCTAssertEqual(saved, loaded)
        XCTAssertEqual(saved.answers.enabled, true)
        XCTAssertEqual(saved.answers.minimumConfidence, 0.6)
        XCTAssertEqual(saved.answers.disabledApps, ["com.apple.mail"])
        XCTAssertEqual(saved.sources["teams"]?.answerSource, true)
        XCTAssertNil(saved.sources["whatsapp"]?.answerSource, "an untouched choice stays untouched")
        XCTAssertEqual(saved.sources["documents"]?.answerSource, false)
        XCTAssertEqual(saved.sources["documents"]?.options["folder"], "/tmp/notes")
        XCTAssertEqual(saved.enabledSourceIDs, ["teams", "whatsapp"])
        XCTAssertEqual(saved.privacy.retentionDays, 90)
        XCTAssertEqual(saved.index.topK, 5)
    }

    @MainActor private static var retained: [AnyObject] = []
}

/// A key store that always has the test key and never touches the Keychain.
private struct FixedKeyStore: TypingHistoryKeyStore {
    let key: SymmetricKey
    func existingKey() throws -> SymmetricKey? { key }
    func createKey() throws -> SymmetricKey { key }
    func deleteKey() throws {}
}

/// The fixture's direct line to the SQLite file, standing in for what the earlier code wrote.
private final class RawDatabase {
    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }

    func count(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 3) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func close() {
        sqlite3_close(handle)
        handle = nil
    }
}
