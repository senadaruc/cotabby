import AppKit
import SwiftUI

/// File overview:
/// The two floating surfaces of selection rewrite: the small Cotabby button at the selection's end,
/// and the popup that replaces it when pressed. Both are non-activating panels (like
/// `AnswerCardController`), so a click never takes focus from the app being edited and its
/// selection stays put. The popup can become key only after `allowKeyboard()`, which the
/// coordinator calls when the user clicks into the custom instruction box. Owned by
/// `SelectionRewriteCoordinator`.
@MainActor
final class SelectionRewritePanelController {
    /// Two separate panels rather than one: the small button and the popup have different sizes and
    /// lifetimes, and the button is hidden the moment the popup opens.
    private var buttonPanel: RewritePanel?
    private var popupPanel: RewritePanel?

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

    /// Shows the popup under the selection's end (or above it when there is no room below), clamped
    /// to the screen that holds the anchor. Hides the button first: the popup replaces it.
    func showPopup(near anchor: CGRect, model: SelectionRewritePopupModel) {
        buttonPanel?.orderOut(nil)
        let panel = popupPanel ?? Self.makePanel()
        popupPanel = panel
        panel.allowsKey = false
        let hosting = FirstClickHostingView(rootView: SelectionRewritePopupView(model: model))
        panel.contentView = hosting
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 8)
        if origin.y < screen.minY { origin.y = anchor.maxY + 8 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Resizes the popup to its content after a phase change (preview text arrives).
    /// The top edge is kept fixed, so the popup grows downward from where it was opened.
    func refit() {
        guard let panel = popupPanel, let view = panel.contentView else { return }
        let size = view.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    /// Lets the popup take the keyboard for the instruction box. The panel stays non-activating, so
    /// the edited app remains the active app; only keystrokes come here until the popup closes.
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

/// A borderless panel that refuses key status by default. `allowsKey` is flipped on only while the
/// instruction box needs typing, so the rest of the time the edited app keeps the keyboard.
private final class RewritePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// A window that is not key would otherwise spend the first click on activation and deliver
/// nothing; accepting the first mouse makes that one click press the button or preset.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
