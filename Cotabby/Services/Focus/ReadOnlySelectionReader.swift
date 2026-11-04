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
           AXHelper.owningApplication(of: element)?.processIdentifier == pid {
            switch read(element: element, pid: pid, bundleIdentifier: bundleIdentifier, path: nil) {
            case .found(let capture): return capture
            // Stop, do not fall through to the hit-test: a password field has the focus, and the
            // pointer's element climbs to a parent web area whose marker selection can cover that field.
            case .sensitive: return nil
            case .nothing: break
            }
        }
        guard let mouseUp, var element = AXHelper.element(atCocoaPoint: mouseUp),
              AXHelper.owningApplication(of: element)?.processIdentifier == pid
        else { return nil }
        for _ in 0...Self.maximumParentClimb {
            switch read(element: element, pid: pid, bundleIdentifier: bundleIdentifier, path: .hitTest) {
            case .found(let capture): return capture
            case .sensitive: return nil
            case .nothing: break
            }
            guard let parent = AXHelper.parentElement(of: element) else { return nil }
            element = parent
        }
        return nil
    }

    /// What one element yielded. `sensitive` is distinct from `nothing` so the caller can stop
    /// instead of trying another element that might expose the same secret.
    private enum ElementReading {
        case found(SelectedTextCapture)
        case sensitive
        case nothing
    }

    /// The three read paths in order. A password or credential field's selection is never returned,
    /// whatever it answers.
    private func read(element: AXUIElement, pid: pid_t, bundleIdentifier: String,
                      path override: SelectedTextReadPath?) -> ElementReading {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? ""
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        // ApplicationServices has no role constant for secure fields, only the subrole; AppKit reports
        // `AXSecureTextField` as the subrole of an `AXTextField`, so the literal covers hosts that use it as a role.
        guard role != Self.secureTextFieldName, subrole != kAXSecureTextFieldSubrole as String,
              subrole != Self.secureTextFieldName else { return .sensitive }
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
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        // The richer detectors (the same ones autocomplete uses) cost several IPC reads, so they run
        // only once there is a selection: a plain static-text hit pays nothing extra.
        if isSensitive(element: element, role: role, subrole: subrole, text: text) { return .sensitive }
        // `isSecure` stays false: a sensitive element never produces a capture.
        return .found(SelectedTextCapture(
            text: text, rect: selectionRect(on: element, range: range, parameterized: parameterized), lineRect: nil,
            bundleIdentifier: bundleIdentifier, processIdentifier: pid, isSecure: false, source: override ?? path
        ))
    }

    /// Parity with the autocomplete resolver: secure fields (role description, title, description) and
    /// sign-in style fields (email, username, code boxes) are never translated or sent anywhere.
    private func isSensitive(element: AXUIElement, role: String, subrole: String?, text: String) -> Bool {
        let title = AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element)
        let description = AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)
        if SecureFieldDetector.isSecure(
            role: role, subrole: subrole,
            roleDescription: AXHelper.stringValue(for: kAXRoleDescriptionAttribute as CFString, on: element),
            title: title, descriptionLabel: description
        ) { return true }
        guard CredentialFieldDetector.mightBeCredentialField(role: role) else { return false }
        return CredentialFieldDetector.isCredentialField(
            role: role,
            labels: [title, description, AXHelper.stringValue(for: kAXPlaceholderValueAttribute as CFString, on: element)],
            domIdentifier: AXHelper.stringValue(for: "AXDOMIdentifier" as CFString, on: element),
            text: text
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
