import Carbon.HIToolbox
import Foundation

/// File overview:
/// One system-wide keyboard shortcut registered through Carbon's `RegisterEventHotKey`. Translate on
/// Select uses it for its "translate the current selection" chord.
///
/// Why a Carbon hot key and not a CGEvent tap: a modifying event tap sits on the path of every keystroke
/// in every app, so each key waits on Cotabby's main thread (which also runs Accessibility reads). That
/// is exactly the shape of the system-wide typing lag this Mac has suffered from. A registered hot key
/// is matched by the window server: it consumes only its own chord, adds nothing to the keystroke path
/// and needs no Input Monitoring permission. Carbon's API is nominally deprecated, but it is still the
/// mechanism every macOS hot-key utility uses and Apple has not offered a replacement.
///
/// Owned by `CotabbyAppEnvironment` through `SelectionTranslationCoordinator`, which installs and
/// removes it as the feature is switched on and off. Lives for the whole app run.
@MainActor
final class CarbonHotKey: SelectionHotkeyInstalling {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// Four-character signature ('CTBY') that tags our registration; the id distinguishes hot keys.
    private static let signature: OSType = 0x4354_4259

    nonisolated deinit {}

    /// Registers `keyCode` + `modifiers` (`ShortcutModifierMask` bits). Installing again unregisters the
    /// previous chord first, so a changed shortcut applies at once.
    func install(keyCode: CGKeyCode, modifiers: UInt32, onPress: @escaping () -> Void) {
        unregisterKey()
        self.onPress = onPress
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), Self.carbonModifiers(from: modifiers), id, GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr { hotKeyRef = ref }
    }

    func remove() {
        unregisterKey()
        onPress = nil
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func unregisterKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    /// One handler for the app's lifetime of the registration. `self` travels through the C callback as
    /// an unretained pointer; it stays valid because `remove()` drops the handler before we go away.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<CarbonHotKey>.fromOpaque(userData).takeUnretainedValue()
            // The application event target delivers on the main thread, so assuming isolation is sound.
            MainActor.assumeIsolated { hotKey.onPress?() }
            return noErr
        }, 1, &spec, userData, &ref)
        if status == noErr { handlerRef = ref }
    }

    /// `ShortcutModifierMask` bits (command 1<<0, shift 1<<1, option 1<<2, control 1<<3) to Carbon flags.
    nonisolated static func carbonModifiers(from mask: UInt32) -> UInt32 {
        var flags: UInt32 = 0
        if mask & (1 << 0) != 0 { flags |= UInt32(cmdKey) }
        if mask & (1 << 1) != 0 { flags |= UInt32(shiftKey) }
        if mask & (1 << 2) != 0 { flags |= UInt32(optionKey) }
        if mask & (1 << 3) != 0 { flags |= UInt32(controlKey) }
        return flags
    }
}
