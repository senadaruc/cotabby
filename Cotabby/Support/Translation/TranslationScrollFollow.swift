import CoreGraphics
import Foundation

/// File overview:
/// Keeps drawn translations on their messages while the chat scrolls. A scroll moves every message
/// in a chat by the same amount, so one anchor message's movement (its Accessibility element's frame
/// before and now) shifts every label; `TranslationAnchorReader` reads that frame, and labels the
/// scroll carried past the conversation area are cut off by `clipRegion`.
///
/// Pure: `TranslationCoordinator` runs the follow loop and owns the anchors.
nonisolated enum TranslationScrollFollow {
    /// How far the anchor moved, nil when it did not (no redraw needed).
    static func delta(anchorWas: CGRect, anchorIs: CGRect) -> CGVector? {
        let dx = anchorIs.minX - anchorWas.minX
        let dy = anchorIs.minY - anchorWas.minY
        return abs(dx) < 0.25 && abs(dy) < 0.25 ? nil : CGVector(dx: dx, dy: dy)
    }

    /// The part of the window where messages scroll: below the chat header and above the reply
    /// field (or the window's bottom without one), from the reply field's left edge rightwards.
    /// Labels are clipped to it so a scrolled one never floats over the header or the composer.
    static func clipRegion(windowFrame: CGRect, composeFrame: CGRect?, headerHeight: CGFloat = 52) -> CGRect {
        let top = windowFrame.minY + headerHeight
        guard let composeFrame, windowFrame.intersects(composeFrame) else {
            return CGRect(x: windowFrame.minX, y: top, width: windowFrame.width, height: max(0, windowFrame.maxY - top))
        }
        let left = max(windowFrame.minX, composeFrame.minX - 24)
        return CGRect(x: left, y: top, width: windowFrame.maxX - left, height: max(0, composeFrame.minY - 6 - top))
    }
}
