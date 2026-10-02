import XCTest
@testable import Cotabby

/// `TerminalCursorDetector` on synthetic terminal screens: a grid of glyph-like ink at a known pitch
/// and a cursor in the configured colour at a known cell.
final class TerminalCursorDetectorTests: XCTestCase {
    private let background: (UInt8, UInt8, UInt8) = (29, 31, 36)
    private let glyph: (UInt8, UInt8, UInt8) = (150, 150, 150)
    private let cursorColor = TerminalRGBColor(hex: "#e6edf3")!
    private let padding = 4, rowPitch = 20, columnPitch = 10

    /// A 40 x 15 cell screen, text on rows 0...8, every cell inked like a glyph.
    private func screen(cursors: [(row: Int, column: Int)], hollow: Bool = true) -> TerminalPixelBuffer {
        let width = padding * 2 + 40 * columnPitch, height = padding * 2 + 15 * rowPitch
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        func paint(_ x: Int, _ y: Int, _ color: (UInt8, UInt8, UInt8)) {
            let offset = (y * width + x) * 4
            rgba[offset] = color.0; rgba[offset + 1] = color.1; rgba[offset + 2] = color.2
        }
        for y in 0..<height { for x in 0..<width { paint(x, y, background) } }
        for row in 0...8 {
            for column in 0..<40 {
                let left = padding + column * columnPitch, top = padding + row * rowPitch + 4
                for y in top..<(top + 12) { for x in (left + 2)..<(left + 8) { paint(x, y, glyph) } }
            }
        }
        let cursorRGB = (cursorColor.red, cursorColor.green, cursorColor.blue)
        for cursor in cursors {
            let left = padding + cursor.column * columnPitch, top = padding + cursor.row * rowPitch
            let edges = hollow ? [left, left + columnPitch - 1] : [left]
            for x in edges { for y in top..<(top + 18) { paint(x, y, cursorRGB) } }
        }
        return TerminalPixelBuffer(width: width, height: height, rgba: rgba)!
    }

    func testFindsAHollowCursorAndTheGrid() throws {
        let measurement = try XCTUnwrap(TerminalCursorDetector.measure(screen(cursors: [(6, 3)]), cursorColor: cursorColor))
        XCTAssertEqual(measurement.cursorX, padding + 3 * columnPitch)
        XCTAssertEqual(measurement.cursorTop, padding + 6 * rowPitch)
        XCTAssertEqual(measurement.cursorHeight, 18)
        XCTAssertEqual(measurement.rowPitch, Double(rowPitch), accuracy: 0.3)
        XCTAssertEqual(measurement.columnPitch, Double(columnPitch), accuracy: 0.3)
        // Text on rows 0...8 and the cursor on row 6: two rows down to the last inked row.
        XCTAssertEqual(measurement.rowsFromCursorToLastInk, 2)
    }

    func testFindsABarCursor() throws {
        let measurement = try XCTUnwrap(
            TerminalCursorDetector.measure(screen(cursors: [(8, 12)], hollow: false), cursorColor: cursorColor)
        )
        XCTAssertEqual(measurement.cursorX, padding + 12 * columnPitch)
        XCTAssertEqual(measurement.rowsFromCursorToLastInk, 0)
    }

    func testNoCursorOrTwoCursorsIsNoAnswer() {
        XCTAssertNil(TerminalCursorDetector.measure(screen(cursors: []), cursorColor: cursorColor), "a blinked-off cursor")
        XCTAssertNil(
            TerminalCursorDetector.measure(screen(cursors: [(2, 3), (6, 20)]), cursorColor: cursorColor),
            "two cursor-shaped strokes are ambiguous; a guess would put the ghost on the wrong line"
        )
    }

    func testPitchIsTheBestRepeatWithinTheCursorsRange() throws {
        // Ink every 17 px, stronger every other cell: the 34 px lag scores as high as 17 px (measured
        // live within 1%). Searching near the cursor's cell keeps the fundamental.
        let profile = (0..<400).map { index -> Double in
            index % 17 < 8 ? (index % 34 < 17 ? 10 : 6) : 0
        }
        let pitch = try XCTUnwrap(TerminalCursorDetector.pitch(of: profile, within: 14.5...20.4))
        XCTAssertEqual(pitch, 17, accuracy: 0.5)
        XCTAssertNil(TerminalCursorDetector.pitch(of: [Double](repeating: 1, count: 400), within: 10...20), "flat: no repeat")
    }

    func testShorterGlyphStrokesInTheCursorColourAreIgnored() throws {
        var buffer = screen(cursors: [(6, 3)])
        // A same-coloured glyph stroke, shorter than the cursor, elsewhere on screen.
        var rgba = buffer.rgba
        for y in 30..<42 { let offset = (y * buffer.width + 300) * 4; rgba[offset] = 0xE6; rgba[offset + 1] = 0xED; rgba[offset + 2] = 0xF3 }
        buffer = TerminalPixelBuffer(width: buffer.width, height: buffer.height, rgba: rgba)!
        let measurement = try XCTUnwrap(TerminalCursorDetector.measure(buffer, cursorColor: cursorColor))
        XCTAssertEqual(measurement.cursorX, padding + 3 * columnPitch)
    }

    func testBlinkedOffCursorDoesNotPassAGlyphStrokeAsTheCursor() {
        // No cursor; a same-coloured glyph stroke at 70% of a cell is the tallest stroke on screen.
        let base = screen(cursors: [])
        var rgba = base.rgba
        for y in 128..<142 { let offset = (y * base.width + 200) * 4; rgba[offset] = 0xE6; rgba[offset + 1] = 0xED; rgba[offset + 2] = 0xF3 }
        let buffer = TerminalPixelBuffer(width: base.width, height: base.height, rgba: rgba)!
        XCTAssertNil(TerminalCursorDetector.measure(buffer, cursorColor: cursorColor))
    }

    func testHexColours() {
        XCTAssertEqual(TerminalRGBColor(hex: "#e6edf3"), TerminalRGBColor(red: 0xE6, green: 0xED, blue: 0xF3))
        XCTAssertEqual(TerminalRGBColor(hex: "ffffff"), TerminalRGBColor(red: 255, green: 255, blue: 255))
        XCTAssertNil(TerminalRGBColor(hex: "#fff"))
    }
}
