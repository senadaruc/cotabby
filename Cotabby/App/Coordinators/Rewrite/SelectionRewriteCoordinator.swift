import AppKit
import Combine
import Foundation
import Logging

/// File overview:
/// Selection rewrite's state machine: hidden → button → popup → generating → preview.
///
/// 1. A selection in an eligible field (`SelectionRewriteEligibility`) that stays the same for
///    `stableSelectionDelay` shows the button at the selection's end, if the setting allows it, and
///    arms the ⌃⌥R shortcut either way.
/// 2. The button or the shortcut opens the popup (`SelectionRewritePopupModel`), with the memory
///    toggle set from Settings and disabled when the provider is an API that memory may not reach.
/// 3. An action runs one rewrite (`RewriteEngine`): memory first when asked for
///    (`RewriteMemoryGatherer`), then the model, streaming into the preview. A rewrite whose names or
///    numbers are in neither the selection nor the facts (`AnswerGroundingPolicy`) previews with
///    Replace off.
/// 4. Replace re-validates the selection (`SelectionReplaceValidator`), restoring it once if focus
///    came back from the instruction box, then pastes over it; any mismatch copies the result to the
///    clipboard instead.
///
/// Anything that means the user moved on closes everything and cancels the rewrite: another
/// selection, typing (the selection is replaced or gone), another field or app, Esc. Nothing is
/// stored. Built by `CotabbyAppEnvironment`, started and stopped by `AppDelegate`.
@MainActor
final class SelectionRewriteCoordinator {
    private let snapshots: AnyPublisher<FocusSnapshot, Never>
    private let currentSnapshot: @MainActor () -> FocusSnapshot
    private let refreshFocus: @MainActor () -> Void
    private let presenter: SelectionRewritePresenting
    private let output: SelectionRewriteTextOutput
    private let engine: SelectionRewriteRunning
    private let memory: SelectionRewriteMemoryGathering
    private let preferences: @MainActor () -> RewritePreferences
    private let isAppAllowed: @MainActor (String) -> Bool
    private let hotkey: TranslationHotkeyTap?
    private let keyTap: TemporaryKeyTap?
    private let stableSelectionDelay: UInt64

    private var cancellables: Set<AnyCancellable> = []
    private var target: SelectionRewriteTarget?
    private var targetInput: FocusedInputSnapshot?
    private var stableTask: Task<Void, Never>?
    private var rewriteTask: Task<Void, Never>?
    private var model: SelectionRewritePopupModel?
    private var lastAction: RewriteAction?
    private var lastFacts: [String] = []

    static let escapeKeyCode: CGKeyCode = 53

    init(
        snapshots: AnyPublisher<FocusSnapshot, Never>,
        currentSnapshot: @escaping @MainActor () -> FocusSnapshot,
        refreshFocus: @escaping @MainActor () -> Void,
        presenter: SelectionRewritePresenting,
        output: SelectionRewriteTextOutput,
        engine: SelectionRewriteRunning,
        memory: SelectionRewriteMemoryGathering,
        preferences: @escaping @MainActor () -> RewritePreferences,
        isAppAllowed: @escaping @MainActor (String) -> Bool,
        hotkey: TranslationHotkeyTap?,
        keyTap: TemporaryKeyTap?,
        stableSelectionDelay: UInt64 = 250_000_000
    ) {
        self.snapshots = snapshots
        self.currentSnapshot = currentSnapshot
        self.refreshFocus = refreshFocus
        self.presenter = presenter
        self.output = output
        self.engine = engine
        self.memory = memory
        self.preferences = preferences
        self.isAppAllowed = isAppAllowed
        self.hotkey = hotkey
        self.keyTap = keyTap
        self.stableSelectionDelay = stableSelectionDelay
    }

    nonisolated deinit {}

    func start() {
        snapshots.sink { [weak self] in self?.observe($0) }.store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        close()
    }

    // MARK: - Observing the selection

    private func observe(_ snapshot: FocusSnapshot) {
        // While the user types in the popup's instruction box, focus reports Cotabby or no field;
        // that is not the user leaving the selection.
        if presenter.isPopupKey, snapshot.context == nil || snapshot.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        guard let input = snapshot.context,
              SelectionRewriteEligibility.verdict(for: input, appAllowed: isAppAllowed(input.bundleIdentifier)) == .eligible
        else {
            close()
            return
        }
        let candidate = SelectionRewriteTarget(snapshot: input)
        if candidate == target { return }
        close()
        target = candidate
        targetInput = input
        stableTask = Task { [weak self] in
            guard let self else { return }
            if self.stableSelectionDelay > 0 {
                try? await Task.sleep(nanoseconds: self.stableSelectionDelay)
            }
            guard !Task.isCancelled, self.target == candidate else { return }
            self.armSelection(input)
        }
    }

