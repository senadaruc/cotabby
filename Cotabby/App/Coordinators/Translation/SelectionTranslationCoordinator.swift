import AppKit
import Combine
import Foundation
import Logging

/// File overview:
/// Translate on Select's state machine: gesture → read → gate → one translation → strip.
///
/// 1. `SelectionEventObserving` reports that the user finished selecting (mouse drag, double click,
///    Shift-arrows). After a short debounce the coordinator reads the selected text: from the focus
///    snapshot when an editable field in the frontmost app holds it, otherwise from
///    `SelectionReading` (read-only text in a browser, PDF, chat history).
/// 2. `SelectionTranslationPolicy` decides whether the text is worth translating (not secure, long
///    enough, not already in the reading language). The automatic trigger stays quiet when it cannot
///    tell the language; the shortcut, an explicit request, translates anyway.
/// 3. One translation runs through the Rewrite provider (`SelectionTranslationRunning`), streaming
///    into the strip (`SelectionTranslationStripModel`); finished results are cached so selecting the
///    same sentence again costs nothing.
/// 4. Anything that means the user moved on (a key, a click, another app, another selection) hides the
///    strip and cancels the run.
///
/// Owned by `CotabbyAppEnvironment`, started and stopped by `AppDelegate`. Never logs selected text or
/// translations: a log line may name the app, a character count and a language code, nothing more.
@MainActor
final class SelectionTranslationCoordinator {
    private let preferences: TranslationPreferencesStore
    private let currentSnapshot: @MainActor () -> FocusSnapshot
    private let frontmostApplication: @MainActor () -> (processIdentifier: pid_t, bundleIdentifier: String)?
    private let pointerLocation: @MainActor () -> CGPoint
    private let isAppAllowed: @MainActor (String) -> Bool
    private let windowOverride: @MainActor (_ bundleIdentifier: String, _ windowTitle: String?) -> Bool?
    private let wandFrame: @MainActor () -> CGRect?
    private let focusedWindowTitle: @MainActor (pid_t) -> String?
    private let presenter: SelectionTranslationPresenting
    private let reader: SelectionReading
    private let events: SelectionEventObserving
    private let engine: SelectionTranslationRunning
    private let output: SelectionTranslationTextOutput
    private let hotkey: SelectionHotkeyInstalling?
    private let ownBundleIdentifier: String?
    private let debounce: UInt64

    private var cancellables: Set<AnyCancellable> = []
    private var pendingTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var copiedTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    private var model: SelectionTranslationStripModel?
    /// The selection the strip is (or was last) showing.
    private var target: SelectionTranslationTarget?
    /// The selection the user dismissed. The automatic trigger skips it until the selection changes,
    /// otherwise the Shift-key release or the next focus poll would pop the strip straight back up.
    private var dismissedTarget: SelectionTranslationTarget?
    private var cache = TranslationCache()
    /// Identifies the newest translation. A superseded run can still resolve after its replacement
    /// started, so every write after an `await` compares its own id with this first. `dismiss()` bumps
    /// it too, which is how hiding the strip invalidates a run in flight.
    private var runID = 0
    /// The reading language last applied, to notice a change in Settings.
    private var appliedLanguage: String?

