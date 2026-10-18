import XCTest
@testable import Cotabby

final class MLXHealingVocabularyTests: XCTestCase {
    private let pieces: [[UInt8]] = [" i", " in", " int", " intelligence", " intel", "nt", "\n", " in\n", ""].map { Array($0.utf8) }

    func test_tokensCoveringEveryTypedByteAreAllowed() {
        let vocabulary = MLXHealingVocabulary(pieces: pieces)
        // " int" typed: " int", " intelligence" and " intel" cover it; " i" and " in" do not.
        XCTAssertEqual(Set(vocabulary.matchingTokens(prefix: Array(" int".utf8), singleLine: false)), [2, 3, 4])
    }

    func test_withoutACoveringTokenShorterSpellingsAreAllowed() {
        let vocabulary = MLXHealingVocabulary(pieces: pieces)
        // Nothing starts with " inx": fall back to its exact front parts " i" and " in".
        XCTAssertEqual(Set(vocabulary.matchingTokens(prefix: Array(" inx".utf8), singleLine: false)), [0, 1])
    }

    func test_singleLineFieldsNeverReplayThroughALineBreak() {
        let vocabulary = MLXHealingVocabulary(pieces: pieces)
        XCTAssertEqual(Set(vocabulary.matchingTokens(prefix: Array(" in".utf8), singleLine: false)), [1, 2, 3, 4, 7])
        XCTAssertEqual(Set(vocabulary.matchingTokens(prefix: Array(" in".utf8), singleLine: true)), [1, 2, 3, 4])
    }

    func test_pieceBytesDecodeGemmaStyleTokens() {
        XCTAssertEqual(MLXHealingVocabulary.pieceBytes("▁network"), Array(" network".utf8))
        XCTAssertEqual(MLXHealingVocabulary.pieceBytes("<0x0A>"), [10])
        XCTAssertEqual(MLXHealingVocabulary.pieceBytes("<end_of_turn>"), [])
        XCTAssertEqual(MLXHealingVocabulary.pieceBytes("work"), Array("work".utf8))
    }
}
