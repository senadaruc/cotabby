import CoreGraphics
import Foundation

/// File overview:
/// Values for Translate on Select: what one read of the screen's selection produced, and the identity
/// of "the same selection" the coordinator uses so one translation is never shown twice. Pure data,
/// passed between the selection reader (`ReadOnlySelectionReader`), the gate
/// (`SelectionTranslationPolicy`) and `SelectionTranslationCoordinator`; none of them owns another's state.

/// Where the selected text was read from, for the debug log: hosts differ in which path answers.
nonisolated enum SelectedTextReadPath: String, Sendable {
    /// The focus snapshot of an editable field: no extra Accessibility calls.
    case snapshot
    /// `kAXSelectedText` on the focused element (AppKit text views, some web areas).
    case selectedText
    /// `kAXSelectedTextRange` plus `AXStringForRange`.
    case range
    /// WebKit and Chromium text markers (`AXSelectedTextMarkerRange` plus `AXStringForTextMarkerRange`).
    case marker
    /// The element under the pointer, or one of its parents, when the focused element had nothing.
    case hitTest
}

/// One read of the text the user selected on screen.
nonisolated struct SelectedTextCapture: Equatable, Sendable {
    let text: String
    /// The selected text's box in AppKit screen coordinates (bottom-left origin), when the host
    /// answered a bounds query; nil otherwise, and the strip then anchors to the pointer.
    let rect: CGRect?
    /// The first selected line's box when known (an editable field's caret rect); nil for read-only
    /// text. The strip stacks above the Rewrite wand, which sits above this line.
    let lineRect: CGRect?
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let isSecure: Bool
    let source: SelectedTextReadPath
}

/// What makes two reads "the same selection": the same text in the same process. Window and element
/// identity are left out on purpose: a Chromium page recreates its Accessibility nodes constantly.
nonisolated struct SelectionTranslationTarget: Equatable, Sendable {
    let text: String
    let processIdentifier: pid_t
    let bundleIdentifier: String

    init(capture: SelectedTextCapture) {
        text = capture.text
        processIdentifier = capture.processIdentifier
        bundleIdentifier = capture.bundleIdentifier
    }
}