    /// Modifier-only key codes (command, shift, option, control, caps lock, fn, both sides). Pressing
    /// one is the start of a shortcut, not the user moving on.
    private static let modifierKeyCodes: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init(
        preferences: TranslationPreferencesStore,
        currentSnapshot: @escaping @MainActor () -> FocusSnapshot,
        frontmostApplication: @escaping @MainActor () -> (processIdentifier: pid_t, bundleIdentifier: String)?,
        pointerLocation: @escaping @MainActor () -> CGPoint,
        isAppAllowed: @escaping @MainActor (String) -> Bool,
        windowOverride: @escaping @MainActor (_ bundleIdentifier: String, _ windowTitle: String?) -> Bool?,
        wandFrame: @escaping @MainActor () -> CGRect?,
        focusedWindowTitle: @escaping @MainActor (pid_t) -> String? = { AXHelper.focusedWindowTitle(processIdentifier: $0) },
        presenter: SelectionTranslationPresenting,
        reader: SelectionReading,
        events: SelectionEventObserving,
        engine: SelectionTranslationRunning,
        output: SelectionTranslationTextOutput,
        hotkey: SelectionHotkeyInstalling?,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        debounce: UInt64 = 500_000_000
    ) {
        self.preferences = preferences
        self.currentSnapshot = currentSnapshot
        self.frontmostApplication = frontmostApplication
        self.pointerLocation = pointerLocation
        self.isAppAllowed = isAppAllowed
        self.windowOverride = windowOverride
        self.wandFrame = wandFrame
        self.focusedWindowTitle = focusedWindowTitle
        self.presenter = presenter
        self.reader = reader
        self.events = events
        self.engine = engine
        self.output = output
        self.hotkey = hotkey
        self.ownBundleIdentifier = ownBundleIdentifier
        self.debounce = debounce
    }

    nonisolated deinit {}

    // MARK: - Lifecycle

    func start() {
        events.onSelectionGesture = { [weak self] point in self?.handleGesture(at: point) }
        events.onPlainClick = { [weak self] in self?.close(reason: "plain-click") }
        events.onMouseDown = { [weak self] in self?.dismiss(reason: "mouse-down") }
        events.onKeyDown = { [weak self] code, flags in self?.handleKeyDown(code, flags) }
        events.onAppActivated = { [weak self] in self?.dismiss(reason: "app-activated") }
        // The sink fires once at once with the current value, which applies the saved setting.
        preferences.$preferences
            .sink { [weak self] prefs in self?.applyPreferences(prefs) }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        events.stop()
        hotkey?.remove()
        close(reason: "stop")
    }

    /// Hides the strip without forgetting the selection. The Rewrite popup opens over the same
    /// selection, so `AppDelegate` wires `SelectionRewriteCoordinator.onPopupOpened` here.
    func hide() { dismiss(reason: "rewrite-popup") }

    /// The field icon changed the per-window setting: whatever the strip shows is stale.
    func handleScopeChange() { close(reason: "scope-change") }

    /// Takes the emitted value, not `preferences.preferences`: `@Published` publishes in `willSet`, so
    /// the store still holds the old value while its subscribers run.
    private func applyPreferences(_ prefs: TranslationPreferences) {
        if prefs.translatesSelection {
            events.start()
            // `install` re-registers the chord, so a changed shortcut applies at once. A Carbon hot key
            // costs nothing per keystroke, unlike an always-on modifying event tap.
            hotkey?.install(keyCode: prefs.selectionKeyCode, modifiers: prefs.selectionKeyModifiers) { [weak self] in
                // Already on the main thread. The hop lets the hot-key handler return at once; the
                // Accessibility reads run on the next main-loop turn.
                DispatchQueue.main.async { self?.handleShortcut() }
            }
        } else {
            events.stop()
            hotkey?.remove()
            close(reason: "feature-off")
            cache.removeAll()
        }
        // A gesture still in its debounce belongs to the old settings.
        if !prefs.translatesSelection || prefs.selectionTrigger != .automatic { pendingTask?.cancel() }
        // A cached translation or a showing strip is in the old language once the setting changes.
        if let applied = appliedLanguage, applied != prefs.readingLanguage {
            close(reason: "language-changed")
            cache.removeAll()
        }
        appliedLanguage = prefs.readingLanguage
    }

    // MARK: - Triggers

    private var automaticTriggerIsOn: Bool {
        let prefs = preferences.preferences
        return prefs.translatesSelection && prefs.selectionTrigger == .automatic
    }

