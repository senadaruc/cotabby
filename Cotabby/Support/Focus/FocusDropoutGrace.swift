import Foundation

/// Pure policy for a host's brief "no focused field" read while the user is typing in it.
///
/// WhatsApp, Safari, and Teams redraw their composer while text changes, and for one or two polls
/// the Accessibility API answers "No focused Accessibility element" or "Missing text value" before
/// the same field comes back, usually within 100-400 ms. `FocusTracker` used to publish that read and
/// clear the field's signature, which counted as leaving the field: the ghost hid, the prediction and
/// prompt cache were dropped, and the returning field started a new focus session, so screen capture
/// and OCR ran again. `FocusCapabilityFlickerGate` in the coordinator cannot catch it because the read
/// carries no field to compare, and the tracker only republishes on change, so a read-counting gate
/// would never see the second identical read.
///
/// The grace is therefore time-based and lives where the read happens. While it holds, the tracker
/// keeps publishing the last live field and keeps its signature, so the field's return continues the
/// same session. It holds only an `.unsupported` read with no field, in the app whose field was live,
/// and only for `window` measured from the first missing read; a field that really went away is
/// published once the window ends. A recent click releases at once, because clicking is how a user
/// leaves the composer within the same app, and Return/Escape already hide the ghost as dismissal keys.
///
/// Owned by `FocusTracker` for the tracker's lifetime; it has no collaborators beyond the snapshots
/// and monotonic timestamps (seconds) the tracker passes in.
struct FocusDropoutGrace {
    /// How long a missing field is treated as a redraw. Typing dropouts in WhatsApp ran a median of
    /// ~315 ms with most under 500 ms (2026-10-09 logs); longer gaps are rare enough that publishing
    /// them is the right call, and a ghost lingering past half a second after a real exit would show.
    static let window: TimeInterval = 0.5

    nonisolated enum Decision: Equatable {
        /// Keep the last live field published; the read is likely a host redraw.
        case hold
        /// Publish the read as it is.
        case release
    }

    private var dropoutStartedAt: TimeInterval?
    private var lastPointerDownAt: TimeInterval?

    /// True while a missing read is being held back, so the tracker can keep polling at full cadence
    /// until the hold resolves one way or the other.
    var isHolding: Bool { dropoutStartedAt != nil }

    /// Decides what to do with a capture that found no usable field.
    mutating func evaluateDropout(
        published: FocusSnapshot,
        captured: FocusSnapshot,
        now: TimeInterval
    ) -> Decision {
        guard case .unsupported = captured.capability,
              captured.context == nil,
              case .supported = published.capability,
              let liveField = published.context,
              captured.bundleIdentifier == liveField.bundleIdentifier
        else {
            dropoutStartedAt = nil
            return .release
        }

        if let lastPointerDownAt, now - lastPointerDownAt < Self.window {
            dropoutStartedAt = nil
            return .release
        }

        let startedAt = dropoutStartedAt ?? now
        guard now - startedAt < Self.window else {
            dropoutStartedAt = nil
            return .release
        }
        dropoutStartedAt = startedAt
        return .hold
    }

    /// A capture found a field again: any hold is over, and the next dropout gets a full window.
    mutating func fieldObserved() {
        dropoutStartedAt = nil
    }

    /// Records a physical click, so a dropout right after it is published immediately.
    mutating func notePointerDown(at now: TimeInterval) {
        lastPointerDownAt = now
    }
}
