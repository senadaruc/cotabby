import XCTest
@testable import Cotabby

/// Memory for a rewrite comes from the conversation the focused window names, then from the same
/// title in other sources; never from a global search. Style examples come only from the app's own
/// conversation and only from the user's own messages.
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

    private let conversation = MemoryConversation(source: "whatsapp", conversationId: "c1", title: "Richard",
                                                  participants: ["Richard"], lastTimestamp: 0)

    private func hit(_ text: String, sender: String = "Richard", fromMe: Bool = false) -> MemorySearchResult.Hit {
        MemorySearchResult.Hit(recordId: UUID().uuidString, source: "whatsapp", conversationId: "c1", conversationTitle: "Richard",
                               sender: sender, isFromMe: fromMe, timestamp: 0, subject: nil, text: text, score: 1,
                               similarity: 0.8, via: "vector")
    }

    private func message(_ text: String, fromMe: Bool) -> MemoryStore.StoredMessage {
        MemoryStore.StoredMessage(recordID: UUID().uuidString, source: "whatsapp", conversationID: "c1", conversationKey: "k",
                                  sender: fromMe ? "Me" : "Richard", isFromMe: fromMe, timestamp: 0, subject: nil, text: text)
    }

    private func input() -> FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(bundleIdentifier: "net.whatsapp.WhatsApp", windowTitle: "Richard")
    }

    func test_factsAndOwnStyleFromTheAppsConversation() async {
        let search = StubSearch()
        search.resultsBySources[["whatsapp"]] = MemorySearchResult(scope: "conversation", conversation: conversation, elapsedMs: 1,
                                                                   hits: (1...8).map { hit("fact \($0)") })
        search.messages = [message("Hi Richard, see you then. Best regards, Senad", fromMe: true),
                           message("Great, the 28th works", fromMe: false)]
        let gatherer = RewriteMemoryGatherer(search: search, sourcesByBundle: { ["net.whatsapp.WhatsApp": ["whatsapp"], "com.apple.mail": ["apple_mail"]] })
        Self.retained.append(gatherer)

        let memory = await gatherer.gather(for: input(), selection: "dinner 27th or 28th")
        XCTAssertEqual(memory?.facts.count, 6)
        XCTAssertEqual(memory?.styleExamples, ["Hi Richard, see you then. Best regards, Senad"])
        XCTAssertFalse(search.scopes.contains { $0.global })
    }

    func test_fallsBackToOtherSourcesWithoutStyle() async {
        let search = StubSearch()
        search.resultsBySources[["apple_mail"]] = MemorySearchResult(scope: "conversation", conversation: conversation, elapsedMs: 1,
                                                                     hits: [hit("Richard asked about cigars")])
        search.messages = [message("Dear Richard, …", fromMe: true)]
        let gatherer = RewriteMemoryGatherer(search: search, sourcesByBundle: { ["com.apple.mail": ["apple_mail"]] })
        Self.retained.append(gatherer)

        let memory = await gatherer.gather(for: input(), selection: "the book for cigars")
        XCTAssertEqual(memory?.facts.map(\.text), ["Richard asked about cigars"])
        XCTAssertEqual(memory?.styleExamples, [], "Mail must not stand as the style of a chat message")
        XCTAssertFalse(search.scopes.contains { $0.global })
    }

    func test_nothingFoundIsNil() async {
        let search = StubSearch()
        let gatherer = RewriteMemoryGatherer(search: search, sourcesByBundle: { ["net.whatsapp.WhatsApp": ["whatsapp"]] })
        Self.retained.append(gatherer)
        let memory = await gatherer.gather(for: input(), selection: "anything")
        XCTAssertNil(memory)
    }
}
