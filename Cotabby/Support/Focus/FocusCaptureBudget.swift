import Foundation

/// Keeps Cotabby's Accessibility reads to a bounded share of the focused app's main thread.
///
/// Every read of the focused field is answered by the host app's main thread, the same thread
/// that handles its typing. TextEdit answers in about 2 ms, but WhatsApp took 30-98 ms a read, and
/// the focus timer plus the per-keystroke publish poll read it back to back: over half of
/// WhatsApp's main thread went to Cotabby while the user typed, and typing and deleting lagged in
/// WhatsApp itself. The budget learns each app's read cost and spaces polling reads so they take at
/// most `maximumShare` of the time; a fast app is still read every few milliseconds.
///
/// Kept apart from `FocusTracker` so the arithmetic is tested without live Accessibility reads.
nonisolated struct FocusCaptureBudget {
    /// The largest share of the host's time polling reads may take.
    static let maximumShare = 0.25
    /// Weight of the newest read in the running average of the read cost.
    static let smoothing = 0.3

    private(set) var processIdentifier: pid_t?
    private(set) var averageCostMs: Double = 0
    private(set) var lastCaptureEndMs: Double?

    /// Records a completed read of the app with `processIdentifier`. A new app starts its average
    /// from this read, so one slow app never throttles the next.
    mutating func record(processIdentifier: pid_t?, costMs: Double, endedAtMs: Double) {
        if processIdentifier == self.processIdentifier {
            averageCostMs += Self.smoothing * (costMs - averageCostMs)
        } else {
            self.processIdentifier = processIdentifier
            averageCostMs = costMs
        }
        lastCaptureEndMs = endedAtMs
    }

    /// Whether a polling read of the app may start at `nowMs`: always for an app other than the one
    /// last read, otherwise once the gap since the last read lets reads stay within `maximumShare`.
    func allowsCapture(processIdentifier: pid_t?, atMs nowMs: Double) -> Bool {
        guard let lastCaptureEndMs, processIdentifier == self.processIdentifier else { return true }
        let minimumGapMs = averageCostMs * (1 / Self.maximumShare - 1)
        return nowMs - lastCaptureEndMs >= minimumGapMs
    }
}
