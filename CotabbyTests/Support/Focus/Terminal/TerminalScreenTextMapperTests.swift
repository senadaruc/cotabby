import XCTest
@testable import Cotabby

/// `TerminalScreenTextMapper`: a cursor row counted from the lowest inked row, and its column, to an
/// offset in the tail of a terminal's text.
final class TerminalScreenTextMapperTests: XCTestCase {
    // Shaped like the measured Claude Code screen in Ghostty: the prompt, then a rule and two
    // status lines, then blank rows the screen shows but the text may or may not end with.
    private let tail = "…older output\n⏺ Answer\n────\n❯ git che\n────\n  status line\n  permissions\n\n"

    func testCursorLineIsCountedUpFromTheLastInkedLine() throws {
        let offset = try XCTUnwrap(TerminalScreenTextMapper.caretOffset(in: tail, rowsAboveLastInk: 3, column: 9))
        XCTAssertEqual((tail as NSString).substring(to: offset).components(separatedBy: "\n").last, "❯ git che")
    }

    func testColumnPastTheLineEndClampsToIt() throws {
        let offset = try XCTUnwrap(TerminalScreenTextMapper.caretOffset(in: tail, rowsAboveLastInk: 3, column: 40))
        XCTAssertEqual((tail as NSString).substring(to: offset).components(separatedBy: "\n").last, "❯ git che")
    }

    func testTheCutFirstLineAndBlankTailsAreNoAnswer() {
        XCTAssertNil(TerminalScreenTextMapper.caretOffset(in: tail, rowsAboveLastInk: 6, column: 0), "first line may be cut")
        XCTAssertNil(TerminalScreenTextMapper.caretOffset(in: "\n  \n", rowsAboveLastInk: 0, column: 0))
    }
}
