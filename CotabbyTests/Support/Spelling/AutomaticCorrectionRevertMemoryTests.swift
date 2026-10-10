import XCTest
@testable import Cotabby

/// Verifies that an automatic typo fix the user undid is recognised when the word comes back, and
/// that the same misspelling elsewhere is not mistaken for an undo.
final class AutomaticCorrectionRevertMemoryTests: XCTestCase {
    private let search = "com.google.Chrome|42|search"

    func test_retypedWordAtTheCorrectedPositionIsARestoration() {
        // LinkedIn search: "cribl" became "crib", the user pressed Backspace, typed "l" and Space.
        var memory = AutomaticCorrectionRevertMemory()
        memory.recordCorrection(of: "cribl", textBeforeWord: "", fieldKey: search)

        XCTAssertTrue(memory.isRestoration(of: "cribl", textBeforeWord: "", fieldKey: search))
    }

    func test_restorationAfterEarlierTextKeepsItsPosition() {
        var memory = AutomaticCorrectionRevertMemory()
        memory.recordCorrection(of: "Cribl", textBeforeWord: "We moved our logs to ", fieldKey: search)

        XCTAssertTrue(memory.isRestoration(of: "Cribl", textBeforeWord: "We moved our logs to ", fieldKey: search))
    }

    func test_sameTypoElsewhereInTheTextIsStillFixed() {
        var memory = AutomaticCorrectionRevertMemory()
        memory.recordCorrection(of: "teh", textBeforeWord: "I sent ", fieldKey: search)

        XCTAssertFalse(memory.isRestoration(of: "teh", textBeforeWord: "I sent the report and ", fieldKey: search))
    }

    func test_sameTypoInAnotherFieldIsStillFixed() {
        var memory = AutomaticCorrectionRevertMemory()
        memory.recordCorrection(of: "cribl", textBeforeWord: "", fieldKey: search)

        XCTAssertFalse(memory.isRestoration(of: "cribl", textBeforeWord: "", fieldKey: "com.apple.mail|7|body"))
    }

    func test_differentWordAtTheSamePositionIsNotARestoration() {
        var memory = AutomaticCorrectionRevertMemory()
        memory.recordCorrection(of: "cribl", textBeforeWord: "", fieldKey: search)

        XCTAssertFalse(memory.isRestoration(of: "splnk", textBeforeWord: "", fieldKey: search))
    }

    func test_onlyTheMostRecentCorrectionsAreRemembered() {
        var memory = AutomaticCorrectionRevertMemory()
        memory.recordCorrection(of: "first", textBeforeWord: "0 ", fieldKey: search)
        for index in 1...AutomaticCorrectionRevertMemory.capacity {
            memory.recordCorrection(of: "word\(index)", textBeforeWord: "\(index) ", fieldKey: search)
        }

        XCTAssertFalse(memory.isRestoration(of: "first", textBeforeWord: "0 ", fieldKey: search))
        XCTAssertTrue(memory.isRestoration(of: "word1", textBeforeWord: "1 ", fieldKey: search))
    }

    func test_textBeforeWordRequiresTheCommittedWordAtTheEnd() {
        XCTAssertEqual(
            AutomaticCorrectionRevertMemory.textBeforeWord("cribl", delimiter: " ", in: "logs to cribl "),
            "logs to "
        )
        XCTAssertEqual(AutomaticCorrectionRevertMemory.textBeforeWord("cribl", delimiter: " ", in: "cribl "), "")
        XCTAssertNil(AutomaticCorrectionRevertMemory.textBeforeWord("cribl", delimiter: " ", in: "cribl"))
        XCTAssertNil(AutomaticCorrectionRevertMemory.textBeforeWord("cribl", delimiter: " ", in: "crib "))
    }
}
