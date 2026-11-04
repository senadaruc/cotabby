import AppKit
import SwiftUI

/// File overview:
/// The two surfaces of selection rewrite: the button, which is the Cotabby icon panel turned into a
/// wand floating just above the selected line (`ActivationIndicatorController.showRewrite`,
/// `RewriteButtonPlacement`), and the popup that opens beside it. The wand first borrowed the icon's
/// field-edge spot, but a mail body fills its window, so there it landed outside the window (Mail) or
/// on the pane splitter (Outlook), where nobody looks (2026-10-21). The popup is a non-activating panel (like
/// `AnswerCardController`), so the host app stays the active app and keeps its selection; it takes
/// the keyboard as soon as it opens, so Return and typing go to the popup and never fall through to
/// the edited app (Return in a chat app would send the message). Owned by
/// `SelectionRewriteCoordinator`.
@MainActor
final class SelectionRewritePanelController {
    private let indicator: ActivationIndicatorController
    private var popupPanel: RewritePanel?

    init(indicator: ActivationIndicatorController) {
        self.indicator = indicator
    }
    /// The caret rect the popup was last opened at. Kept so `refit()` can recompute placement for
    /// the new content size with the same rule `showPopup` used.
    private var popupAnchor: CGRect?
    /// The model on screen, read at placement time: its phase decides strip or card placement.
    private weak var popupModel: SelectionRewritePopupModel?

    var isPopupKey: Bool { popupPanel?.isKeyWindow ?? false }

    /// Shows the rewrite button just above the selected line, centered over the selected text.
    /// `caretRect` and `selectionRect` are AppKit screen coordinates (bottom-left origin).
    func showButton(caretRect: CGRect, selectionRect: CGRect?, onPress: @escaping () -> Void) {
        indicator.showRewrite(caretRect: caretRect, selectionRect: selectionRect, onPress: onPress)
    }

    /// Shows the popup beside the rewrite icon when it is on screen (else at `anchor`). With
    /// `takesKeyboard` it also becomes key, so its keystrokes reach the popup rather than the edited
    /// app; a notice passes false and leaves the host's keyboard alone.
    func showPopup(near anchor: CGRect, model: SelectionRewritePopupModel, takesKeyboard: Bool) {
        popupAnchor = indicator.rewriteIconFrame ?? anchor
        popupModel = model
        let panel = popupPanel ?? Self.makePanel()
        popupPanel = panel
        let hosting = FirstClickHostingView(rootView: SelectionRewritePopupView(model: model))
        panel.contentView = hosting
        place(panel, size: hosting.fittingSize)
        panel.orderFrontRegardless()
        // Keyboard only after the panel is on screen. `allowsKey` is what lets an NSPanel with
        // `.nonactivatingPanel` become key at all; the host app is not activated by this.
        panel.allowsKey = takesKeyboard
        if takesKeyboard { panel.makeKey() }
    }

    /// Resizes the popup to its content after a phase change (preview text arrives), then places it
    /// again with the same rule as `showPopup`, so it stays on screen as it grows.
    func refit() {
        guard let panel = popupPanel, let view = panel.contentView else { return }
        place(panel, size: view.fittingSize)
    }

    /// Closes both panels. Takes the keyboard back first (`allowsKey = false`) so that no later
    /// `makeKey` call can pull focus into a panel that is already gone.
    func hideAll() {
        indicator.endRewrite()
        popupPanel?.allowsKey = false
        popupPanel?.orderOut(nil)
    }

    /// The one placement rule for the popup, used by both `showPopup` and `refit`. The anchor is
    /// the wand, centered just above the selected line (or the caret, for a notice with no wand).
    /// The strip takes the wand's place: centered on it, so it reads as the wand unfolding. A card
    /// goes above the wand, so the preview never covers the text it rewrites, and drops below the
    /// line only when the screen has no room above. Both are clamped inside the visible frame of
    /// the screen that holds the anchor's midpoint. The midpoint is used because the anchor's
    /// origin can sit on a screen edge, and the origin can fall outside every screen's frame.
    private func place(_ panel: RewritePanel, size: CGSize) {
        guard let anchor = popupAnchor else { return }
        let midpoint = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = (NSScreen.screens.first { $0.frame.contains(midpoint) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2)
        if popupModel?.phase != .actions {
            origin.y = anchor.maxY + 8
            // Below the selected line: the anchor sits a few points above it, so allow for one line.
            if origin.y + size.height > screen.maxY - 8 { origin.y = anchor.minY - size.height - 28 }
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size).integral, display: true)
    }

    /// Built the same way as `AnswerCardController`'s panel: non-activating, floating above normal
    /// windows (`.statusBar`), visible on every Space and over full-screen apps, and with no
    /// open/close animation so it appears at the caret without lag.
    private static func makePanel() -> RewritePanel {
        let panel = RewritePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        return panel
    }
}

/// A borderless panel that refuses key status unless `allowsKey` is set, which the popup does
/// while it is open.
private final class RewritePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// A window that is not key would otherwise spend the first click on activation and deliver
/// nothing; accepting the first mouse makes that one click press the button or preset.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