    private func handleGesture(at point: CGPoint) {
        guard automaticTriggerIsOn else { return }
        log("select-gesture", "Translate on Select gesture", level: .trace)
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            // A zero debounce (tests) skips the sleep, so the gesture still hops once like production.
            if let delay = self?.debounce, delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard let self, !Task.isCancelled else { return }
            self.fire(pointer: point, viaShortcut: false)
        }
    }

    /// The shortcut: an explicit request, so it translates what is selected now whatever was
    /// dismissed and whatever the detector thinks.
    func handleShortcut() {
        guard preferences.preferences.translatesSelection else { return }
        pendingTask?.cancel()
        fire(pointer: pointerLocation(), viaShortcut: true)
    }

    private func handleKeyDown(_ code: CGKeyCode, _ flags: NSEvent.ModifierFlags) {
        if Self.modifierKeyCodes.contains(code) { return }
        let prefs = preferences.preferences
        // The shortcut's own key press must not hide the strip it is about to (re)show.
        if code == prefs.selectionKeyCode, Self.modifierMask(flags).rawValue == prefs.selectionKeyModifiers { return }
        dismiss(reason: "key-down")
    }

    private static func modifierMask(_ flags: NSEvent.ModifierFlags) -> ShortcutModifierMask {
        var mask: ShortcutModifierMask = []
        if flags.contains(.command) { mask.insert(.command) }
        if flags.contains(.shift) { mask.insert(.shift) }
        if flags.contains(.option) { mask.insert(.option) }
        if flags.contains(.control) { mask.insert(.control) }
        return mask
    }

    // MARK: - Reading and gating

    private func fire(pointer: CGPoint, viaShortcut: Bool) {
        // A debounce that outlived a setting change must not fire an automatic run.
        guard viaShortcut || automaticTriggerIsOn else { return }
        guard let app = frontmostApplication(), app.bundleIdentifier != ownBundleIdentifier else { return }
        guard isAppAllowed(app.bundleIdentifier) else {
            log("select-verdict", "Translate on Select verdict",
                metadata: ["app": .string(app.bundleIdentifier), "verdict": "app not allowed"])
            return
        }
        let snapshot = currentSnapshot()
        // The snapshot only names a window when an editable field of this app holds focus. A Mail
        // reading pane, a web page or a chat history has none, so fall back to the focused window's
        // own title (one bounded Accessibility call, made only after a gesture) or the per-window
        // "translation off" would be ignored for the feature's main input. Conversation-scoped keys in
        // chat apps still match only while the composer holds focus.
        let title = Self.windowTitle(in: snapshot, for: app.processIdentifier) ?? focusedWindowTitle(app.processIdentifier)
        // The field icon can turn translation off for one window.
        if windowOverride(app.bundleIdentifier, title) == false { return }
        let capture = readSelection(in: snapshot, app: app, pointer: pointer)
        guard let capture else {
            log("select-read", "Translate on Select read",
                metadata: ["app": .string(app.bundleIdentifier), "outcome": "none"])
            return
        }
        log("select-read", "Translate on Select read", metadata: [
            "app": .string(app.bundleIdentifier), "path": .string(capture.source.rawValue),
            "characters": .stringConvertible(capture.text.count)
        ])

        let candidate = SelectionTranslationTarget(capture: capture)
        if !viaShortcut, isAlreadyHandled(candidate) { return }
        let prefs = preferences.preferences
        let verdict = SelectionTranslationPolicy.verdict(
            for: capture, targetLanguage: prefs.readingLanguage,
            trigger: viaShortcut ? .shortcut : .automatic, ownBundleIdentifier: ownBundleIdentifier
        )
        // The verdict prints only its case and a language code, never the text.
        log("select-verdict", "Translate on Select verdict",
            metadata: ["app": .string(app.bundleIdentifier), "verdict": .string("\(verdict)")])
        switch verdict {
        case .translate(let source):
            begin(capture, candidate, sourceCode: source, pointer: pointer, viaShortcut: viaShortcut)
        case .sameLanguage where viaShortcut:
            noticeAlreadyInReadingLanguage(capture, candidate, pointer: pointer)
        default:
            return
        }
    }

    /// The automatic trigger skips a selection that is already showing or that the user dismissed.
    private func isAlreadyHandled(_ candidate: SelectionTranslationTarget) -> Bool {
        (candidate == target && model != nil) || candidate == dismissedTarget
    }

    private func noticeAlreadyInReadingLanguage(
        _ capture: SelectedTextCapture, _ candidate: SelectionTranslationTarget, pointer: CGPoint
    ) {
        let name = displayName(for: preferences.preferences.readingLanguage)
        // A translation still running for an older selection must not overwrite the notice.
        translateTask?.cancel()
        runID += 1
        target = candidate
        showNotice("Already in \(name)", in: model, capture: capture, pointer: pointer)
    }

    /// Everything one translation run needs, so `runTranslation` takes one value instead of seven.
    private struct Run {
        let capture: SelectedTextCapture
        let source: String?
        let model: SelectionTranslationStripModel
        let displayName: String
        let targetName: String
        let viaShortcut: Bool
        let pointer: CGPoint
    }

    private static func windowTitle(in snapshot: FocusSnapshot, for pid: pid_t) -> String? {
        snapshot.context?.processIdentifier == pid ? snapshot.context?.featureScopeWindowTitle : nil
    }

    private func readSelection(
        in snapshot: FocusSnapshot, app: (processIdentifier: pid_t, bundleIdentifier: String), pointer: CGPoint
    ) -> SelectedTextCapture? {
        if snapshot.context?.processIdentifier == app.processIdentifier,
           snapshot.capability == .blocked(CredentialFieldDetector.blockedReason) {
            // A username, email, phone or code box: the focus resolver keeps its context but marks it
            // blocked. Return nil without asking the reader, which would read the same field through
            // Accessibility. (Not `.supported` only: a selection in an ordinary editable field is
            // reported as `.blocked("Text is currently selected.")` and must keep working.)
            return nil
        }
        if let input = snapshot.context, input.processIdentifier == app.processIdentifier, !input.selectedText.isEmpty {
            // An editable field already carries its selection in the snapshot: no extra AX calls.
            return SelectedTextCapture(
                text: input.selectedText, rect: input.selectionRect, lineRect: input.caretRect,
                bundleIdentifier: input.bundleIdentifier, processIdentifier: input.processIdentifier,
                isSecure: input.isSecure, source: .snapshot
            )
        }
        return reader.read(frontmost: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, mouseUp: pointer)
    }

    // MARK: - Translating

    private func begin(
        _ capture: SelectedTextCapture, _ candidate: SelectionTranslationTarget,
        sourceCode source: String?, pointer: CGPoint, viaShortcut: Bool
    ) {
        translateTask?.cancel()
        copiedTask?.cancel()
        autoHideTask?.cancel()
        runID += 1
        target = candidate
        dismissedTarget = nil
        let prefs = preferences.preferences
        let name = displayName(for: prefs.readingLanguage)
        let targetName = SelectionTranslationPolicy.englishName(forLanguageCode: prefs.readingLanguage)

        let model = SelectionTranslationStripModel()
        model.targetLanguageName = name
        model.disclosure = engine.activeProviderSendsOffDevice
            ? "The selected text is sent to \(engine.activeHostName ?? "your API provider")."
            : nil
        model.onCopy = { [weak self] in self?.copy() }
        model.onClose = { [weak self] in self?.dismiss(reason: "close-button") }
        self.model = model

        let lineRect = capture.lineRect ?? capture.rect ?? CGRect(origin: pointer, size: CGSize(width: 1, height: 1))
        let present = { [presenter, wandFrame] in
            presenter.show(model: model, selectionRect: capture.rect, lineRect: lineRect, wandFrame: wandFrame())
        }

        if let cached = cache.value(for: capture.text, target: prefs.readingLanguage) {
            model.phase = .shown(cached.translatedText)
            present()
            log("select-shown", "Translate on Select shown", metadata: [
                "cached": .stringConvertible(true), "characters": .stringConvertible(cached.translatedText.count)
            ])
            return
        }
        model.phase = .translating("")
        present()
        let id = runID
        // True only while this run is still the newest and the strip it started for is still up.
        let isCurrent = { [weak self, weak model] () -> Bool in
            guard let self, let model else { return false }
            return self.runID == id && self.model === model && !Task.isCancelled
        }
        log("select-translate", "Translate on Select translating", metadata: [
            "source": .string(source ?? "unknown"), "target": .string(prefs.readingLanguage),
            "characters": .stringConvertible(capture.text.count), "shortcut": .stringConvertible(viaShortcut)
        ])
        translateTask = Task { [weak self] in
            await self?.runTranslation(
                Run(capture: capture, source: source, model: model, displayName: name, targetName: targetName,
                    viaShortcut: viaShortcut, pointer: pointer),
                isCurrent: isCurrent
            )
        }
    }

    /// One translation, from the request to the strip's final phase. Every write after an `await` is
    /// guarded by `isCurrent`, so a superseded or dismissed run changes nothing on screen.
    private func runTranslation(_ run: Run, isCurrent: @escaping () -> Bool) async {
        let (capture, source, model, name) = (run.capture, run.source, run.model, run.displayName)
        let (targetName, viaShortcut, pointer) = (run.targetName, run.viaShortcut, run.pointer)
        let readingLanguage = preferences.preferences.readingLanguage
        let started = Date()
        do {
            let text = try await engine.translate(
                capture.text, sourceLanguage: source.map(SelectionTranslationPolicy.englishName(forLanguageCode:)),
                into: targetName
            ) { [weak self] partial in
                guard isCurrent(), case .translating = model.phase else { return }
                model.phase = .translating(partial)
                self?.presenter.refit()
            }
            guard isCurrent() else { return }
            if SelectionTranslationPolicy.isEcho(output: text, input: capture.text) {
                // The model returned the input: it is already in the reading language (or it declined).
                if viaShortcut {
                    showNotice("Already in \(name)", in: model, capture: capture, pointer: pointer)
                } else {
                    dismiss(reason: "echo")
                }
                return
            }
            cache.store(TranslationResult(
                sourceText: capture.text, sourceLanguage: source ?? "",
                targetLanguage: readingLanguage, translatedText: text
            ))
            model.phase = .shown(text)
            presenter.refit()
            log("select-shown", "Translate on Select shown", metadata: [
                "latency_ms": .stringConvertible(Int(Date().timeIntervalSince(started) * 1000)),
                "characters": .stringConvertible(text.count), "source": .string(source ?? "unknown"),
                "target": .string(readingLanguage), "cached": .stringConvertible(false)
            ])
        } catch is CancellationError {
            return
        } catch {
            // A superseded request can fail with URLError(.cancelled) rather than CancellationError;
            // the id check keeps that failure off the newer strip.
            guard isCurrent() else { return }
            // Only a code, never the description: a provider error can echo the request body, which is
            // the selected text.
            log("select-translate", "Translate on Select failed", level: .warning,
                metadata: ["error": .string(Self.safeErrorCode(error))])
            if viaShortcut {
                model.phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't translate this.")
                presenter.refit()
                autoHide(model, after: 4_000_000_000)
            } else {
                dismiss(reason: "failed")
            }
        }
    }

    /// A short message in the strip, hidden after 2.5 s. With no strip showing (the shortcut on text
    /// already in the reading language) a fresh one is created at the selection.
    private func showNotice(_ text: String, in existing: SelectionTranslationStripModel?, capture: SelectedTextCapture, pointer: CGPoint) {
        let model: SelectionTranslationStripModel
        if let existing {
            model = existing
            model.phase = .notice(text)
            presenter.refit()
        } else {
            model = SelectionTranslationStripModel()
            model.targetLanguageName = displayName(for: preferences.preferences.readingLanguage)
            model.onClose = { [weak self] in self?.dismiss(reason: "close-button") }
            model.phase = .notice(text)
            self.model = model
            let lineRect = capture.lineRect ?? capture.rect ?? CGRect(origin: pointer, size: CGSize(width: 1, height: 1))
            presenter.show(model: model, selectionRect: capture.rect, lineRect: lineRect, wandFrame: wandFrame())
        }
        autoHide(model, after: 2_500_000_000)
    }

    private func autoHide(_ model: SelectionTranslationStripModel, after nanoseconds: UInt64) {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self, weak model] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, let model, !Task.isCancelled, self.model === model else { return }
            self.dismiss(reason: "auto-hide")
        }
    }

    private func copy() {
        guard let model else { return }
        let text: String
        switch model.phase {
        case .shown(let shown), .copied(let shown): text = shown
        default: return
        }
        output.copyToClipboard(text)
        model.phase = .copied(text)
        presenter.refit()
        copiedTask?.cancel()
        copiedTask = Task { [weak self, weak model] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, let model, !Task.isCancelled, self.model === model, case .copied = model.phase else { return }
            model.phase = .shown(text)
            self.presenter.refit()
        }
    }

    // MARK: - Closing

    /// The user moved on, or closed the strip. Cancels everything in flight and hides the strip, but
    /// remembers the selection so the automatic trigger does not bring it straight back.
    /// `reason` names the trigger in the log line: a strip that vanishes "by itself" is otherwise
    /// impossible to tell apart from one the user clicked away.
    private func dismiss(reason: String) {
        pendingTask?.cancel()
        translateTask?.cancel()
        copiedTask?.cancel()
        autoHideTask?.cancel()
        runID += 1
        let wasShowing = model != nil
        model = nil
        presenter.hide()
        dismissedTarget = target
        if wasShowing {
            log("select-dismiss", "Translate on Select dismissed", level: .debug, metadata: ["reason": .string(reason)])
        }
    }

    /// Full teardown: the selection is gone (a plain click, a setting change). Forgets it too, so the
    /// same text selected again is treated as new.
    private func close(reason: String) {
        dismiss(reason: reason)
        target = nil
        dismissedTarget = nil
    }

    // MARK: - Helpers

    /// The error's type, plus the case name (no associated values) for `RewriteError`.
    private static func safeErrorCode(_ error: Error) -> String {
        let type = String(describing: Swift.type(of: error))
        guard error is RewriteError else { return type }
        let described = String(describing: error)
        return "\(type).\(described.prefix { $0 != "(" })"
    }

    private func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func log(
        _ stage: String, _ message: String, level: Logger.Level = .debug,
        metadata: [String: Logger.MetadataValue] = [:]
    ) {
        var fields = metadata
        fields["category"] = "translation"
        fields["stage"] = .string(stage)
        CotabbyLogger.app.log(level: level, "\(message)", metadata: fields)
    }
}

