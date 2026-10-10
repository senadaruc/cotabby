import XCTest
@testable import Cotabby

/// The rewrite prompt keeps the user's language and meaning, asks for the bare text, and states that
/// memory facts are for accuracy only.
final class RewritePromptBuilderTests: XCTestCase {
    private let draft = "Please let me know if te dates are ok and wors for you."

    func test_instructPromptCarriesRulesActionAndSelection() {
        let prompt = RewritePromptBuilder.instructPrompt(RewriteRequest(selection: draft, action: .fixGrammar, memory: .empty))
        XCTAssertTrue(prompt.system.contains("same language"))
        XCTAssertTrue(prompt.system.contains("Return only the rewritten text"))
        XCTAssertTrue(prompt.system.contains(RewritePromptBuilder.actionLine(.fixGrammar)))
        XCTAssertTrue(prompt.user.hasSuffix(draft))
        XCTAssertFalse(prompt.user.contains("Facts"))
    }

    func test_customInstructionIsQuotedAsTheInstruction() {
        let line = RewritePromptBuilder.actionLine(.custom("make it warmer"))
        XCTAssertTrue(line.contains("\"make it warmer\""))
    }

    func test_memoryAddsFactsAndStyleWithTheAccuracyRule() {
        let memory = RewriteMemoryContext(
            facts: [.init(text: "Dinner moved to the 28th.", source: "whatsapp", sender: "Richard")],
            styleExamples: ["Hi Richard, sounds good. Best regards, Senad"]
        )
        let prompt = RewritePromptBuilder.instructPrompt(RewriteRequest(selection: draft, action: .rewrite, memory: memory))
        XCTAssertTrue(prompt.user.contains("Richard: Dinner moved to the 28th."))
        XCTAssertTrue(prompt.user.contains("Hi Richard, sounds good."))
        XCTAssertTrue(prompt.system.contains("never add"))
    }

    func test_basePromptEndsReadyForTheRewrittenText() {
        let prompt = RewritePromptBuilder.basePrompt(RewriteRequest(selection: draft, action: .shorter, memory: .empty))
        XCTAssertTrue(prompt.hasSuffix("Draft: \(draft)\nRewritten:"))
        XCTAssertTrue(RewritePromptBuilder.baseStopSequences.contains("\nDraft:"))
    }

    func test_longFactsAreTrimmed() {
        let longFact = String(repeating: "x", count: 1_000)
        let memory = RewriteMemoryContext(facts: [.init(text: longFact, source: "mail", sender: "A")], styleExamples: [])
        let prompt = RewritePromptBuilder.instructPrompt(RewriteRequest(selection: draft, action: .rewrite, memory: memory))
        XCTAssertLessThan(prompt.user.count, 1_000)
    }
}
