import AppKit
import CoreGraphics
import Foundation
import Logging
import ScreenCaptureKit

/// File overview:
/// Keeps the latest pixel-measured cursor of a terminal whose Accessibility element reports none
/// (Ghostty, see `TerminalAppDetector.reportsNoCursor`). The resolver asks on every focus poll;
/// this answers from its cache at once and, when the terminal's text changed since the last
/// measurement, captures the text area once in the background (ScreenCaptureKit, the Screen
/// Recording permission screen context already uses), finds the cursor with
/// `TerminalCursorDetector`, and asks focus tracking to resolve again with the new fix.
///
/// Owned by `CotabbyAppEnvironment` for the app's lifetime and handed to `FocusSnapshotResolver`
/// through `FocusTrackingModel`/`FocusTracker` as a `TerminalCursorProviding`. MainActor state; the
/// capture is async and the pixel scan runs on a detached task, so the main actor never blocks.
///
/// Cost: one capture of the terminal's text area per change, at most every `minimumInterval`, only
/// while such a terminal is focused. Ghostty's cursor blinks, so a capture can miss it; the previous
/// fix is then kept, and the next change captures again.
@MainActor
final class TerminalCursorTracker: TerminalCursorProviding {
    /// Called on the main actor after a capture produced a new fix.
    var onFixUpdated: (() -> Void)?

    /// Captures run no more often than this while text keeps changing (a spinner redraws often).
    static let minimumInterval: TimeInterval = 0.25
    /// A fix older than this is re-measured even with unchanged text: a cursor moved with the arrow
    /// keys changes no text.
    static let refreshAge: TimeInterval = 1.0
    /// Captures tried per measurement before giving up on a blinked-off cursor, and the gap between
    /// them: four over 450 ms always land inside one visible phase of a one-second blink.
    static let captureAttempts = 4
    static let retryDelayNanoseconds: UInt64 = 150_000_000

    private let loadConfiguration: () -> GhosttyConfiguration
    private var fix: TerminalCursorFix?
    private var fixKey: Key?
    private var lastTextLength: Int?
    private var lastCaptureStart: Date?
    private var captureInFlight = false

    /// What a fix is valid for: the same process and text area (a moved or resized window lays out
    /// a different grid).
    private struct Key: Equatable {
        let processIdentifier: pid_t
        let elementFrame: CGRect
    }

    init(loadConfiguration: @escaping () -> GhosttyConfiguration = { GhosttyConfiguration.load() }) {
        self.loadConfiguration = loadConfiguration
    }

    func cursorFix(processIdentifier: pid_t, elementFrame: CGRect, textLength: Int) -> TerminalCursorFix? {
        let key = Key(processIdentifier: processIdentifier, elementFrame: elementFrame)
        if fixKey != key {
            fix = nil
            fixKey = key
            lastTextLength = nil
        }
        let now = Date()
        let changed = textLength != lastTextLength
        let stale = fix.map { now.timeIntervalSince($0.measuredAt) > Self.refreshAge } ?? true
        let rested = lastCaptureStart.map { now.timeIntervalSince($0) >= Self.minimumInterval } ?? true
        if !captureInFlight, rested, changed || stale {
            lastTextLength = textLength
            startCapture(for: key)
        }
        return fix
    }

    private func startCapture(for key: Key) {
        captureInFlight = true
        lastCaptureStart = Date()
        let configuration = loadConfiguration()
        Task { [weak self] in
            let outcome = await Self.measure(key: key, configuration: configuration)
            let measured: TerminalCursorFix?
            switch outcome {
            case let .success(fix):
                measured = fix
                CotabbyLogger.focus.debug(
                    "Terminal cursor measured",
                    metadata: [
                        "stage": .string("terminal-cursor"),
                        "column": .stringConvertible(fix.column),
                        "rows_above_last_ink": .stringConvertible(fix.rowsAboveLastInk)
                    ]
                )
            case let .failure(failure):
                measured = nil
                CotabbyLogger.focus.debug(
                    "Terminal cursor not measured",
                    metadata: ["stage": .string("terminal-cursor"), "reason": .string(failure.reason)]
                )
            }
            guard let self else { return }
            self.captureInFlight = false
            // A capture for a text area that is no longer focused must not overwrite the new one.
            guard self.fixKey == key else { return }
            guard let measured else {
                // Missed (a blink, or the cursor was hidden): try again on the next poll instead of
                // waiting for the text to change.
                self.lastTextLength = nil
                return
            }
            self.fix = measured
            self.onFixUpdated?()
        }
    }

