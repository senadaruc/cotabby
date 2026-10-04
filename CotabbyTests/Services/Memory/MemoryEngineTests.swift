import CryptoKit
import Foundation
import XCTest
@testable import Cotabby

/// Pins conversation memory's engine: the ingest pipeline, the scope rule suggestions rely on
/// (this conversation, then exactly the same people, never a guess), what answers may draw on, and
/// with the embedding model present, indexing and search by meaning end to end.
///
/// Without a model the engine searches by keywords only (the index is empty), which pins every
/// scope rule exactly and runs in milliseconds.
final class MemoryEngineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(sources: [String], modelURL: URL? = nil) throws -> MemoryEngine {
        let engine = try MemoryEngine(
            paths: MemoryEngine.Paths(dataDirectory: directory),
            masterKey: SymmetricKey(data: Data(0..<32)),
            modelURL: modelURL ?? directory.appendingPathComponent("none.gguf"),
            conditions: {
                EmbeddingSchedulePolicy.Conditions(isOnACPower: true, isLowPowerMode: false, thermalState: .nominal,
                                                   userIdleSeconds: 60, isGenerating: false, pendingPassages: 0)
            }
        )
        try engine.updateConfiguration { configuration in
            for source in sources { configuration.sources[source] = MemorySourceSettings(enabled: true) }
            configuration.index.vectorWeight = modelURL == nil ? 0 : 0.7
        }
        return engine
    }

    private func record(
        _ conversation: String, _ text: String, sender: String = "Ayşe", me: Bool = false, title: String? = nil,
        participants: [String] = [], at timestamp: Date = Date(), subject: String? = nil
    ) -> MemoryIngestRecord {
        MemoryIngestRecord(
            sourceMessageID: "\(conversation):\(text)", conversationID: conversation, conversationTitle: title ?? conversation,
            sender: sender, isFromMe: me, timestamp: timestamp, text: text, participants: participants, subject: subject
        )
    }

    private func scope(_ title: String, _ sources: [String]) -> MemoryEngine.Scope {
        var scope = MemoryEngine.Scope()
        scope.title = title
        scope.sources = sources
        return scope
    }

    // MARK: - Ingest

    func test_ingestDropsSecretsExclusionsAndExpiredMessagesAndStripsMailQuotes() throws {
        let engine = try makeEngine(sources: ["whatsapp", "apple_mail"])
        try engine.updateConfiguration { $0.privacy.excludedParticipants = ["Boss"] }
        let result = try engine.ingest(source: "whatsapp", records: [
            record("c1", "the invoice is paid", participants: ["Ayşe"]),
            record("c1", "Your verification code is 482913"),
            record("c2", "from the boss", sender: "Boss"),
            record("c3", "an old message", at: Date().addingTimeInterval(-400 * 86_400)),
        ], cursor: "4")
        XCTAssertEqual(result, MemoryEngine.IngestResult(stored: 1, dropped: 3))
        XCTAssertEqual(engine.cursor(source: "whatsapp"), "4")

        try engine.ingest(source: "apple_mail", records: [
            record("t1", "Numbers are in.\n\nOn Mon, Ayşe wrote:\n> old quoted text", title: "POC", subject: "POC")
        ], cursor: nil)
        let hits = engine.search(query: "numbers", scope: scope("POC", ["apple_mail"])).hits
        XCTAssertEqual(hits.map(\.text), ["Numbers are in."])
    }

    func test_aDisabledSourceStoresNothing() throws {
        let engine = try makeEngine(sources: ["whatsapp"])
        XCTAssertEqual(try engine.ingest(source: "apple_mail", records: [record("t1", "hello")], cursor: nil).stored, 0)
    }

    // MARK: - Scope rule

    func test_searchStaysInTheConversationThenTheSamePeople() throws {
        let engine = try makeEngine(sources: ["whatsapp", "apple_mail"])
        try engine.ingest(source: "whatsapp", records: [
            record("ayse-dm", "the invoice is paid", title: "Ayşe", participants: ["Ayşe"]),
            record("can-dm", "the invoice is late", sender: "Can", title: "Can", participants: ["Can"]),
        ], cursor: nil)
        try engine.ingest(source: "apple_mail", records: [
            record("thread", "invoice number 4417", title: "Invoice", participants: ["Ayşe"]),
        ], cursor: nil)

        let own = engine.search(query: "invoice", scope: scope("Ayşe", ["whatsapp"]), topK: 1)
        XCTAssertEqual(own.scope, "conversation")
        XCTAssertEqual(own.hits.map(\.text), ["the invoice is paid"])

        let widened = engine.search(query: "invoice", scope: scope("Ayşe", ["whatsapp"]), topK: 4)
        XCTAssertEqual(widened.scope, "person")
        XCTAssertEqual(Set(widened.hits.map(\.text)), ["the invoice is paid", "invoice number 4417"],
                       "Ayşe's mail thread, never Can's chat")
    }

    func test_unknownAmbiguousOrForeignAppTitlesFindNothing() throws {
        let engine = try makeEngine(sources: ["whatsapp", "apple_mail"])
        try engine.ingest(source: "whatsapp", records: [
            record("ali-1", "the budget is fixed", sender: "Ali", title: "Ali"),
            record("ali-2", "the budget is late", sender: "Ali B", title: "Ali"),
        ], cursor: nil)
        XCTAssertEqual(engine.search(query: "budget", scope: scope("Ali", ["whatsapp"])).scope, "none", "two chats called Ali")
        XCTAssertEqual(engine.search(query: "budget", scope: scope("Nobody", ["whatsapp"])).hits, [])
        XCTAssertEqual(engine.search(query: "budget", scope: scope("Ali", ["apple_mail"])).hits, [], "titles never cross apps")
    }

    func test_disabledSourcesAreNeverSearched() throws {
        let engine = try makeEngine(sources: ["whatsapp"])
        try engine.ingest(source: "whatsapp", records: [record("c1", "the invoice is paid", title: "Ayşe")], cursor: nil)
        try engine.updateConfiguration { $0.sources["whatsapp"]?.enabled = false }
        XCTAssertEqual(engine.search(query: "invoice", scope: scope("Ayşe", ["whatsapp"])).hits, [])
    }

    func test_teamsGroupsNeverShareMemoryWithOneToOneChats() throws {
        let engine = try makeEngine(sources: ["teams"])
        try engine.ingest(source: "teams", records: [
            record("dm", "my salary negotiation is private", sender: "Ali Pakkan", title: "Ali Pakkan", participants: ["8:orgid:ali"]),
            record("group", "the release is on Friday", sender: "Ali Pakkan", title: "Ops",
                   participants: ["8:orgid:ali", "teams-group:group"]),
        ], cursor: nil)
        XCTAssertTrue(engine.search(query: "salary", scope: scope("Ops", ["teams"])).hits.isEmpty)
        XCTAssertTrue(engine.search(query: "release", scope: scope("Ali Pakkan", ["teams"])).hits.isEmpty)
    }

    // MARK: - Answers

    func test_answerSearchUsesOnlyAnswerSourcesAndTheCurrentConversationAndNeverTheQuestion() throws {
        let engine = try makeEngine(sources: ["outlook", "whatsapp", "teams"])
        try engine.ingest(source: "outlook", records: [
            record("thy", "The THY POC passed all detection tests", sender: "Irem", title: "THY - Imperum"),
        ], cursor: nil)
        try engine.ingest(source: "whatsapp", records: [
            record("family", "THY flight to Izmir is at 9", title: "Family"),
        ], cursor: nil)
        let question = record("ali", "How did the THY POC go?", sender: "Ali", title: "Ali Pakkan")
        try engine.ingest(source: "teams", records: [question], cursor: nil)
        let questionID = MemoryStore.recordID(source: "teams", sourceMessageID: question.sourceMessageID)

        let result = engine.answerSearch(question: "How did the THY POC go?", sources: ["outlook"],
                                         currentConversation: ("teams", "ali"), excludingRecordIDs: [questionID])
        XCTAssertEqual(result.scope, "answer")
        XCTAssertEqual(result.hits.map(\.text), ["The THY POC passed all detection tests"],
                       "WhatsApp is not an answer source here, and the question is not its own answer")
    }

    // MARK: - Schedule policy

    func test_schedulePolicyRunsSmallDeltasAnytimeAndBacklogsOnlyWhenPluggedInIdleAndCool() {
        var conditions = EmbeddingSchedulePolicy.Conditions(
            isOnACPower: false, isLowPowerMode: false, thermalState: .nominal, userIdleSeconds: 0,
            isGenerating: false, pendingPassages: 50
        )
        XCTAssertEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.pendingPassages = 5_000
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run, "a backlog waits for power")
        conditions.isOnACPower = true
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run, "and for the user to pause")
        conditions.userIdleSeconds = 60
        XCTAssertEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.thermalState = .serious
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.thermalState = .nominal
        conditions.isLowPowerMode = true
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.isLowPowerMode = false
        conditions.isGenerating = true
        XCTAssertNotEqual(EmbeddingSchedulePolicy.decide(conditions), .run)
        conditions.pendingPassages = 0
        XCTAssertEqual(EmbeddingSchedulePolicy.decide(conditions), .wait("Nothing to index"))
    }

    // MARK: - With the embedding model

    /// Indexing and search by meaning end to end (`COTABBY_TEST_EMBEDDING_MODEL_PATH`).
    func test_indexedMessagesAreFoundByMeaningWithinTheirScope() async throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_TEST_EMBEDDING_MODEL_PATH"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set COTABBY_TEST_EMBEDDING_MODEL_PATH to the embedding .gguf to run this test")
        }
        let engine = try makeEngine(sources: ["whatsapp"], modelURL: URL(fileURLWithPath: path))
        try engine.start()
        defer { engine.stop() }
        try engine.ingest(source: "whatsapp", records: [
            record("ayse", "The September invoice was paid by bank transfer.", title: "Ayşe", participants: ["Ayşe"]),
            record("ayse", "Yarın saat üçte Karaköy'de buluşalım.", title: "Ayşe", participants: ["Ayşe"]),
            record("can", "My invoice for September is still unpaid.", sender: "Can", title: "Can", participants: ["Can"]),
        ], cursor: nil)
        let deadline = Date().addingTimeInterval(30)
        while engine.status.passages < 3, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(engine.status.passages, 3)

        let result = engine.search(query: "was the payment made?", scope: scope("Ayşe", ["whatsapp"]), topK: 1)
        XCTAssertEqual(result.hits.first?.text, "The September invoice was paid by bank transfer.",
                       "found by meaning: 'payment' appears in neither message")
        XCTAssertGreaterThan(result.hits.first?.similarity ?? 0, 0.3)
        let turkish = engine.search(query: "when do we meet tomorrow", scope: scope("Ayşe", ["whatsapp"]), topK: 1)
        XCTAssertEqual(turkish.hits.first?.text, "Yarın saat üçte Karaköy'de buluşalım.", "across languages")
    }
}
