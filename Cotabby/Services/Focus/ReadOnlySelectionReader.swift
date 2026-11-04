import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Reads the text the user selected in any app, editable or not, for Translate on Select.
/// `FocusSnapshotResolver` reads a selection only inside editable fields (it exists for autocomplete),
/// so a Mail message in the reading pane, a web page in Chrome or a Slack message never reach the focus
/// snapshot. This reader asks the host's focused element directly, once, after the selection gesture
/// ended, trying the three shapes macOS hosts expose:
///
/// 1. `kAXSelectedText`: AppKit text views and some web areas answer the selected string outright.
/// 2. `kAXSelectedTextRange` + `AXStringForRange`: AppKit text views without (1).
/// 3. `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange`: WebKit (Mail, Safari) and Chromium
///    (Chrome, Electron) documents, whose ranges are opaque markers.
///
/// When the focused element has nothing (focus sits on a toolbar while the page holds the selection),
/// the element under the pointer and a few of its parents are asked the same way: a hit lands on an
/// `AXStaticText` run while the selection lives on its enclosing web area. Nothing is simulated: no
/// ⌘C, no clipboard. A host whose Accessibility exposes none of the three gets no translation in v1
/// (a ⌘C fallback is a possible later addition).
///
/// Every element read is bounded by a short messaging timeout so a wedged host cannot stall the main
/// actor. Built by `CotabbyAppEnvironment`, used by `SelectionTranslationCoordinator`. The selected
/// text is user content and is never logged.
@MainActor
protocol SelectionReading: AnyObject {
    /// `mouseUp` is the pointer's position (AppKit screen coordinates) when the gesture ended, or nil
    /// for a keyboard gesture.
    func read(frontmost pid: pid_t, bundleIdentifier: String, mouseUp: CGPoint?) -> SelectedTextCapture?
}

@MainActor
final class ReadOnlySelectionReader: SelectionReading {
    /// Parents walked up from a hit-tested element before giving up.
    static let maximumParentClimb = 3
    private static let secureTextFieldName = "AXSecureTextField"
    private static let messagingTimeout: Float = 0.05
    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange"

    nonisolated init() {}

    func read(frontmost pid: pid_t, bundleIdentifier: String, mouseUp: CGPoint?) -> SelectedTextCapture? {
        if let element = AXHelper.focusedElement(forApplicationPID: pid) ?? AXHelper.focusedElement(),
           AXHelper.owningApplication(of: element)?.processIdentifier == pid,
           let capture = capture(on: element, pid: pid, bundleIdentifier: bundleIdentifier) {
            return capture
        }
        guard let mouseUp, var element = AXHelper.element(atCocoaPoint: mouseUp),
              AXHelper.owningApplication(of: element)?.processIdentifier == pid
        else { return nil }
        for _ in 0...Self.maximumParentClimb {
            if let capture = capture(on: element, pid: pid, bundleIdentifier: bundleIdentifier, path: .hitTest) {
                return capture
            }
            guard let parent = AXHelper.parentElement(of: element) else { return nil }
            element = parent
        }
        return nil
    }

    /// The three read paths in order; nil when the element has no non-empty selection. A password
    /// field's selection is never read, whatever it answers.
    private func capture(on element: AXUIElement, pid: pid_t, bundleIdentifier: String,
                         path override: SelectedTextReadPath? = nil) -> SelectedTextCapture? {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? ""
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        // ApplicationServices has no role constant for secure fields, only the subrole; AppKit reports
        // `AXSecureTextField` as the subrole of an `AXTextField`, so the literal covers hosts that use it as a role.
        guard role != Self.secureTextFieldName, subrole != kAXSecureTextFieldSubrole as String,
              subrole != Self.secureTextFieldName else { return nil }
        let attributes = Set(AXHelper.attributeNames(on: element))
        let parameterized = Set(AXHelper.parameterizedAttributeNames(on: element))
        var text: String?
        var path: SelectedTextReadPath = .selectedText
        var range: NSRange?
        if attributes.contains(kAXSelectedTextAttribute as String),
           let value = AXHelper.stringValue(for: kAXSelectedTextAttribute as CFString, on: element), !value.isEmpty {
            text = value
            range = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
        } else if attributes.contains(kAXSelectedTextRangeAttribute as String),
                  let selected = AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element),
                  selected.length > 0,
                  parameterized.contains(kAXStringForRangeParameterizedAttribute as String),
                  let value = AXHelper.parameterizedStringValue(
                      for: kAXStringForRangeParameterizedAttribute as CFString, range: selected, on: element),
                  !value.isEmpty {
            text = value
            path = .range
            range = selected
        } else if attributes.contains(Self.selectedTextMarkerRangeAttribute),
                  parameterized.contains(Self.stringForMarkerRangeAttribute),
                  let value = AXHelper.selectedTextMarkerString(on: element), !value.isEmpty {
            text = value
            path = .marker
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SelectedTextCapture(
            text: text, rect: selectionRect(on: element, range: range, parameterized: parameterized), lineRect: nil,
            bundleIdentifier: bundleIdentifier, processIdentifier: pid, isSecure: false, source: override ?? path
        )
    }

    /// The selection's box: `AXBoundsForRange` for a native range, else the marker bounds; converted
    /// to AppKit coordinates with the element's own frame as the anchor (`validatedCocoaTextRect`
    /// disambiguates the host's coordinate convention with it; without an anchor a second monitor can
    /// land the strip a screen away).
    private func selectionRect(on element: AXUIElement, range: NSRange?, parameterized: Set<String>) -> CGRect? {
        var axRect: CGRect?
        if let range, range.length > 0, parameterized.contains(kAXBoundsForRangeParameterizedAttribute as String) {
            axRect = AXHelper.parameterizedRectValue(for: kAXBoundsForRangeParameterizedAttribute as CFString, range: range, on: element)
        }
        if axRect == nil || axRect == .zero { axRect = AXHelper.textMarkerCaretRect(on: element) }
        guard let axRect, axRect != .zero, AXHelper.rectHasFiniteComponents(axRect) else { return nil }
        let anchor = AXHelper.rectValue(for: "AXFrame" as CFString, on: element)
            .map(AXHelper.cocoaRect(fromAccessibilityRect:))
        let cocoa = AXHelper.validatedCocoaTextRect(fromAccessibilityRect: axRect, anchorFrame: anchor)
        return cocoa.isEmpty ? nil : cocoa
    }
}