    /// Why a measurement produced no fix, for the debug log.
    private struct MeasurementFailure: Error {
        let reason: String
    }

    /// Captures the text area and measures the cursor; fails when the window is not capturable or
    /// the cursor is not visible in this frame (blink, scrolled away, ambiguous).
    private static func measure(
        key: Key,
        configuration: GhosttyConfiguration
    ) async -> Result<TerminalCursorFix, MeasurementFailure> {
        guard CGPreflightScreenCaptureAccess() else { return .failure(.init(reason: "no-screen-recording")) }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return .failure(.init(reason: "no-shareable-content")) }
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == key.processIdentifier
                && $0.frame.contains(CGPoint(x: key.elementFrame.midX, y: key.elementFrame.midY))
        }) else { return .failure(.init(reason: "no-window")) }

        // ScreenCaptureKit and Accessibility share global top-left display points; the crop is
        // window-relative.
        // AppKit screen frames have a bottom-left origin on the primary display, so the midpoint is
        // flipped against the primary display's height to find the screen it is on.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let midpoint = NSPoint(x: key.elementFrame.midX, y: primaryHeight - key.elementFrame.midY)
        let scale = NSScreen.screens.first(where: { $0.frame.contains(midpoint) })?.backingScaleFactor ?? 2
        let configurationSC = SCStreamConfiguration()
        configurationSC.sourceRect = CGRect(
            x: key.elementFrame.minX - window.frame.minX,
            y: key.elementFrame.minY - window.frame.minY,
            width: key.elementFrame.width,
            height: key.elementFrame.height
        )
        // Native pixels: the hollow cursor's edges are one device pixel wide and would blend away
        // at a lower scale.
        configurationSC.width = max(1, Int((key.elementFrame.width * scale).rounded(.up)))
        configurationSC.height = max(1, Int((key.elementFrame.height * scale).rounded(.up)))
        configurationSC.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let color = configuration.cursorColor
        // Ghostty's cursor blinks (about half of each second off, measured: two of three captures
        // missed it), so a capture without a cursor is retried a few times within one blink cycle.
        var found: (image: CGImage, measurement: TerminalCursorDetector.Measurement)?
        for attempt in 0..<Self.captureAttempts {
            if attempt > 0 { try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds) }
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configurationSC
            ) else { return .failure(.init(reason: "capture-failed")) }
            let measurement = await Task.detached(priority: .userInitiated) { () -> TerminalCursorDetector.Measurement? in
                guard let buffer = TerminalPixelBuffer(image: image) else { return nil }
                return TerminalCursorDetector.measure(buffer, cursorColor: color)
            }.value
            if let measurement {
                found = (image, measurement)
                break
            }
        }
        guard let (image, measurement) = found else { return .failure(.init(reason: "cursor-not-found")) }

        let pixelScale = CGFloat(image.width) / key.elementFrame.width
        let cellWidth = CGFloat(measurement.columnPitch) / pixelScale
        let cursorX = CGFloat(measurement.cursorX) / pixelScale
        let column = Int(((cursorX - configuration.paddingX) / cellWidth).rounded())
        return .success(TerminalCursorFix(
            elementFrame: key.elementFrame,
            caretRect: CGRect(
                x: key.elementFrame.minX + cursorX,
                y: key.elementFrame.minY + CGFloat(measurement.cursorTop) / pixelScale,
                width: 0,
                height: CGFloat(measurement.rowPitch) / pixelScale
            ),
            rowsAboveLastInk: measurement.rowsFromCursorToLastInk,
            column: max(0, column),
            measuredAt: Date()
        ))
    }
}
