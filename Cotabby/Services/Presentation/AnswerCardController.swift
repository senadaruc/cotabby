import AppKit
import SwiftUI

/// File overview:
/// Shows and hides the answer card next to the reply field.
///
/// One borderless, non-activating, click-through panel (it must never take focus from the app the
/// user is replying in), sized to the card's content and placed under the field, or above it when
/// there is no room below, the way the reply-translation card is. Owned by `AnswerCoordinator`.
@MainActor
final class AnswerCardController {
    private var panel: AnswerPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// `fieldFrame` is the reply field (or caret) in AppKit screen coordinates.
    func show(_ offer: AnswerOffer, near fieldFrame: CGRect) {
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        let view = NSHostingView(rootView: AnswerCardView(offer: offer))
        let width = min(max(fieldFrame.width, 360), 560)
        view.frame.size.width = width
        let height = view.fittingSize.height
        let screen = NSScreen.screens.first { $0.frame.intersects(fieldFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? fieldFrame
        var origin = CGPoint(x: fieldFrame.minX, y: fieldFrame.minY - height - 6)
        if origin.y < visible.minY { origin.y = min(fieldFrame.maxY + 6, visible.maxY - height) }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        panel.contentView = view
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> AnswerPanel {
        let panel = AnswerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }
}

/// Never key or main: the card must not steal focus from the reply field.
private final class AnswerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
