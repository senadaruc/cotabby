import Foundation
import XCTest
@testable import Cotabby

/// Pins how conversation memory reaches a prompt: which fields have a conversation, what is
/// searched, how retrieved messages read, where they sit in the prompt, and that they never reach
/// the endpoint engine.
final class ConversationMemoryTests: XCTestCase {
    private let sources = ["net.whatsapp.WhatsApp": ["whatsapp"], "com.apple.mail": ["apple_mail"]]

    // MARK: - Scope

    func test_scopeNeedsAnAppWithMemoryAndARealConversationTitle() {
        XCTAssertEqual(
            ConversationScopeResolver.scope(bundleIdentifier: "net.whatsapp.WhatsApp", conversationTitle: " Ayşe ", sourcesByBundle: sources),
            ConversationScope(title: "Ayşe", sources: ["whatsapp"])
        )
        XCTAssertNil(ConversationScopeResolver.scope(bundleIdentifier: "com.apple.TextEdit", conversationTitle: "Notes", sourcesByBundle: sources))
        XCTAssertNil(ConversationScopeResolver.scope(bundleIdentifier: "net.whatsapp.WhatsApp", conversationTitle: "WhatsApp", sourcesByBundle: sources))
        XCTAssertNil(ConversationScopeResolver.scope(bundleIdentifier: "com.apple.mail", conversationTitle: "New Message", sourcesByBundle: sources))
        XCTAssertNil(ConversationScopeResolver.scope(bundleIdentifier: "net.whatsapp.WhatsApp", conversationTitle: nil, sourcesByBundle: sources))
    }

    func test_teamsWindowTitlesNameTheOpenConversation() {
        let teams = ["com.microsoft.teams2": ["teams"]]
        XCTAssertEqual(
            ConversationScopeResolver.scope(bundleIdentifier: "com.microsoft.teams2",
                                            conversationTitle: "Chat | Ali Pakkan | imperum.io | senad@imperum.io | Microsoft Teams",
                                            sourcesByBundle: teams),
            ConversationScope(title: "Ali Pakkan", sources: ["teams"])
        )
        XCTAssertEqual(ConversationScopeResolver.teamsConversationTitle("Sohbet | POC Planning | imperum.io | Microsoft Teams"), "POC Planning")
        XCTAssertNil(ConversationScopeResolver.teamsConversationTitle("Activity | imperum.io | senad@imperum.io | Microsoft Teams"))
        XCTAssertNil(ConversationScopeResolver.teamsConversationTitle("Microsoft Teams"))
    }

    func test_queryUsesCompleteBlocksSoItStaysStableWhileTyping() {
        let scope = ConversationScope(title: "Ayşe", sources: ["whatsapp"])
        XCTAssertEqual(ConversationScopeResolver.query(precedingText: "about the", scope: scope), "Ayşe")
        let eight = "one two three four five six seven eight"
        XCTAssertEqual(ConversationScopeResolver.query(precedingText: eight + " nine ten", scope: scope), eight)
    }

    // MARK: - Lines

    func test_linesAreChronologicalAttributedAndBounded() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let newer = Date(timeIntervalSince1970: 1_789_000_000)
        let older = newer.addingTimeInterval(-86_400 * 3)
        let lines = MemorySnippetFormatter.lines([
            .init(sender: "Ayşe", isFromMe: false, timestamp: newer, text: "Paid\nyesterday"),
            .init(sender: "Me", isFromMe: true, timestamp: older, text: "Is the invoice paid?"),
            .init(sender: "Ayşe", isFromMe: false, timestamp: newer, text: String(repeating: "x", count: 500))
        ], calendar: calendar)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("You: Is the invoice paid?"))
        XCTAssertTrue(lines[1].hasSuffix("Ayşe: Paid yesterday"))
        XCTAssertLessThanOrEqual(lines[2].count, MemorySnippetFormatter.maximumLineCharacters + 20)
        XCTAssertLessThanOrEqual(lines.joined(separator: "\n").count, MemorySnippetFormatter.maximumTotalCharacters)
    }

    // MARK: - Prompt

    func test_memorySectionSitsInTheBasePromptAboveTheCaretText() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "Great, so we are",
            applicationName: "WhatsApp",
            userName: nil,
            memorySnippets: ["12 Sep · Ayşe: the invoice is paid"]
        )
        let memory = try? XCTUnwrap(prompt.range(of: "Earlier in this conversation:\n12 Sep · Ayşe: the invoice is paid"))
        let caret = prompt.range(of: "Great, so we are")
        XCTAssertNotNil(memory)
        XCTAssertLessThan(memory!.lowerBound, caret!.lowerBound)
        XCTAssertFalse(BaseCompletionPromptRenderer.prompt(prefixText: "Hi", applicationName: "WhatsApp", userName: nil)
            .contains("Earlier in this conversation"))
    }

    func test_theFactoryDropsMemoryForTheEndpointEngine() {
        let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello there")
        let local = SuggestionRequestFactory.buildRequest(
            context: context, settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .llamaOpenSource),
            configuration: .standard, memorySnippets: ["12 Sep · Ayşe: hi"]
        ).request
        let endpoint = SuggestionRequestFactory.buildRequest(
            context: context, settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .openAICompatible),
            configuration: .standard, memorySnippets: ["12 Sep · Ayşe: hi"]
        ).request
        XCTAssertEqual(local.memorySnippets, ["12 Sep · Ayşe: hi"])
        XCTAssertTrue(local.prompt.contains("Earlier in this conversation"))
        XCTAssertEqual(endpoint.memorySnippets, [])
        XCTAssertFalse(endpoint.prompt.contains("Ayşe"))
    }

    // MARK: - Retriever gates

    @MainActor
    func test_retrieverReturnsNothingWhereMemoryMustNotApply() {
        let retriever = MemoryRetriever(client: MemoryServiceClient(socketPath: "/tmp/cm-none.sock"), isServiceRunning: { true })
        Self.retained.append(retriever)
        retriever.updateSources([])
        let context = CotabbyTestFixtures.focusedInputContext(bundleIdentifier: "net.whatsapp.WhatsApp", windowTitle: "Ayşe")
        XCTAssertEqual(retriever.memorySnippets(for: context, engine: .llamaOpenSource), [], "no enabled source")
        XCTAssertFalse(retriever.hasMemory(forApplication: "net.whatsapp.WhatsApp"))
        XCTAssertEqual(retriever.memorySnippets(for: context, engine: .openAICompatible), [], "endpoint never")
    }

    @MainActor private static var retained: [AnyObject] = []
}
