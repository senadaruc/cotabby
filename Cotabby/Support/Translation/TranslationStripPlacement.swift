import CoreGraphics
import Foundation

/// File overview:
/// Where the translation strip goes: centered above the selected text, like a selection toolbar, and
/// stacked above whatever already floats there: the Rewrite wand (both features arm on the same
/// selection in an editable field) or another utility's selection bar (PopClip puts its bar over
/// any selection the moment the mouse goes up, half a second before the strip arrives). Below the
/// selection only when the screen has no room above, again clear of anything floating there.
/// Pure geometry in AppKit screen coordinates (origin bottom-left), the sibling of
/// `RewriteButtonPlacement`; `SelectionTranslationPanelController` feeds it the rects and the screen.
nonisolated enum TranslationStripPlacement {
    static let gap: CGFloat = 6
    static let screenInset: CGFloat = 8
    /// How many obstacles the strip will step over in one direction before giving up on more: a
    /// stack deeper than this is not a selection toolbar any more.
    static let maximumSteps = 4

    /// `selectionRect` is the selected text's box when the host measured it, `lineRect` the first
    /// selected line (or a 1×1 rect at the pointer when nothing better is known), `obstacles` the
    /// frames the strip must not cover: the Rewrite wand while it is on screen, and other apps'
    /// floating windows near the selection. Only an obstacle the strip would actually overlap moves
    /// it; a palette off to the side or far above is left alone.
    static func frame(
        selectionRect: CGRect?, lineRect: CGRect, avoiding obstacles: [CGRect], size: CGSize, visibleFrame: CGRect?
    ) -> CGRect {
        let anchor = selectionRect ?? lineRect
        var originX = anchor.midX - size.width / 2
        if let visibleFrame {
            originX = min(max(originX, visibleFrame.minX + screenInset), visibleFrame.maxX - size.width - screenInset)
        }
        var originY = stepped(from: anchor.maxY + gap, originX: originX, size: size, over: obstacles, upwards: true)
        if let visibleFrame {
            if originY + size.height > visibleFrame.maxY - screenInset {
                originY = stepped(from: anchor.minY - gap - size.height, originX: originX, size: size, over: obstacles, upwards: false)
            }
            originY = min(max(originY, visibleFrame.minY + screenInset), visibleFrame.maxY - size.height - screenInset)
        }
        // Rounded origin, exact size, as the wand does: `integral` would widen the strip.
        return CGRect(origin: CGPoint(x: originX.rounded(), y: originY.rounded()), size: size)
    }

    /// The wand-only form the first callers used; kept so a single wand reads as what it is.
    static func frame(selectionRect: CGRect?, lineRect: CGRect, avoiding wand: CGRect?, size: CGSize, visibleFrame: CGRect?) -> CGRect {
        frame(selectionRect: selectionRect, lineRect: lineRect, avoiding: wand.map { [$0] } ?? [], size: size, visibleFrame: visibleFrame)
    }

    /// Moves the candidate strip past every obstacle it overlaps, one at a time: above the highest
    /// one when stacking upwards, below the lowest one when stacking downwards.
    private static func stepped(from originY: CGFloat, originX: CGFloat, size: CGSize, over obstacles: [CGRect], upwards: Bool) -> CGFloat {
        var originY = originY
        for _ in 0..<maximumSteps {
            let candidate = CGRect(x: originX, y: originY, width: size.width, height: size.height)
            let blocking = obstacles.filter { !$0.isEmpty && $0.intersects(candidate) }
            guard let edge = upwards ? blocking.map(\.maxY).max() : blocking.map(\.minY).min() else { break }
            originY = upwards ? edge + gap : edge - gap - size.height
        }
        return originY
    }
}
