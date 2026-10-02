import CoreGraphics
import Foundation

/// A terminal cursor measured from the terminal's pixels, for terminals whose Accessibility element
/// reports no cursor offset or character bounds (`TerminalAppDetector.reportsNoCursor`). Produced by
/// `TerminalCursorTracker`, consumed by `FocusSnapshotResolver`, which turns it into the field's
/// selection and caret rect.
struct TerminalCursorFix: Equatable, Sendable {
    /// The terminal text area's frame the measurement was taken in (Accessibility coordinates).
    let elementFrame: CGRect
    /// The cursor's cell, zero width, in Accessibility coordinates (top-left origin).
    let caretRect: CGRect
    /// Text rows from the cursor's row down to the lowest inked row on screen.
    let rowsAboveLastInk: Int
    /// The cursor's column in cells.
    let column: Int
    let measuredAt: Date
}

/// The narrow seam the resolver needs. Returns the latest fix for the terminal at `elementFrame`, and
/// may start a fresh measurement when `textLength` shows the terminal changed since the last one;
/// the provider then asks focus tracking to resolve again once it has it.
@MainActor
protocol TerminalCursorProviding: AnyObject {
    func cursorFix(processIdentifier: pid_t, elementFrame: CGRect, textLength: Int) -> TerminalCursorFix?
}
