import XCTest
@testable import Cotabby

/// The preview's warning says exactly what the rewrite changed, so the user can decide whether to
/// "Replace anyway". The case that prompted it: "1000% eminim" came back as "%100 eminim", and the
/// old message ("Not in your text or memory: 100") did not say that the number had changed.
final class RewriteChangeWarningTests: XCTestCase {
    func test_changedNumberNamesBothValues() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "AMA ben sana söyleyeyim 1000% eminim", rewrite: "AMA sana söyleyeyim, %100 eminim",
                                         unsupported: ["100"], usedMemory: false),
            "The number changed: you wrote 1000, the rewrite says 100."
        )
    }

    func test_severalChangedNumbers() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "dinner on the 27th or 28th", rewrite: "dinner on the 26th or 29th",
                                         unsupported: ["26", "29"], usedMemory: false),
            "Numbers changed: you wrote 27, 28; the rewrite says 26, 29."
        )
    }

    func test_addedNumberWithNothingRemoved() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "see you soon", rewrite: "see you at 5", unsupported: ["5"], usedMemory: false),
            "The rewrite adds the number 5, which isn't in your text."
        )
    }

    func test_addedName() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "let me know", rewrite: "Let me know, Arnaud.", unsupported: ["Arnaud"], usedMemory: false),
            "The rewrite adds “Arnaud”, which isn't in your text."
        )
    }

    func test_addedNamesWithMemoryInPlay() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "let me know", rewrite: "Let me know, Arnaud and Bea.",
                                         unsupported: ["Arnaud", "Bea"], usedMemory: true),
            "The rewrite adds “Arnaud”, “Bea”, which aren't in your text or memory."
        )
    }

    func test_numberAndNameTogether() {
        XCTAssertEqual(
            RewriteChangeWarning.message(selection: "meet at 10", rewrite: "Meet Arnaud at 11.", unsupported: ["11", "Arnaud"], usedMemory: false),
            "The number changed: you wrote 10, the rewrite says 11. The rewrite adds “Arnaud”, which isn't in your text."
        )
    }

    func test_nothingUnsupportedIsNoWarning() {
        XCTAssertNil(RewriteChangeWarning.message(selection: "a", rewrite: "b", unsupported: [], usedMemory: false))
    }
}