// MARK: - Collaborator protocols

/// What the coordinator needs from the selection shortcut: register one chord, drop it. `CarbonHotKey`
/// is the live implementation; tests pass nil.
@MainActor protocol SelectionHotkeyInstalling: AnyObject {
    func install(keyCode: CGKeyCode, modifiers: UInt32, onPress: @escaping () -> Void)
    func remove()
}

/// The Rewrite engine as Translate on Select sees it: provider facts for the disclosure, one translation.
@MainActor protocol SelectionTranslationRunning: AnyObject {
    var activeProviderSendsOffDevice: Bool { get }
    var activeHostName: String? { get }
    func translate(_ text: String, sourceLanguage: String?, into target: String,
                   onPartial: @escaping @MainActor (String) -> Void) async throws -> String
}

extension RewriteEngine: SelectionTranslationRunning {
    /// Read from the destination the engine would use now, the same answer the Rewrite popup discloses.
    var activeProviderSendsOffDevice: Bool { destination().sendsOffDevice }
    var activeHostName: String? { destination().hostName }

    /// A translation is a rewrite with the translate action and no memory: memory is other people's
    /// messages and has no place in a translation, so it is never gathered and never sent.
    func translate(_ text: String, sourceLanguage: String?, into target: String,
                   onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        var request = RewriteRequest(selection: text, action: .translate(into: target), memory: .empty)
        request.language = sourceLanguage
        request.fixesMistakes = false
        return try await rewrite(request, onPartial: onPartial)
    }
}

/// The one thing the strip's Copy button needs from the host. `LiveSelectionRewriteTextOutput` already
/// writes the clipboard for the Rewrite popup, so it serves both.
@MainActor protocol SelectionTranslationTextOutput: AnyObject {
    func copyToClipboard(_ text: String)
}

extension LiveSelectionRewriteTextOutput: SelectionTranslationTextOutput {}
