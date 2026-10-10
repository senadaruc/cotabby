import AppKit
import SwiftUI

/// File overview:
/// The two floating surfaces of selection rewrite: the small Cotabby button at the selection's end,
/// and the popup that replaces it when pressed. Both are non-activating panels (like
/// `AnswerCardController`), so the host app stays the active app and keeps its selection. The popup
/// takes the keyboard as soon as it opens, so Return and typing go to the popup and never fall
/// through to the edited app (Return in a chat app would send the message). The button panel never
/// becomes key. Owned by `SelectionRewriteCoordinator`.
@MainActor
final class SelectionRewritePanelController {
    /// Two separate panels rather than one: the small button and the popup have different sizes and
    /// lifetimes, and the button is hidden the moment the popup opens.
    private var buttonPanel: RewritePanel?
    private var popupPanel: RewritePanel?
    /// The caret rect the popup was last opened at. Kept so `refit()` can recompute placement for
    /// the new content size with the same rule `showPopup` used.
    private var popupAnchor: CGRect?

    var isPopupVisible: Bool { popupPanel?.isVisible ?? false }
    var isPopupKey: Bool { popupPanel?.isKeyWindow ?? false }

    /// `anchor` is the caret rect at the selection's end in AppKit screen coordinates (bottom-left
    /// origin), as `FocusedInputSnapshot.caretRect` provides.
    func showButton(near anchor: CGRect, onPress: @escaping () -> Void) {
        let panel = buttonPanel ?? Self.makePanel()
        buttonPanel = panel
        let view = Button(action: onPress) {
            Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Rewrite with AI")
        panel.contentView = FirstClickHostingView(rootView: view)
        let size = CGSize(width: 26, height: 26)
        panel.setFrame(CGRect(origin: CGPoint(x: anchor.maxX + 6, y: anchor.minY - 2), size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Shows the popup at the selection's end and makes it key, so its keystrokes reach the popup
    /// rather than the edited app. Hides the button first: the popup replaces it.
    func showPopup(near anchor: CGRect, model: SelectionRewritePopupModel) {
        buttonPanel?.orderOut(nil)
        popupAnchor = anchor
        let panel = popupPanel ?? Self.makePanel()
        popupPanel = panel
        let hosting = FirstClickHostingView(rootView: SelectionRewritePopupView(model: model))
        panel.contentView = hosting
        place(panel, size: hosting.fittingSize)
        panel.orderFrontRegardless()
        // Keyboard only after the panel is on screen. `allowsKey` is what lets an NSPanel with
        // `.nonactivatingPanel` become key at all; the host app is not activated by this.
        panel.allowsKey = true
        panel.makeKey()
    }

    /// Resizes the popup to its content after a phase change (preview text arrives), then places it
    /// again with the same rule as `showPopup`, so it stays on screen as it grows.
    func refit() {
        guard let panel = popupPanel, let view = panel.contentView else { return }
        place(panel, size: view.fittingSize)
    }

    /// Lets the popup take the keyboard for the instruction box. `showPopup` already does this, so
    /// this is only a second request if the popup lost key status while open.
    func allowKeyboard() {
        guard let panel = popupPanel else { return }
        panel.allowsKey = true
        panel.makeKey()
    }

    func hideButton() { buttonPanel?.orderOut(nil) }

    /// Closes both panels. Takes the keyboard back first (`allowsKey = false`) so that no later
    /// `makeKey` call can pull focus into a panel that is already gone.
    func hideAll() {
        buttonPanel?.orderOut(nil)
        popupPanel?.allowsKey = false
        popupPanel?.orderOut(nil)
    }

    /// The one placement rule for the popup, used by both `showPopup` and `refit`: below the caret
    /// when the popup fits there, otherwise above it, then clamped inside the visible frame of the
    /// screen that holds the caret's midpoint. The midpoint is used because the caret's origin can sit
    /// on a screen edge, and the origin can fall outside every screen's frame.
    private func place(_ panel: RewritePanel, size: CGSize) {
        guard let anchor = popupAnchor else { return }
        let midpoint = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = (NSScreen.screens.first { $0.frame.contains(midpoint) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 8)
        if origin.y < screen.minY { origin.y = anchor.maxY + 8 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
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

/// A borderless panel that refuses key status unless `allowsKey` is set. The popup sets it while it
/// is open; the button panel never sets it, so the button can never take the keyboard.
private final class RewritePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// A window that is not key would otherwise spend the first click on activation and deliver
/// nothing; accepting the first mouse makes that one click press the button or preset.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
