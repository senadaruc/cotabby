import XCTest
@testable import Cotabby

/// Translations stay on their messages while the chat scrolls.
@MainActor
final class TranslationScrollFollowTests: XCTestCase {
    func testDeltaIsTheAnchorsMovementAndNoneWhenItStayed() {
        let was = CGRect(x: 300, y: 500, width: 400, height: 40)
        XCTAssertEqual(
            TranslationScrollFollow.delta(anchorWas: was, anchorIs: was.offsetBy(dx: 0, dy: -120)),
            CGVector(dx: 0, dy: -120)
        )
        XCTAssertNil(TranslationScrollFollow.delta(anchorWas: was, anchorIs: was.offsetBy(dx: 0.1, dy: 0.1)))
    }

    func testLabelsAndTheirCoversMoveTogether() {
        let cover = TranslationCover(
            rect: CGRect(x: 10, y: 20, width: 100, height: 18),
            background: ChatColor(red: 1, green: 2, blue: 3), foreground: ChatColor(red: 4, green: 5, blue: 6), fontSize: 15
        )
        let label = TranslationLabel(id: 1, text: "My brother", messageFrame: CGRect(x: 8, y: 18, width: 104, height: 22), cover: cover)
        let moved = label.shifted(by: CGVector(dx: 0, dy: -50))
        XCTAssertEqual(moved.messageFrame.minY, -32)
        XCTAssertEqual(moved.cover?.rect.minY, -30)
        XCTAssertEqual(moved.cover?.fontSize, 15)
        XCTAssertEqual(moved.text, "My brother")
    }

    func testClipKeepsLabelsBetweenTheHeaderAndTheComposer() {
        let window = CGRect(x: 100, y: 50, width: 900, height: 700)
        let composer = CGRect(x: 420, y: 700, width: 560, height: 36)
        XCTAssertEqual(
            TranslationScrollFollow.clipRegion(windowFrame: window, composeFrame: composer),
            CGRect(x: 396, y: 102, width: 604, height: 592)
        )
        XCTAssertEqual(
            TranslationScrollFollow.clipRegion(windowFrame: window, composeFrame: nil),
            CGRect(x: 100, y: 102, width: 900, height: 648)
        )
    }
}
