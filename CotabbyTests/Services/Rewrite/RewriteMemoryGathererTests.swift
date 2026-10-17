import XCTest
@testable import Cotabby

/// Memory for a rewrite comes only from the conversation the focused window names, in the focused
/// app's own sources; never from another app's history, a mail window or a global search. Style
/// examples come only from that conversation and only from the user's own messages.
@MainActor
final class RewriteMemoryGathererTests: XCTestCase {
    private static var retained: [AnyObject] = []

    @MainActor
    private final class StubSearch: RewriteMemorySearching {
        var resultsBySources: [[String]: MemorySearchResult] = [:]
        var messages: [MemoryStore.StoredMessage] = []
        private(set) var scopes: [MemoryEngine.Scope] = []
        func search(query: String, scope: MemoryEngine.Scope) async -> MemorySearchResult? {
            scopes.append(scope)
            return resultsBySources[scope.sources] ?? .empty
        }
        func latestMessages(source: String, conversationID: String, limit: Int) async -> [MemoryStore.StoredMessage] { messages }
    }

    private let conversation = MemoryConversation(source: "whatsapp", conversationId: "c1", title: "Charlie",
                                                  participants: ["Charlie"], lastTimestamp: 0)

    private func hit(_ text: String, sender: String = "Charlie", fromMe: Bool = false) -> MemorySearchResult.Hit {
        MemorySearchResult.Hit(recordId: UUID().uuidString, source: "whatsapp", conversationId: "c1", conversationTitle: "Charlie",
                               sender: sender, isFromMe: fromMe, timestamp: 0, subject: nil, text: text, score: 1,
                               similarity: 0.8, via: "vector")
    }

    private func message(_ text: String, fromMe: Bool) -> MemoryStore.StoredMessage {
        MemoryStore.StoredMessage(recordID: UUID().uuidString, source: "whatsapp", conversationID: "c1", conversationKey: "k",
                                  sender: fromMe ? "Me" : "Charlie", isFromMe: fromMe, timestamp: 0, subject: nil, text: text)
    }

    private func input() -> FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(bundleIdentifier: "net.whatsapp.WhatsApp", windowTitle: "Charlie")
    }

    func test_factsAndOwnStyleFromTheAppsConversation() async {
        let search = StubSearch()
        search.resultsBySources[["whatsapp"]] = MemorySearchResult(scope: "conversation", conversation: conversation, elapsedMs: 1,
                                                                   hits: (1...8).map { hit("fact \($0)") })
        search.messages = [message("Hi Charlie, see you then. Best regards, Alex", fromMe: true),
                           message("Great, the 28th works", fromMe: false)]
        let gatherer = RewriteMemoryGatherer(search: search, sourcesByBundle: { ["net.whatsapp.WhatsApp": ["whatsapp"], "com.apple.mail": ["apple_mail"]] })
        Self.retained.append(gatherer)

        let memory = await gatherer.gather(for: input(), selection: "dinner 27th or 28th")
        XCTAssertEqual(memory?.facts.count, 6)
        XCTAssertEqual(memory?.styleExamples, ["Hi Charlie, see you then. Best regards, Alex"])
        XCTAssertFalse(search.scopes.contains { $0.global })
    }

    /// The same title in another app is not the same conversation: titles never cross apps.
    func test_aTitleNeverCrossesIntoAnotherAppsHistory() async {
        let search = StubSearch()
        search.resultsBySources[["teams"]] = MemorySearchResult(scope: "conversation", conversation: conversation, elapsedMs: 1,
                                                                hits: [hit("Charlie asked about hiking")])
        let gatherer = RewriteMemoryGatherer(search: search, sourcesByBundle: { ["com.microsoft.teams2": ["teams"]] })
        Self.retained.append(gatherer)

        let memory = await gatherer.gather(for: input(), selection: "the book for hiking")
        XCTAssertNil(memory)
        XCTAssertTrue(search.scopes.isEmpty, "WhatsApp has no source of its own here, so nothing is searched")
    }

    /// A mail window names no conversation memory may use (its subject says nothing of who the
    /// mail is for, and its body is the other person's to shape).
    func test_aMailWindowGetsNoMemory() async {
        let search = StubSearch()
        search.resultsBySources[["apple_mail"]] = MemorySearchResult(scope: "conversation", conversation: conversation, elapsedMs: 1,
                                                                     hits: [hit("Charlie asked about hiking")])
        let gatherer = RewriteMemoryGatherer(search: search, sourcesByBundle: { ["com.apple.mail": ["apple_mail"]] })
        Self.retained.append(gatherer)
        let mail = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "com.apple.mail",
            trailingText: "\n\nOn 3 Oct 2026, at 10:00, Charlie <charlie@example.com> wrote:\n> Which book?",
            windowTitle: "Re: Hiking"
        )

        let memory = await gatherer.gather(for: mail, selection: "the book for hiking")
        XCTAssertNil(memory)
        XCTAssertTrue(search.scopes.isEmpty)
    }

    func test_windowMemorySwitchOffGivesNoMemory() async {
        let search = StubSearch()
        search.resultsBySources[["whatsapp"]] = MemorySearchResult(scope: "conversation", conversation: conversation, elapsedMs: 1,
                                                                   hits: [hit("fact")])
        let gatherer = RewriteMemoryGatherer(search: search,
                                             sourcesByBundle: { ["net.whatsapp.WhatsApp": ["whatsapp"]] },
                                             isAllowed: { _ in false })
        Self.retained.append(gatherer)

        let memory = await gatherer.gather(for: input(), selection: "dinner 27th or 28th")
        XCTAssertNil(memory)
        XCTAssertTrue(search.scopes.isEmpty)
    }

    func test_nothingFoundIsNil() async {
        let search = StubSearch()
        let gatherer = RewriteMemoryGatherer(search: search, sourcesByBundle: { ["net.whatsapp.WhatsApp": ["whatsapp"]] })
        Self.retained.append(gatherer)
        let memory = await gatherer.gather(for: input(), selection: "anything")
        XCTAssertNil(memory)
    }
}
