import XCTest
@testable import Cotabby

final class GhosttyConfigurationTests: XCTestCase {
    func testReadsCursorColourAndLeftPadding() {
        // The measured user config.
        let config = GhosttyConfiguration.parse("""
        font-size = 14
        # --- Cursor ---
        cursor-color = #e6edf3
          window-padding-x = 10
          window-padding-y = 8
        """)
        XCTAssertEqual(config.cursorColor, TerminalRGBColor(hex: "#e6edf3"))
        XCTAssertEqual(config.paddingX, 10)
    }

    func testFallsBackToForegroundThenDefaults() {
        XCTAssertEqual(GhosttyConfiguration.parse("foreground = #112233").cursorColor, TerminalRGBColor(hex: "#112233"))
        let empty = GhosttyConfiguration.parse("")
        XCTAssertEqual(empty.cursorColor, GhosttyConfiguration.defaultCursorColor)
        XCTAssertEqual(empty.paddingX, GhosttyConfiguration.defaultPadding)
        XCTAssertEqual(GhosttyConfiguration.parse("window-padding-x = 6,12").paddingX, 6, "left of a left,right pair")
    }

    func testLaterLinesWinAndCommentsAreIgnored() {
        let config = GhosttyConfiguration.parse("cursor-color = #000000\n# cursor-color = #ff0000\ncursor-color = #010203")
        XCTAssertEqual(config.cursorColor, TerminalRGBColor(red: 1, green: 2, blue: 3))
    }
}