    private func armSelection(_ input: FocusedInputSnapshot) {
        let prefs = preferences()
        hotkey?.install(keyCode: prefs.shortcutKeyCode, modifiers: prefs.shortcutModifiers) { [weak self] in
            DispatchQueue.main.async { self?.handleShortcut() }
        }
        if prefs.showsButtonOnSelection {
            presenter.showButton(near: input.caretRect) { [weak self] in self?.openPopup() }
        }
    }

    /// ⌃⌥R: open the popup for the current selection.
    func handleShortcut() {
        if target == nil, let input = currentSnapshot().context,
           SelectionRewriteEligibility.verdict(for: input, appAllowed: isAppAllowed(input.bundleIdentifier)) == .eligible {
            target = SelectionRewriteTarget(snapshot: input)
            targetInput = input
        }
        openPopup()
    }

    // MARK: - The popup

    private func openPopup() {
        guard let input = targetInput, model == nil else { return }
        stableTask?.cancel()
        let prefs = preferences()
        let model = SelectionRewritePopupModel()
        model.memoryToggleEnabled = engine.memoryAllowed
        model.usesMemory = engine.memoryAllowed && prefs.usesMemoryByDefault
        if !engine.memoryAllowed {
            model.memoryNote = "Memory stays on this Mac. Allow it in Settings → Rewrite to use it with your API model."
        }
        if engine.activeProviderSendsOffDevice, let host = engine.activeHostName {
            model.disclosure = engine.memoryAllowed
                ? "The selected text and memory facts are sent to \(host)."
                : "The selected text is sent to \(host)."
        }
        model.onAction = { [weak self] in self?.run($0) }
        model.onRetry = { [weak self] in if let action = self?.lastAction { self?.run(action) } }
        model.onReplace = { [weak self] in self?.replace() }
        model.onCopy = { [weak self] in self?.copyPreview() }
        model.onClose = { [weak self] in self?.close() }
        self.model = model
        presenter.showPopup(near: input.caretRect, model: model)
        keyTap?.install { [weak self] keyCode, _ in
            guard keyCode == Self.escapeKeyCode else { return .pass }
            DispatchQueue.main.async { self?.close() }
            return .consume
        }
    }

    private func run(_ action: RewriteAction) {
        guard let input = targetInput, let model else { return }
        lastAction = action
        rewriteTask?.cancel()
        model.phase = .generating("")
        presenter.refit()
        let wantsMemory = model.usesMemory && engine.memoryAllowed
        rewriteTask = Task { [weak self] in
            guard let self else { return }
            var context = RewriteMemoryContext.empty
            if wantsMemory {
                if let found = await self.memory.gather(for: input, selection: input.selectedText) {
                    context = found
                } else {
                    model.memoryNote = "No memory for this person."
                }
            }
            guard !Task.isCancelled, self.model === model else { return }
            do {
                let text = try await self.engine.rewrite(
                    RewriteRequest(selection: input.selectedText, action: action, memory: context),
                    onPartial: { [weak self, weak model] partial in
                        guard let model, self?.model === model, case .generating = model.phase else { return }
                        model.phase = .generating(partial)
                    }
                )
                guard !Task.isCancelled, self.model === model else { return }
                self.lastFacts = context.facts.map(\.text)
                let unsupported = AnswerGroundingPolicy.unsupportedSpecifics(in: text, facts: self.lastFacts, question: input.selectedText)
                model.phase = .preview(text: text, unsupported: unsupported)
            } catch is CancellationError {
                return
            } catch {
                guard self.model === model else { return }
                model.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self.presenter.refit()
        }
    }

    // MARK: - Replace and copy

    private func replace() {
        guard let model, let target, case .preview(let text, let unsupported) = model.phase, unsupported.isEmpty else { return }
        let wasTyping = presenter.isPopupKey
        presenter.hideAll()
        if wasTyping { output.activate(pid: target.processIdentifier) }
        refreshFocus()
        var outcome = SelectionReplaceValidator.outcome(target: target, current: currentSnapshot().context)
        if outcome == .restoreSelectionThenReplace, let range = target.hostSelection,
           output.restoreSelection(range, pid: target.processIdentifier) {
            refreshFocus()
            outcome = SelectionReplaceValidator.outcome(target: target, current: currentSnapshot().context)
        }
        switch outcome {
        case .replace where output.paste(text):
            CotabbyLogger.app.info("Rewrite replaced", metadata: ["category": "rewrite", "characters": .stringConvertible(text.count)])
            close()
            verifyInserted(text, in: target)
        case .copyInstead(let reason):
            copyAndNotify(text, reason: reason)
        default:
            copyAndNotify(text, reason: "Couldn't replace the selection — copied to clipboard.")
        }
    }

    /// Spec: "after inserting, poll until Accessibility shows the new text". Some hosts swallow a
    /// paste silently; then the result goes to the clipboard so it is not lost. Checks a short
    /// prefix of the rewrite around the caret, up to 5 times over about a second, after the inserter
    /// has restored the user's clipboard (~0.3 s).
    private func verifyInserted(_ text: String, in target: SelectionRewriteTarget) {
        let probe = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !probe.isEmpty else { return }
        Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.refreshFocus()
                if let input = self.currentSnapshot().context,
                   SelectionRewriteTarget.fieldKey(for: input) == target.fieldKey,
                   (input.precedingText + input.selectedText + input.trailingText).contains(probe) {
                    return
                }
            }
            self?.output.copyToClipboard(text)
            CotabbyLogger.app.warning("Rewrite not seen in the field; copied to clipboard", metadata: ["category": "rewrite"])
        }
    }

    private func copyPreview() {
        guard let model, case .preview(let text, _) = model.phase else { return }
        output.copyToClipboard(text)
        close()
    }

    private func copyAndNotify(_ text: String, reason: String) {
        output.copyToClipboard(text)
        CotabbyLogger.app.info("Rewrite copied instead", metadata: ["category": "rewrite", "reason": .string(reason)])
        guard let model, let input = targetInput else { return close() }
        model.phase = .notice(reason)
        presenter.showPopup(near: input.caretRect, model: model)
        Task { [weak self, weak model] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, let model, self.model === model else { return }
            self.close()
        }
    }

    private func close() {
        stableTask?.cancel()
        rewriteTask?.cancel()
        stableTask = nil
        rewriteTask = nil
        model = nil
        target = nil
        targetInput = nil
        lastAction = nil
        keyTap?.remove()
        hotkey?.remove()
        presenter.hideAll()
    }
}

