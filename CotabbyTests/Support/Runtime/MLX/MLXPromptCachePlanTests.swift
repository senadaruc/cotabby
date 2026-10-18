import XCTest
@testable import Cotabby

final class MLXPromptCachePlanTests: XCTestCase {
    func test_aTypedCharacterReusesThePromptAndDropsTheGeneratedTail() {
        // The cache holds the old prompt plus two generated tokens; the new prompt adds one token.
        let plan = MLXPromptCachePlan.decision(cachedPrompt: [1, 2, 3, 4], cacheLength: 6, newPrompt: [1, 2, 3, 4, 5], canTrim: true)
        XCTAssertEqual(plan, .init(reusedTokens: 4, trimCount: 2))
    }

    func test_aBackspaceTrimsBackToTheSharedPrefix() {
        let plan = MLXPromptCachePlan.decision(cachedPrompt: [1, 2, 3, 4, 5], cacheLength: 7, newPrompt: [1, 2, 3, 4], canTrim: true)
        XCTAssertEqual(plan, .init(reusedTokens: 3, trimCount: 4), "the last prompt token is always decoded for its logits")
    }

    func test_theSamePromptStillDecodesItsLastToken() {
        let plan = MLXPromptCachePlan.decision(cachedPrompt: [1, 2, 3], cacheLength: 5, newPrompt: [1, 2, 3], canTrim: true)
        XCTAssertEqual(plan, .init(reusedTokens: 2, trimCount: 3))
    }

    func test_anUnrelatedPromptRebuilds() {
        XCTAssertTrue(MLXPromptCachePlan.decision(cachedPrompt: [1, 2, 3], cacheLength: 3, newPrompt: [9, 2, 3], canTrim: true).rebuild)
    }

    func test_anUntrimmableOrEmptyCacheRebuilds() {
        XCTAssertTrue(MLXPromptCachePlan.decision(cachedPrompt: [1, 2, 3], cacheLength: 3, newPrompt: [1, 2, 3, 4], canTrim: false).rebuild)
        XCTAssertTrue(MLXPromptCachePlan.decision(cachedPrompt: [], cacheLength: 0, newPrompt: [1, 2], canTrim: true).rebuild)
    }
}
