import XCTest
@testable import Cotabby

/// The composer's rows in a window capture, left out of the "did the chat change" hash so a blinking
/// caret no longer re-reads (and used to blink) every translation label.
@MainActor
final class TranslationCaptureRowsTests: XCTestCase {
    private let window = CGRect(x: 100, y: 50, width: 800, height: 600)

    func testComposerRowsArePaddedAndScaledToTheCapture() {
        // Composer 40 pt tall near the bottom of a 2x capture.
        let composer = CGRect(x: 300, y: 590, width: 500, height: 40)
        XCTAssertEqual(
            TranslationCoordinator.imageRows(of: composer, in: window, imageHeight: 1200),
            (2 * (540 - 12))..<(2 * (580 + 12))
        )
    }

    func testRowsAreClampedToTheImageAndMissingFramesExcludeNothing() {
        let pastBottom = CGRect(x: 300, y: 640, width: 500, height: 40)
        XCTAssertEqual(TranslationCoordinator.imageRows(of: pastBottom, in: window, imageHeight: 600), 578..<600)
        XCTAssertNil(TranslationCoordinator.imageRows(of: nil, in: window, imageHeight: 600))
        XCTAssertNil(TranslationCoordinator.imageRows(of: CGRect(x: 0, y: 900, width: 10, height: 10), in: window, imageHeight: 600))
    }
}
