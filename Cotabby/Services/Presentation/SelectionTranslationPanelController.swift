import AppKit
import SwiftUI

/// File overview:
/// The AppKit side of Translate on Select: one borderless panel hosting
/// `SelectionTranslationStripView`, floated above the selection. Owned by
/// `SelectionTranslationCoordinator`, which talks to it only through `SelectionTranslationPresenting`
/// so its tests can stub the screen out.
///
/// Two differences from `SelectionRewritePanelController`'s popup. First, this panel never becomes
/// key or main: the strip appears while the user is working in another app, and taking the keyboard
/// would swallow Return in a chat and stop Cmd-C copying in the host. It still accepts mouse events
/// so Copy is clickable. Second, placement is not re-derived here: `TranslationStripPlacement` owns
/// the rule (above the selection, above the Rewrite wand when it is there), and this file only
/// supplies the rects and the screen.

@MainActor
protocol SelectionTranslationPresenting: AnyObject {
    var isVisible: Bool { get }
    /// Shows the strip for `model` above the selection: `selectionRect` is the selected text's box
    /// (nil when the host gave none), `lineRect` the first selected line or a 1×1 rect at the pointer,
    /// `wandFrame` the Rewrite wand's frame while it is on screen. AppKit screen coordinates.
    func show(model: SelectionTranslationStripModel, selectionRect: CGRect?, lineRect: CGRect, wandFrame: CGRect?)
    /// Re-sizes to the content after a phase change and places it again with the same inputs.
    func refit()
    func hide()
}

@MainActor
final class SelectionTranslationPanelController: SelectionTranslationPresenting {
    private var panel: TranslationStripPanel?
    // Kept so `refit()` can place the grown strip with the same inputs `show` used.
    private var selectionRect: CGRect?
    private var lineRect: CGRect = .zero
    private var wandFrame: CGRect?

    nonisolated init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(model: SelectionTranslationStripModel, selectionRect: CGRect?, lineRect: CGRect, wandFrame: CGRect?) {
        self.selectionRect = selectionRect
        self.lineRect = lineRect
        self.wandFrame = wandFrame
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        // `FirstClickHostingView` (shared with the Rewrite popup): a click on a panel that is not
        // key would otherwise be spent on activation; accepting the first mouse lets Copy fire.
        let hosting = FirstClickHostingView(rootView: SelectionTranslationStripView(model: model))
        panel.contentView = hosting
        place(panel, size: hosting.fittingSize)
        panel.orderFrontRegardless()
    }

    func refit() {
        guard let panel, let view = panel.contentView else { return }
        place(panel, size: view.fittingSize)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The screen is the one holding the anchor's midpoint, not its origin: an origin on a screen
    /// edge can fall outside every screen's frame.
    private func place(_ panel: TranslationStripPanel, size: CGSize) {
        let anchor = selectionRect ?? lineRect
        let midpoint = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(midpoint) } ?? NSScreen.main
        let frame = TranslationStripPlacement.frame(
            selectionRect: selectionRect, lineRect: lineRect, avoiding: wandFrame,
            size: size, visibleFrame: screen?.visibleFrame
        )
        panel.setFrame(frame, display: true)
    }

    /// Built like the Rewrite popup's panel: non-activating, above normal windows, on every Space
    /// and over full-screen apps, with no open/close animation.
    private static func makePanel() -> TranslationStripPanel {
        let panel = TranslationStripPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
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

/// A panel that can never be key or main, so showing or clicking it leaves the host's keyboard
/// focus alone. Mouse events still reach it (`ignoresMouseEvents` stays false).
private final class TranslationStripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
