import CoreGraphics
import XCTest
@testable import Cotabby

/// File overview:
/// Tests for `TranslationStripPlacement`, the pure geometry that puts the translation strip above or
/// below the selection and clear of the Rewrite wand. All rects are in AppKit screen coordinates
/// (origin bottom-left), so "above" means a larger `minY`.
final class TranslationStripPlacementTests: XCTestCase {
    private let size = CGSize(width: 300, height: 44)
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    private let gap = TranslationStripPlacement.gap
    private let inset = TranslationStripPlacement.screenInset

    private func place(
        selection: CGRect?,
        line: CGRect,
        wand: CGRect? = nil,
        windows: [CGRect] = [],
        visible: CGRect? = nil
    ) -> CGRect {
        TranslationStripPlacement.frame(
            selectionRect: selection,
            lineRect: line,
            avoiding: (wand.map { [$0] } ?? []) + windows,
            size: size,
            visibleFrame: visible ?? screen
        )
    }

    private let selection = CGRect(x: 710, y: 560, width: 692, height: 59)
    private let line = CGRect(x: 710, y: 600, width: 2, height: 19)

    /// PopClip's bar: centered over the selection, a few points above it, there before the strip.
    func test_stacksAboveAnotherAppsSelectionBar() {
        let bar = CGRect(x: 930, y: 623, width: 250, height: 44)
        let frame = place(selection: selection, line: line, windows: [bar])
        XCTAssertEqual(frame.minY, bar.maxY + gap)
        XCTAssertEqual(frame.midX, selection.midX, accuracy: 1)
    }

    func test_stacksAboveTheWandAndTheBarTogether() {
        let wand = CGRect(x: 1035, y: 623, width: 21, height: 21)
        let bar = CGRect(x: 930, y: 650, width: 250, height: 44)
        let frame = place(selection: selection, line: line, wand: wand, windows: [bar])
        XCTAssertEqual(frame.minY, bar.maxY + gap)
    }

    /// A floating palette beside the selection, or well above it, is not in the strip's way.
    func test_ignoresFloatingWindowsTheStripWouldNotCover() {
        let beside = CGRect(x: 1500, y: 600, width: 200, height: 300)
        let farAbove = CGRect(x: 900, y: 900, width: 300, height: 100)
        let frame = place(selection: selection, line: line, windows: [beside, farAbove])
        XCTAssertEqual(frame.minY, 619 + gap)
    }

    func test_goesBelowTheBarWhenTheStripHasToDropBelowTheSelection() {
        let top = CGRect(x: 710, y: 1100, width: 400, height: 19)
        let bar = CGRect(x: 800, y: 1050, width: 250, height: 44)
        let frame = place(selection: top, line: top, windows: [bar])
        XCTAssertEqual(frame.maxY, bar.minY - gap)
    }

    func test_centeredAboveTheSelectionWhenNothingIsInTheWay() {
        let selection = CGRect(x: 710, y: 560, width: 692, height: 59)
        let frame = place(selection: selection, line: CGRect(x: 710, y: 600, width: 2, height: 19))
        XCTAssertEqual(frame.midX, selection.midX, accuracy: 1)
        XCTAssertEqual(frame.minY, 619 + gap)
    }

    func test_stacksAboveTheWandWhenTheWandFloatsAboveTheSelection() {
        let selection = CGRect(x: 710, y: 560, width: 692, height: 59)
        let frame = place(
            selection: selection,
            line: CGRect(x: 710, y: 600, width: 2, height: 19),
            wand: CGRect(x: 1035, y: 623, width: 21, height: 21)
        )
        XCTAssertEqual(frame.minY, 644 + gap)
    }

    func test_goesBelowTheSelectionWhenThereIsNoRoomAbove() {
        let frame = place(
            selection: CGRect(x: 710, y: 1100, width: 400, height: 19),
            line: CGRect(x: 710, y: 1100, width: 2, height: 19)
        )
        XCTAssertEqual(frame.maxY, 1100 - gap)
    }

    func test_goesBelowTheWandWhenTheWandAlreadyDroppedBelow() {
        let frame = place(
            selection: nil,
            line: CGRect(x: 710, y: 1100, width: 2, height: 19),
            wand: CGRect(x: 700, y: 1075, width: 21, height: 21)
        )
        XCTAssertEqual(frame.maxY, 1075 - gap)
    }

    func test_clampedInsideTheRightEdge() {
        let frame = place(
            selection: CGRect(x: 1700, y: 600, width: 200, height: 19),
            line: CGRect(x: 1700, y: 600, width: 2, height: 19)
        )
        XCTAssertEqual(frame.maxX, 1800 - inset)
    }

    /// With no screen to clamp against, the strip is placed purely from the anchor: the line's midX is
    /// -39, so the origin is -39 minus half the width, and the y is the line's maxY plus the gap.
    func test_withoutAScreenItIsPlacedFromTheAnchorAlone() {
        let frame = TranslationStripPlacement.frame(
            selectionRect: nil,
            lineRect: CGRect(x: -40, y: 600, width: 2, height: 19),
            avoiding: nil,
            size: size,
            visibleFrame: nil
        )
        XCTAssertEqual(frame.origin, CGPoint(x: -189, y: 619 + gap))
    }
}