/// The narrow surface the coordinator needs from the popup panel. `SelectionRewritePanelController`
/// conforms; tests substitute a stub that records calls. `@MainActor` because the panel is AppKit.
@MainActor protocol SelectionRewritePresenting: AnyObject {
    var isPopupVisible: Bool { get }
    var isPopupKey: Bool { get }
    func showButton(near anchor: CGRect, onPress: @escaping () -> Void)
    func showPopup(near anchor: CGRect, model: SelectionRewritePopupModel)
    func refit()
    func allowKeyboard()
    func hideButton()
    func hideAll()
}
extension SelectionRewritePanelController: SelectionRewritePresenting {}

/// Writes a rewrite into the host and reads back the field. A protocol so tests can record the
/// paste, the clipboard write and the selection restore without touching the pasteboard or AX.
@MainActor protocol SelectionRewriteTextOutput: AnyObject {
    func paste(_ text: String) -> Bool
    func copyToClipboard(_ text: String)
    func restoreSelection(_ range: NSRange, pid: pid_t) -> Bool
    func activate(pid: pid_t)
}

/// The rewrite engine as the coordinator sees it: the provider facts for the popup disclosure, and
/// one generation. Narrower than `RewriteEngine` so tests need no providers.
@MainActor protocol SelectionRewriteRunning: AnyObject {
    var memoryAllowed: Bool { get }
    var activeProviderSendsOffDevice: Bool { get }
    var activeHostName: String? { get }
    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String
}

/// Memory lookup for one rewrite, behind a protocol so tests can return a fixed context.
@MainActor protocol SelectionRewriteMemoryGathering: AnyObject {
    func gather(for input: FocusedInputSnapshot, selection: String) async -> RewriteMemoryContext?
}
extension RewriteMemoryGatherer: SelectionRewriteMemoryGathering {}

extension RewriteEngine: SelectionRewriteRunning {
    var activeProviderSendsOffDevice: Bool { activeProvider.sendsOffDevice }
    var activeHostName: String? { (activeProvider as? APIRewriteProvider)?.hostName }
}

/// Writes a rewrite into the host: pastes over the live selection (paste, not keystrokes, because a
/// typed line break would send a chat message), or puts it on the clipboard.
@MainActor
final class LiveSelectionRewriteTextOutput: SelectionRewriteTextOutput {
    private let inserter: SuggestionInserter
    init(inserter: SuggestionInserter) { self.inserter = inserter }
    nonisolated deinit {}
    func paste(_ text: String) -> Bool { inserter.pasteAtCaret(text) }
    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func restoreSelection(_ range: NSRange, pid: pid_t) -> Bool { AXHelper.setSelectedTextRange(range, onFocusedElementOf: pid) }
    func activate(pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.activate() }
}
