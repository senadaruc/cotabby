import XCTest
@testable import Cotabby

/// Replacing a message visually: the time stays out of the translated text and the cover, the
/// cover takes the bubble's colours, and the text size follows the lines.
final class TranslationCoverStyleTests: XCTestCase {
    func testTrailingTimeAndReceiptAreSplitOffTheMessage() {
        // Measured OCR line in WhatsApp.
        let split = MessageBlockGrouper.splittingTrailingTimestamp("Kardeşim orasi fena karisacak 20:11 //")
        XCTAssertEqual(split.body, "Kardeşim orasi fena karisacak")
        XCTAssertEqual(split.stamp, "20:11 //")
        XCTAssertEqual(MessageBlockGrouper.splittingTrailingTimestamp("meet at 14:30 tomorrow").body, "meet at 14:30 tomorrow")
        XCTAssertEqual(MessageBlockGrouper.splittingTrailingTimestamp("No but I will 5:01 PM").body, "No but I will")
    }

    func testFontSizeFollowsThePitchOrTheSingleBox() {
        // Measured: wrapped lines 16.5 pt apart; single boxes 13 pt without descenders, 17 with.
        let wrapped = [CGRect(x: 0, y: 85, width: 300, height: 15), CGRect(x: 0, y: 101.5, width: 300, height: 13)]
        XCTAssertEqual(TranslationCoverStyle.fontSize(lineFrames: wrapped), 14.85, accuracy: 0.01)
        XCTAssertEqual(TranslationCoverStyle.fontSize(lineFrames: [CGRect(x: 0, y: 0, width: 90, height: 13)]), 14.95, accuracy: 0.01)
        XCTAssertEqual(TranslationCoverStyle.fontSize(lineFrames: [CGRect(x: 0, y: 0, width: 90, height: 17.2)]), 15.14, accuracy: 0.01)
    }

    /// A 200 x 100 pt window at 1x: a green bubble at (20, 20, 160 x 40) with white text strokes.
    private func chat(bubble: (UInt8, UInt8, UInt8) = (0x14, 0x53, 0x3E)) -> ChatPixelImage {
        var rgba = [UInt8](repeating: 0, count: 200 * 100 * 4)
        for y in 0..<100 {
            for x in 0..<200 {
                let inBubble = x >= 20 && x < 180 && y >= 20 && y < 60
                let inGlyph = inBubble && x >= 34 && x < 120 && y >= 32 && y < 44 && x % 3 == 0
                let color: (UInt8, UInt8, UInt8) = inGlyph ? (0xF5, 0xF5, 0xF5) : inBubble ? bubble : (0x10, 0x10, 0x10)
                let offset = (y * 200 + x) * 4
                rgba[offset] = color.0; rgba[offset + 1] = color.1; rgba[offset + 2] = color.2; rgba[offset + 3] = 255
            }
        }
        return ChatPixelImage(width: 200, height: 100, rgba: rgba)!
    }

    func testCoverTakesTheBubbleAndTextColours() throws {
        let line = CGRect(x: 32, y: 31, width: 90, height: 14)
        let block = MessageBlock(text: "Kardeşim", frame: line, lineFrames: [line])
        let cover = try XCTUnwrap(TranslationCoverStyle.cover(
            for: block, in: chat(), windowFrame: CGRect(x: 0, y: 0, width: 200, height: 100)
        ))
        XCTAssertEqual(cover.background, ChatColor(red: 0x14, green: 0x53, blue: 0x3E))
        XCTAssertEqual(cover.foreground, ChatColor(red: 0xF5, green: 0xF5, blue: 0xF5))
        XCTAssertEqual(cover.rect, line.insetBy(dx: -TranslationCoverStyle.bleed, dy: -TranslationCoverStyle.bleed))
    }

    func testNoCoverWhenTheBackgroundIsNotOneColour() {
        // The line sits at the bubble's top edge, so "above the text" samples the window behind it.
        let line = CGRect(x: 32, y: 21, width: 90, height: 14)
        let block = MessageBlock(text: "Kardeşim", frame: line, lineFrames: [line])
        XCTAssertNil(TranslationCoverStyle.cover(for: block, in: chat(), windowFrame: CGRect(x: 0, y: 0, width: 200, height: 100)))
    }
}
