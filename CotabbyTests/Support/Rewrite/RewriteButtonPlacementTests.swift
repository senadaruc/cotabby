import XCTest
@testable import Cotabby

/// The wand floats above the first selected line, aligned with the selection's start, and moves
/// below the line only when the screen has no room above. AppKit coordinates: y grows upward.
final class RewriteButtonPlacementTests: XCTestCase {
    private let size = CGSize(width: 17, height: 18)
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)

    func test_sitsAboveTheSelectedLineCenteredOverTheSelection() {
        let line = CGRect(x: 710, y: 600, width: 2, height: 19)
        let selection = CGRect(x: 710, y: 600, width: 692, height: 19)
        let frame = RewriteButtonPlacement.frame(lineRect: line, selectionRect: selection, size: size, visibleFrame: screen)
        XCTAssertEqual(frame.midX, selection.midX, accuracy: 1)
        XCTAssertEqual(frame.minY, 600 + 19 + RewriteButtonPlacement.gap)
        XCTAssertEqual(frame.size, size)
    }

    func test_withoutSelectionBoundsItAlignsWithTheSelectionsStart() {
        let line = CGRect(x: 710, y: 600, width: 2, height: 19)
        let frame = RewriteButtonPlacement.frame(lineRect: line, selectionRect: nil, size: size, visibleFrame: screen)
        XCTAssertEqual(frame.minX, 710)
    }

    func test_dropsBelowTheLineWhenTheScreenHasNoRoomAbove() {
        let line = CGRect(x: 710, y: 1110, width: 2, height: 19)
        let frame = RewriteButtonPlacement.frame(lineRect: line, selectionRect: nil, size: size, visibleFrame: screen)
        XCTAssertEqual(frame.maxY, 1110 - RewriteButtonPlacement.gap)
    }

    func test_staysInsideTheScreenHorizontally() {
        let line = CGRect(x: 1795, y: 600, width: 2, height: 19)
        let selection = CGRect(x: 1795, y: 600, width: 100, height: 19)
        let frame = RewriteButtonPlacement.frame(lineRect: line, selectionRect: selection, size: size, visibleFrame: screen)
        XCTAssertEqual(frame.maxX, 1800 - RewriteButtonPlacement.screenInset)
    }

    func test_withoutAScreenItIsStillAboveTheLine() {
        let line = CGRect(x: -40, y: 600, width: 2, height: 19)
        let frame = RewriteButtonPlacement.frame(lineRect: line, selectionRect: nil, size: size, visibleFrame: nil)
        XCTAssertEqual(frame.origin, CGPoint(x: -40, y: 600 + 19 + RewriteButtonPlacement.gap))
    }
}
