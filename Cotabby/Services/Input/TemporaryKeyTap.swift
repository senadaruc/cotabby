import CoreGraphics
import Foundation
import Logging

/// File overview:
/// A keyboard tap that exists only while an offer is on screen (an answer card), deciding per key
/// whether to take it.
///
/// Why its own tap rather than `InputMonitor`'s: that monitor's consuming tap is installed only while
/// a suggestion is visible and its single capture slot belongs to inline commands; an answer card is
/// shown when no suggestion is (the field is empty). Why not `TranslationHotkeyTap`: that handles
/// one shortcut, while a card needs Tab (insert), Esc (dismiss) and every other key reported (typing
/// dismisses the card) but passed through.
///
/// Rules every consuming tap here follows: inserted at the head so it sees keys before the app;
/// installed only while needed and removed right after; synthetic events Cotabby posts itself are
/// ignored (`InputSuppressionController`); re-enabled if macOS disables it for a slow callback; and
/// the callback does no Accessibility work, only decides, so it returns in microseconds. Work a
/// decision triggers runs afterwards on the main queue.
@MainActor
final class TemporaryKeyTap {
    enum Decision {
        /// Let the key reach the app.
        case pass
        /// Take the key: the app never sees it.
        case consume
    }

    private let suppressionController: InputSuppressionController
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var decide: ((_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> Decision)?

    init(suppressionController: InputSuppressionController) {
        self.suppressionController = suppressionController
    }

    var isInstalled: Bool { tap != nil }

    /// Installs the tap (or replaces its decision when installed). `decide` runs on the main thread
    /// for each key press and must not block.
    func install(_ decide: @escaping (_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> Decision) {
        self.decide = decide
        guard tap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<TemporaryKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { owner.handle(type: type, event: event) }
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            CotabbyLogger.app.warning("Failed to create a temporary key tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        runLoopSource = source
    }

    func remove() {
        decide = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            guard !suppressionController.isSynthetic(event), let decide else { return Unmanaged.passUnretained(event) }
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            switch decide(keyCode, event.flags) {
            case .pass: return Unmanaged.passUnretained(event)
            case .consume: return nil
            }
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
