import AppKit
import Foundation
import Logging
import SwiftUI

/// File overview:
/// Owns the tiny non-activating panel that marks supported inputs with Cotabby's icon near
/// the field edge. Unlike the ghost-text overlay, this controller is focus-driven and toggled
/// by a simple boolean.
///
/// Keeping this as a separate controller preserves the architectural split between:
/// supported-field affordances and suggestion-specific UI.
@MainActor
final class ActivationIndicatorController {
    /// Field-edge mode should visually touch the input's outside edge.
    private let fieldEdgeGap: CGFloat = 0
    private let screenInset: CGFloat = 2

    private lazy var contentView: ClickableHostingView = {
        let view = ClickableHostingView(rootView: AnyView(EmptyView()))
        view.onClick = { [weak self] in
            guard let self else { return }
            if let onRewritePress = self.onRewritePress {
                onRewritePress()
            } else {
                self.onClick?(self.panel.frame)
            }
        }
        return view
    }()

    /// Called with the icon's screen frame when the user clicks it; `AppDelegate` opens the
    /// field-scope popup from here.
    var onClick: ((CGRect) -> Void)?

    private lazy var panel: ActivationIndicatorPanel = {
        let panel = ActivationIndicatorPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Clickable: the icon opens the field-scope popup. It sits just outside the field's edge,
        // so taking its 14pt of clicks never covers the host's own text.
        panel.ignoresMouseEvents = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = contentView
        return panel
    }()

    private var isVisible = false

    /// Set while selection rewrite owns the icon (`showRewrite`): a click opens the rewrite popup
    /// instead of the field-scope popup, and focus-driven `show`/`hide` calls leave the icon alone,
    /// because a selection makes the field "not supported" for autocomplete and would hide it.
    private var onRewritePress: (() -> Void)?

    /// The icon's screen frame while it is the rewrite button, so the popup can open beside it.
    var rewriteIconFrame: CGRect? { onRewritePress != nil && panel.isVisible ? panel.frame : nil }

    /// Turns the icon into the rewrite button for the current selection, floating just above the
    /// first selected line (`RewriteButtonPlacement`), whatever the indicator setting: the rewrite
    /// button has its own setting in Settings → Rewrite. `caretRect` is the caret at the selection's
    /// start (its line places the wand vertically) and `selectionRect` the selected text's box (the
    /// wand centers on it when the host gave one).
    func showRewrite(caretRect: CGRect, selectionRect: CGRect?, onPress: @escaping () -> Void) {
        onRewritePress = onPress
        guard Self.isUsableCaret(caretRect) else {
            CotabbyLogger.app.debug(
                "Rewrite button hidden: caret rect unusable",
                metadata: ["category": "rewrite", "caret": .string("\(caretRect)")]
            )
            panel.orderOut(nil)
            isVisible = false
            return
        }
        let contentSize = render(FieldEdgeIconIndicatorView(rewrite: true))
        let frame = RewriteButtonPlacement.frame(
            lineRect: caretRect, selectionRect: selectionRect, size: contentSize,
            visibleFrame: screen(for: caretRect)?.visibleFrame
        )
        CotabbyLogger.app.debug(
            "Rewrite button placed",
            metadata: [
                "category": "rewrite",
                "frame": .string("\(frame)"),
                "caret": .string("\(caretRect)"),
                "selection": .string("\(selectionRect ?? .null)"),
                "on_screen": .stringConvertible(NSScreen.screens.contains { $0.frame.intersects(frame) })
            ]
        )
        order(frame: frame)
    }

    /// Gives the icon back to focus-driven control and hides it; the next focus update shows the
    /// Cotabby icon again where autocomplete applies.
    func endRewrite() {
        guard onRewritePress != nil else { return }
        onRewritePress = nil
        panel.orderOut(nil)
        isVisible = false
        // The focus update for the same change may already have run (and been ignored while rewrite
        // owned the icon), so ask for the normal icon now instead of waiting for the next one.
        onRewriteEnded?()
    }

    /// Called after `endRewrite()` gives the icon back; `AppDelegate` re-evaluates the normal icon.
    var onRewriteEnded: (() -> Void)?

