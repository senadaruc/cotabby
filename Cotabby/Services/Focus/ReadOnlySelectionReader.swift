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
/// One exception, last and narrow: WhatsApp's Mac app exposes no selection anywhere, but describes
/// each chat bubble in one accessibility sentence. For an app on
/// `SelectionTranslationPolicy.wholeMessageBundleIdentifiers`, and only after every path above found
/// nothing (never after one refused a sensitive element), a bounded walk of the app's focused window
/// finds the bubble under the pointer and `WhatsAppMessageDescriptionParser` recovers its body: the
/// whole message is translated, since the dragged-across part cannot be known.
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
    /// Bounds of the whole-message walk. WhatsApp's focused window measured 77 nodes with its
    /// bubbles at depth 8, and the walk below prunes every subtree whose frame misses the pointer (about
    /// 37 nodes visited, 10 to 16 ms live), so these caps only stop a host whose tree is far larger
    /// than measured from holding the main actor.
    static let maximumWholeMessageNodes = 400
    static let maximumWholeMessageDepth = 16

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
        guard let mouseUp, let underPointer = readUnderPointer(mouseUp, pid: pid, bundleIdentifier: bundleIdentifier)
        else { return nil }
        switch underPointer {
        case .found(let capture): return capture
        case .sensitive: return nil
        // Last, and only after every path found nothing: a refused sensitive element never gets here.
        case .nothing: return wholeMessage(under: mouseUp, pid: pid, bundleIdentifier: bundleIdentifier)
        }
    }

    /// What the element under the pointer, or one of its parents, yielded. Nil when another app's
    /// window (a floating panel, a HUD) is under the pointer: nothing of the frontmost app was selected
    /// there, and the whole-message walk must not reach through that window to a bubble beneath it. A
    /// hit-test that answers nothing is `.nothing`, not nil: it is no evidence of another window.
    private func readUnderPointer(_ point: CGPoint, pid: pid_t, bundleIdentifier: String) -> ElementReading? {
        guard var element = AXHelper.element(atCocoaPoint: point) else { return .nothing }
        guard AXHelper.owningApplication(of: element)?.processIdentifier == pid else { return nil }
        for _ in 0...Self.maximumParentClimb {
            switch read(element: element, pid: pid, bundleIdentifier: bundleIdentifier, path: .hitTest) {
            case .nothing: break
            case let reading: return reading // found or sensitive: either ends the climb
            }
            guard let parent = AXHelper.parentElement(of: element) else { break }
            element = parent
        }
        return .nothing
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
        guard !Self.isSecureTextRole(role, subrole: subrole) else { return .sensitive }
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

    /// ApplicationServices has no role constant for secure fields, only the subrole; AppKit reports
    /// `AXSecureTextField` as the subrole of an `AXTextField`, so the literal covers hosts that use it as a role.
    private static func isSecureTextRole(_ role: String, subrole: String?) -> Bool {
        role == secureTextFieldName || subrole == kAXSecureTextFieldSubrole as String || subrole == secureTextFieldName
    }

    // MARK: - Whole message

    /// The whole chat message under the pointer, for an app on the whole-message allowlist whose
    /// selection no read path could see. A breadth-first walk of the app's focused window collects the
    /// `AXStaticText` elements whose frame contains the pointer, then parses the smallest first: a
    /// bubble is the innermost text there, and a small label inside one (a date chip) simply fails to
    /// parse and gives way. `AXUIElementCopyElementAtPosition` is not used to find the bubble: asked on
    /// WhatsApp's application element it answered the menu bar for every point probed.
    ///
    /// Coordinates: `point` is AppKit (bottom-left origin, as the event monitor reports it) and every
    /// `AXFrame` is in the global top-left Accessibility space, so the point is flipped once against
    /// the primary display, the same conversion `AXHelper.element(atCocoaPoint:)` uses, and the chosen
    /// frame is converted back with `AXHelper.cocoaRect(fromAccessibilityRect:)` for the strip.
    private func wholeMessage(under point: CGPoint, pid: pid_t, bundleIdentifier: String) -> SelectedTextCapture? {
        // Checked first so every other app pays nothing for this path.
        guard SelectionTranslationPolicy.readsWholeMessage(bundleIdentifier: bundleIdentifier),
              let primaryHeight = NSScreen.screens.first?.frame.height,
              let window = Self.focusedWindow(ofApplicationPID: pid)
        else { return nil }
        let accessibilityPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        var candidates: [(element: AXUIElement, frame: CGRect)] = []
        var frontier: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        // An index into a growing array instead of `removeFirst()`, which would shift the array on
        // every visit; `index` doubles as the visited-node count the cap bounds.
        while index < frontier.count, index < Self.maximumWholeMessageNodes {
            let (node, depth) = frontier[index]
            index += 1
            AXUIElementSetMessagingTimeout(node, Self.messagingTimeout)
            let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: node)
            // A subtree whose frame misses the pointer cannot hold the bubble under it: on screen a
            // bubble sits inside its containers' frames. A node with no frame (or an empty one) is
            // walked anyway, since an unanswered frame proves nothing.
            if let frame, !frame.isEmpty, AXHelper.rectHasFiniteComponents(frame), !frame.contains(accessibilityPoint) {
                continue
            }
            if AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: node) == kAXStaticTextRole as String {
                // WhatsApp's bubbles have no children, so a static text ends the descent here.
                if let frame, !frame.isEmpty, AXHelper.rectHasFiniteComponents(frame) {
                    candidates.append((node, frame))
                }
                continue
            }
            if depth < Self.maximumWholeMessageDepth {
                frontier += AXHelper.childElements(of: node).map { ($0, depth + 1) }
            }
        }
        for candidate in candidates.sorted(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            guard let description = AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: candidate.element),
                  let body = WhatsAppMessageDescriptionParser.messageBody(fromDescription: description)
            else { continue }
            let role = kAXStaticTextRole as String
            let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: candidate.element)
            // The field detectors (`isSensitive`) do not apply to a bubble: they read the element's
            // AXDescription as a field LABEL ("Password"), but here the description IS the message, so
            // they would refuse on a label that is really content, and they skip static text for the
            // credential check anyway. What replaces them is a content check: a secure role is still
            // refused, and so is a message that looks like a one-time code or talks about a credential
            // (`isSensitiveMessage`), because the user did not pick the exact text and it may go to a
            // cloud provider.
            if Self.isSecureTextRole(role, subrole: subrole)
                || SelectionTranslationPolicy.isSensitiveMessage(body) {
                return nil
            }
            let rect = AXHelper.cocoaRect(fromAccessibilityRect: candidate.frame)
            return SelectedTextCapture(
                text: body, rect: rect.isEmpty ? nil : rect, lineRect: nil,
                bundleIdentifier: bundleIdentifier, processIdentifier: pid, isSecure: false, source: .wholeMessage
            )
        }
        return nil
    }

    /// The app's focused window, with the reader's short timeout on the application element so a
    /// wedged host answers nothing instead of stalling the main actor.
    private static func focusedWindow(ofApplicationPID pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let value = AXHelper.copyAttributeValue(kAXFocusedWindowAttribute as CFString, on: application),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // `AXUIElement` is a Core Foundation type: the type ID was checked above, so the cast is safe.
        return unsafeBitCast(value, to: AXUIElement.self)
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
