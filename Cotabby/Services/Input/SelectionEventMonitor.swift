import AppKit
import Foundation

/// File overview:
/// The gestures that end a text selection, and the events that mean the user moved on, read from global
/// `NSEvent` monitors for Translate on Select. Global monitors are listen-only (they never consume or
/// delay an event, unlike Cotabby's CGEvent taps) and they only see events delivered to *other* apps,
/// so a click on the strip's own Copy button never counts as "a click outside". They need the Input
/// Monitoring permission Cotabby already asks for; without it `addGlobalMonitorForEvents` returns nil,
/// which this type tolerates (the keyboard gestures are then simply never seen).
///
/// Owned and started by `SelectionTranslationCoordinator`. Keeps only what tells a drag from a click.
@MainActor
protocol SelectionEventObserving: AnyObject {
    /// A selection gesture ended: mouse-up after a drag or a multi-click, ⇧+arrow/Home/End key-up,
    /// or ⌘A. The point is the pointer in AppKit screen coordinates.
    var onSelectionGesture: (@MainActor (CGPoint) -> Void)? { get set }
    /// A single click with no drag: the selection is gone.
    var onPlainClick: (@MainActor () -> Void)? { get set }
    var onMouseDown: (@MainActor () -> Void)? { get set }
    var onKeyDown: (@MainActor (CGKeyCode, NSEvent.ModifierFlags) -> Void)? { get set }
    var onAppActivated: (@MainActor () -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class SelectionEventMonitor: SelectionEventObserving {
    var onSelectionGesture: (@MainActor (CGPoint) -> Void)?
    var onPlainClick: (@MainActor () -> Void)?
    var onMouseDown: (@MainActor () -> Void)?
    var onKeyDown: (@MainActor (CGKeyCode, NSEvent.ModifierFlags) -> Void)?
    var onAppActivated: (@MainActor () -> Void)?

    /// Moving the pointer this far (points) between down and up is a drag, i.e. a selection.
    static let dragThreshold: CGFloat = 4
    /// Left, right, down, up, Home, End: with Shift they extend the selection.
    static let selectionKeyCodes: Set<CGKeyCode> = [123, 124, 125, 126, 115, 119]
    static let selectAllKeyCode: CGKeyCode = 0 // kVK_ANSI_A

    private var monitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var mouseDownLocation: CGPoint?
    private var dragged = false

    nonisolated init() {}

    func start() {
        // Guarded separately: without Input Monitoring every add() yields nil and `monitors` stays
        // empty, so one guard would stack a new workspace observer on each start(). Splitting them keeps
        // the observer single and still lets the monitors be retried once permission is granted.
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onAppActivated?() }
            }
        }
        guard monitors.isEmpty else { return }
        add(.leftMouseDown) { [weak self] _ in
            self?.mouseDownLocation = NSEvent.mouseLocation
            self?.dragged = false
            self?.onMouseDown?()
        }
        add(.rightMouseDown) { [weak self] _ in self?.onMouseDown?() }
        add(.leftMouseDragged) { [weak self] _ in self?.dragged = true }
        add(.leftMouseUp) { [weak self] event in self?.handleMouseUp(event) }
        add(.keyDown) { [weak self] event in
            self?.onKeyDown?(CGKeyCode(event.keyCode), event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
        add(.keyUp) { [weak self] event in self?.handleKeyUp(event) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        mouseDownLocation = nil
        dragged = false
    }

    /// Global monitor handlers run on the main thread; `assumeIsolated` states that for the compiler.
    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
        }) {
            monitors.append(monitor)
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        let moved = mouseDownLocation.map { hypot($0.x - location.x, $0.y - location.y) > Self.dragThreshold } ?? false
        mouseDownLocation = nil
        if event.clickCount >= 2 || moved || dragged {
            onSelectionGesture?(location)
        } else if event.clickCount == 1 {
            onPlainClick?()
        }
        dragged = false
    }

    private func handleKeyUp(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = CGKeyCode(event.keyCode)
        if Self.selectionKeyCodes.contains(code), flags.contains(.shift) {
            onSelectionGesture?(NSEvent.mouseLocation)
        } else if code == Self.selectAllKeyCode, flags.contains(.command), !flags.contains(.shift) {
            onSelectionGesture?(NSEvent.mouseLocation)
        }
    }
}
