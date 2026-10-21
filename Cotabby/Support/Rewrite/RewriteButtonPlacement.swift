import CoreGraphics
import Foundation

/// File overview:
/// Where the rewrite wand goes once a selection is stable: floating just above the first selected
/// line, centered over the selected text, the way a selection toolbar sits over selected text.
/// It used to borrow the field-edge Cotabby icon's spot, but a mail body spans its whole window, so
/// the wand landed outside the window (Mail) or on the pane splitter (Outlook), where nobody looks.
///
/// Pure geometry in AppKit screen coordinates (origin bottom-left) so the rule is pinned by tests;
/// `ActivationIndicatorController` feeds it the caret rect and the screen's visible frame.
nonisolated enum RewriteButtonPlacement {
    /// Space between the wand and the selected line.
    static let gap: CGFloat = 4
    /// Keeps the wand clear of the screen's edges.
    static let screenInset: CGFloat = 2

    /// The wand's frame for a selection whose first line is `lineRect` (the caret rect at the
    /// selection's start: its left edge is where the selection begins, its height is the line's)
    /// and whose text occupies `selectionRect` when the host measured it. Centered over the
    /// selection, else aligned with its start; above the line when the screen has room, else below
    /// it; always inside `visibleFrame` when one is given.
    static func frame(lineRect: CGRect, selectionRect: CGRect?, size: CGSize, visibleFrame: CGRect?) -> CGRect {
        var x = selectionRect.map { $0.midX - size.width / 2 } ?? lineRect.minX
        var y = lineRect.maxY + gap
        if let visibleFrame {
            if y + size.height > visibleFrame.maxY - screenInset {
                y = lineRect.minY - gap - size.height
            }
            x = min(max(x, visibleFrame.minX + screenInset), visibleFrame.maxX - size.width - screenInset)
            y = min(max(y, visibleFrame.minY + screenInset), visibleFrame.maxY - size.height - screenInset)
        }
        // Rounded origin, exact size: `integral` on a half-point origin would widen the icon.
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }
}
