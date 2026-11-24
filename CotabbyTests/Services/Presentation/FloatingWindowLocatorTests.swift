import CoreGraphics
import XCTest
@testable import Cotabby

/// File overview:
/// Tests for `FloatingWindowLocator.isObstacle`, the pure rule that decides whether another app's
/// floating window is a selection toolbar the translation strip must step over or screen furniture it
/// must ignore. The sizes below are measured from real windows: PopClip's bar is 28pt tall and
/// 778 to 1126pt wide depending on how many extensions it shows; the overlays are a notch utility, a
/// screen recorder's frame and the menu bar.
final class FloatingWindowLocatorTests: XCTestCase {
    private let display: CGFloat = 3840

    func test_popClipBarsAreObstaclesAtEveryMeasuredWidth() {
        for width: CGFloat in [778, 928, 1126] {
            XCTAssertTrue(
                FloatingWindowLocator.isObstacle(size: CGSize(width: width, height: 28), displayWidth: display),
                "a \(width)x28 toolbar must be stepped over"
            )
        }
    }

    func test_unknownDisplayStillTreatsAThinWideBarAsAnObstacle() {
        XCTAssertTrue(FloatingWindowLocator.isObstacle(size: CGSize(width: 1126, height: 28), displayWidth: nil))
    }

    func test_fullWidthMenuBarIsNotAnObstacle() {
        XCTAssertFalse(FloatingWindowLocator.isObstacle(size: CGSize(width: 3840, height: 30), displayWidth: display))
    }

    func test_tallOverlaysAreNotObstacles() {
        XCTAssertFalse(FloatingWindowLocator.isObstacle(size: CGSize(width: 3840, height: 640), displayWidth: display))
        XCTAssertFalse(FloatingWindowLocator.isObstacle(size: CGSize(width: 5440, height: 2700), displayWidth: display))
    }

    func test_tallWindowsKeepTheSizeCap() {
        XCTAssertTrue(FloatingWindowLocator.isObstacle(size: CGSize(width: 440, height: 200), displayWidth: display))
        XCTAssertFalse(FloatingWindowLocator.isObstacle(size: CGSize(width: 950, height: 200), displayWidth: display))
    }
}
