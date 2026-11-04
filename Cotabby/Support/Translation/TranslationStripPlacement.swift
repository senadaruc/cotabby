import CoreGraphics
import Foundation

/// File overview:
/// Where the translation strip goes: centered above the selected text, like a selection toolbar, and
/// above the Rewrite wand when the wand is already floating there (both features arm on the same
/// selection in an editable field). Below the selection only when the screen has no room above.
/// Pure geometry in AppKit screen coordinates (origin bottom-left), the sibling of
/// `RewriteButtonPlacement`; `SelectionTranslationPanelController` feeds it the rects and the screen.
nonisolated enum TranslationStripPlacement {
    static let gap: CGFloat = 6
    static let screenInset: CGFloat = 8

    /// `selectionRect` is the selected text's box when the host measured it, `lineRect` the first
    /// selected line (or a 1×1 rect at the pointer when nothing better is known), `wand` the Rewrite
    /// wand's frame while it is on screen.
    static func frame(selectionRect: CGRect?, lineRect: CGRect, avoiding wand: CGRect?, size: CGSize, visibleFrame: CGRect?) -> CGRect {
        let anchor = selectionRect ?? lineRect
        var originX = anchor.midX - size.width / 2
        // A wand floating above the anchor is in the way; the strip stacks above it.
        let wandAbove = wand.flatMap { $0.minY >= anchor.maxY - 1 ? $0 : nil }
        var originY = (wandAbove?.maxY ?? anchor.maxY) + gap
        if let visibleFrame {
            if originY + size.height > visibleFrame.maxY - screenInset {
                let wandBelow = wand.flatMap { $0.maxY <= anchor.minY + 1 ? $0 : nil }
                originY = (wandBelow?.minY ?? anchor.minY) - gap - size.height
            }
            originX = min(max(originX, visibleFrame.minX + screenInset), visibleFrame.maxX - size.width - screenInset)
            originY = min(max(originY, visibleFrame.minY + screenInset), visibleFrame.maxY - size.height - screenInset)
        }
        // Rounded origin, exact size, as the wand does: `integral` would widen the strip.
        return CGRect(origin: CGPoint(x: originX.rounded(), y: originY.rounded()), size: size)
    }
}
