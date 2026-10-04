import CryptoKit
import Foundation
import XCTest
@testable import Cotabby

/// Pins conversation memory's encrypted store: byte compatibility with what the Python service
/// wrote (so the existing store opens without re-syncing), the scope keys, idempotent upserts,
/// filter-first keyword search, purging, and that nothing personal is readable on disk.
final class MemoryStoreTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(data: Data(0..<32))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(key: SymmetricKey? = nil) throws -> MemoryStore {
        try MemoryStore(path: directory.appendingPathComponent("messages.sqlite"), vault: MemoryVault(masterKey: key ?? self.key))
    }

    private func record(
        _ conversation: String, _ text: String, sender: String = "Ayşe", me: Bool = false, title: String? = nil,
        participants: [String] = [], at timestamp: Date = Date(), id: String? = nil
    ) -> MemoryIngestRecord {
        MemoryIngestRecord(
            sourceMessageID: id ?? "\(conversation):\(text)", conversationID: conversation,
            conversationTitle: title ?? conversation, sender: sender, isFromMe: me, timestamp: timestamp,
            text: text, participants: participants, subject: nil
        )
    }

    // MARK: - Compatibility with the Python service

    /// Values produced by the Python service's `vault.py` with the key bytes 0..<32.
    func test_valuesSealedByThePythonServiceOpenAndTagsMatch() throws {
        let vault = MemoryVault(masterKey: key)
        let sealed = Data(hex: "80dc6f628849e8ace07efe9369c8e34f23f979564036f325faf642dc36bbb6592fe4d24d53979801bab69c57554a160d9b1ab425a2231180a2c83528bd0863")
        XCTAssertEqual(try vault.open(sealed), "Merhaba dünya, the invoice is paid")
        XCTAssertEqual(vault.tag("title\u{1f}poc results"), "195de12496601a745ae14d3ec29655f9")
        XCTAssertNoThrow(try vault.verify(Data(hex: "2c78aafa8701d9ffeda9a7904a36fd8a5b37052a99a8a60919c1e5328d796ffe3087a9a9223a0f8fbb11a80365aa0b78a4257a33f941e1")))
        XCTAssertEqual(MemoryStore.recordID(source: "whatsapp", sourceMessageID: "A1"), "whatsapp:86da5e534dac21b0e09b")
        XCTAssertEqual(try vault.open(try vault.seal("round trip")), "round trip")
    }

    func test_aStoreOpenedWithAnotherKeyIsRefused() throws {
        _ = try makeStore()
        XCTAssertThrowsError(try makeStore(key: SymmetricKey(data: Data(repeating: 0, count: 32))))
    }

    // MARK: - Writing

    func test_participantsNeverIncludeTheUser() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [
            record("c1", "hello there friend", sender: "Me", me: true, participants: ["Ayşe"]),
            record("c1", "hi back to you", sender: "Ayşe"),
        ])
        XCTAssertEqual(try store.conversation(source: "chat", conversationID: "c1")?.participants, ["ayşe"])
    }

    func test_upsertIsIdempotentAndEditsNeedIndexingAgain() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.upsert(source: "chat", records: [record("c1", "original text here", id: "m1")]).changed, 1)
        let message = try XCTUnwrap(try store.unindexedMessages(sources: ["chat"], limit: 10).first)
        try store.saveIndexEntries([(message, [("p1", HalfPrecision.encode([0.5, 0.5, 0.5, 0.5]))])], model: "m")
        XCTAssertEqual(try store.unindexedCount(sources: ["chat"]), 0)
        XCTAssertEqual(try store.upsert(source: "chat", records: [record("c1", "original text here", id: "m1")]).changed, 0)
        XCTAssertEqual(try store.upsert(source: "chat", records: [record("c1", "edited text here", id: "m1")]).replacedRecordIDs.count, 1)
        XCTAssertEqual(try store.unindexedMessages(sources: ["chat"], limit: 10).map(\.text), ["edited text here"])
        XCTAssertTrue(try store.vectors(model: "m").isEmpty, "an edited message loses its old vector")
    }

    func test_vectorsRoundTripAndAnotherModelsVectorsAreDropped() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [record("c1", "the invoice is paid")])
        let message = try XCTUnwrap(try store.unindexedMessages(sources: ["chat"], limit: 1).first)
        let vector = HalfPrecision.encode([0.25, -0.5, 1, 0])
        try store.saveIndexEntries([(message, [("p1", vector)])], model: "old-model")
        XCTAssertEqual(try store.vectors(model: "old-model").first?.vector, vector)
        XCTAssertEqual(try store.invalidateVectors(notMadeBy: "new-model"), 1)
        XCTAssertTrue(try store.vectors(model: "old-model").isEmpty)
    }

    func test_purgeRemovesExcludedPeopleAndExpiredMessages() throws {
        let store = try makeStore()
        let old = Date().addingTimeInterval(-400 * 86_400)
        try store.upsert(source: "chat", records: [
            record("c1", "from the boss today", sender: "Boss"),
            record("c2", "an old message here", at: old),
            record("c3", "a fresh message here"),
        ])
        let removed = try store.purge(excludedConversations: [], excludedParticipants: ["boss"],
                                      olderThan: Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(try store.unindexedMessages(sources: ["chat"], limit: 10).map(\.conversationID), ["c3"])
    }

    // MARK: - Reading

    func test_keywordSearchNeverLeavesTheGivenConversationsAndMatchesPrefixes() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [
            record("c1", "the invoice is paid"), record("c1", "lunch tomorrow"), record("c2", "the invoice is late", sender: "Can"),
        ])
        let scope = [(source: "chat", conversationKey: store.conversationKey(source: "chat", conversationID: "c1"))]
        XCTAssertEqual(try store.keywordSearch(query: "invo", conversations: scope, limit: 5).map(\.text), ["the invoice is paid"])
    }

    func test_titlesFindConversationsOnlyInTheGivenSources() throws {
        let store = try makeStore()
        try store.upsert(source: "apple_mail", records: [record("t1", "numbers are in", title: "POC results")])
        try store.upsert(source: "whatsapp", records: [record("w1", "hi", title: "POC results")])
        XCTAssertEqual(try store.findConversations(title: "Re: poc results", sources: ["apple_mail"]).map(\.source), ["apple_mail"])
    }

    func test_sameAudienceNeedsExactlyTheSamePeople() throws {
        let store = try makeStore()
        try store.upsert(source: "chat", records: [record("dm", "private note", me: true, participants: ["Ali"])])
        try store.upsert(source: "chat", records: [record("group", "group note", me: true, participants: ["Ali", "Valon"])])
        try store.upsert(source: "mail", records: [record("thread", "mail to ali", me: true, participants: ["ali"])])
        let seen = try store.conversationsSeenBy(audience: ["Ali"], excluding: nil)
        XCTAssertEqual(Set(seen.map(\.source)), ["chat", "mail"])
        XCTAssertFalse(seen.contains { $0.conversationKey == store.conversationKey(source: "chat", conversationID: "group") })
    }

    func test_taggedKeywordSearchFindsWholeWordsAcrossConversations() throws {
        let store = try makeStore()
        try store.upsert(source: "outlook", records: [
            record("t1", "THY POC passed all detection tests"), record("t2", "lunch on friday"),
        ])
        let messages = try store.unindexedMessages(sources: ["outlook"], limit: 10)
        try store.saveIndexEntries(messages.map { ($0, []) }, model: "m")
        let hits = try store.taggedKeywordSearch(query: "how did the THY POC go?", sources: ["outlook"], limit: 5)
        XCTAssertEqual(try hits.compactMap { try store.message(recordID: $0)?.text }, ["THY POC passed all detection tests"])
        XCTAssertTrue(try store.taggedKeywordSearch(query: "THY", sources: ["whatsapp"], limit: 5).isEmpty)
    }

    func test_nothingPersonalIsReadableOnDisk() throws {
        let store = try makeStore()
        let marker = "Zyxwvut-secret-plan"
        try store.upsert(source: "whatsapp", records: [
            record("whatsapp-ayse", "the \(marker) is ready", sender: "Ayşe Yılmaz", title: "Ayşe Yılmaz", participants: ["ayse@example.com"]),
        ])
        let message = try XCTUnwrap(try store.unindexedMessages(sources: ["whatsapp"], limit: 1).first)
        try store.saveIndexEntries([(message, [("p1", HalfPrecision.encode([1, 2, 3]))])], model: "m")
        try store.setCursor("cursor-\(marker)", source: "whatsapp")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file)
            for secret in [marker, "Ayşe", "ayse@example.com", "whatsapp-ayse", "secret", "ready"] {
                XCTAssertNil(data.range(of: Data(secret.utf8)), "\(secret) readable in \(file.lastPathComponent)")
            }
        }
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