    /// Shows or hides the field-edge Cotabby icon indicator.
    func show(
        enabled: Bool,
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        dimmed: Bool = false
    ) {
        // Selection rewrite owns the icon until it calls `endRewrite()`.
        guard onRewritePress == nil else { return }
        guard enabled else {
            hide(reason: "Activation indicator hidden because it is disabled.")
            return
        }

        guard Self.isUsableCaret(caretRect) else {
            hide(reason: "Activation indicator hidden because the caret rect was empty.")
            return
        }

        place(view: FieldEdgeIconIndicatorView(dimmed: dimmed), caretRect: caretRect, inputFrameRect: inputFrameRect)
    }

    /// Renders `view` and puts the panel just outside the field's edge.
    private func place(view: FieldEdgeIconIndicatorView, caretRect: CGRect, inputFrameRect: CGRect?) {
        let contentSize = render(view)
        let origin = fieldEdgeIconOrigin(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            contentSize: contentSize
        )
        order(frame: CGRect(origin: origin, size: contentSize).integral)
    }

    /// Swaps the panel's SwiftUI content and returns the size it wants.
    private func render(_ view: FieldEdgeIconIndicatorView) -> CGSize {
        contentView.rootView = AnyView(view)
        contentView.layoutSubtreeIfNeeded()
        return contentView.fittingSize
    }

    /// Moves the panel to `frame` and shows it, unless it is already exactly there.
    private func order(frame: CGRect) {
        if isVisible, panel.frame == frame, panel.isVisible {
            return
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Hides the indicator when Cotabby is not actively supporting the current field.
    func hide(reason _: String) {
        guard onRewritePress == nil else { return }
        panel.orderOut(nil)
        isVisible = false
    }

    /// Places Cotabby's icon just outside the text area's left edge. When the field is flush against
    /// the screen edge we fall back to the right side so the icon stays fully visible.
    private func fieldEdgeIconOrigin(
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        contentSize: CGSize
    ) -> CGPoint {
        let anchorRect = if let inputFrameRect, !inputFrameRect.isEmpty {
            inputFrameRect
        } else {
            caretRect
        }

        // Horizontal placement follows the field's edge, but vertical placement follows the *caret*.
        // Centering vertically on the field only reads as "beside this input" when the field is
        // about one line tall. In a document-shaped text area it is badly wrong: Word publishes the
        // whole page as one `AXTextArea` (846pt tall), so the icon landed halfway down an empty page,
        // hundreds of points below the line being typed. The caret is always on the active line, and
        // for single-line fields it sits at the field's own centre anyway, so short inputs are
        // unaffected. Falls back to the field when the caret rect is empty.
        let verticalAnchor = Self.isUsableCaret(caretRect) ? caretRect : anchorRect

        let preferredLeftX = anchorRect.minX - contentSize.width - fieldEdgeGap
        let fallbackRightX = anchorRect.maxX + fieldEdgeGap
        let centeredY = verticalAnchor.midY - (contentSize.height / 2)

        guard let screen = screen(for: anchorRect) else {
            return CGPoint(x: preferredLeftX, y: centeredY)
        }

        let visibleFrame = screen.visibleFrame
        let preferredX = preferredLeftX >= visibleFrame.minX + screenInset
            ? preferredLeftX
            : fallbackRightX

        let clampedX = min(
            max(preferredX, visibleFrame.minX + screenInset),
            visibleFrame.maxX - contentSize.width - screenInset
        )
        let clampedY = min(
            max(centeredY, visibleFrame.minY + screenInset),
            visibleFrame.maxY - contentSize.height - screenInset
        )

        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Chooses the screen that currently contains the given rect's center point.
    /// Whether a caret rect can place the icon. Only its height is checked: a caret box is
    /// legitimately zero-width (an empty field's zero-length `AXBoundsForRange`, as in WhatsApp's
    /// composer), and `CGRect.isEmpty`, true for any zero-width rect, hid the icon in exactly the
    /// empty field where the user most needs it.
    static func isUsableCaret(_ caretRect: CGRect) -> Bool {
        !caretRect.isNull && caretRect.height > 0
            && caretRect.minX.isFinite && caretRect.minY.isFinite && caretRect.height.isFinite
    }

    private func screen(for rect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)

        if let containingScreen = NSScreen.screens.first(where: {
            $0.visibleFrame.contains(midpoint)
        }) {
            return containingScreen
        }

        return NSScreen.screens.first(where: { $0.frame.intersects(rect) })
    }
}

private final class ActivationIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view for the icon that turns a click into `onClick`.
///
/// `acceptsFirstMouse` returns true because the panel is never key (it is non-activating), and
/// without it AppKit would spend the first click making the window key instead of delivering it.
final class ClickableHostingView: NSHostingView<AnyView> {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
