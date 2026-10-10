import Combine
import XCTest
@testable import Cotabby

/// The coordinator's state machine: button after a stable selection, popup on press, one rewrite at a
/// time, Replace only over the original selection, and everything closed when the user moves on.
@MainActor
final class SelectionRewriteCoordinatorTests: XCTestCase {
    private static var retained: [AnyObject] = []

    @MainActor
    private final class Presenter: SelectionRewritePresenting {
        var isPopupVisible = false
        var isPopupKey = false
        var buttonPress: (() -> Void)?
        var popupModel: SelectionRewritePopupModel?
        func showButton(near anchor: CGRect, onPress: @escaping () -> Void) { buttonPress = onPress }
        func showPopup(near anchor: CGRect, model: SelectionRewritePopupModel) { popupModel = model; isPopupVisible = true; buttonPress = nil }
        func refit() {}
        func allowKeyboard() { isPopupKey = true }
        func hideButton() { buttonPress = nil }
        func hideAll() { buttonPress = nil; popupModel = nil; isPopupVisible = false; isPopupKey = false }
    }

    @MainActor
    private final class Output: SelectionRewriteTextOutput {
        var pasted: [String] = []
        var copied: [String] = []
        func paste(_ text: String) -> Bool { pasted.append(text); return true }
        func copyToClipboard(_ text: String) { copied.append(text) }
        func restoreSelection(_ range: NSRange, pid: pid_t) -> Bool { false }
        func activate(pid: pid_t) {}
    }

    @MainActor
    private final class Runner: SelectionRewriteRunning {
        var memoryAllowed = true
        var activeProviderSendsOffDevice = false
        var activeHostName: String?
        var result = "Please let me know if the dates work for you."
        var gate: CheckedContinuation<Void, Never>?
        var holds = false
        /// When true, the first call waits on `gate` and then throws `URLError(.cancelled)`, the way a
        /// superseded URLSession request fails. Later calls return at once.
        var cancelFirstAfterGate = false
        private(set) var calls = 0
        private(set) var requests: [RewriteRequest] = []
        func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            requests.append(request)
            calls += 1
            if calls == 1 && cancelFirstAfterGate {
                await withCheckedContinuation { gate = $0 }
                throw URLError(.cancelled)
            }
            if holds { await withCheckedContinuation { gate = $0 } }
            onPartial(result)
            return result
        }
    }

    @MainActor
    private final class Memory: SelectionRewriteMemoryGathering {
        var context: RewriteMemoryContext?
        func gather(for input: FocusedInputSnapshot, selection: String) async -> RewriteMemoryContext? { context }
    }

    private let draft = "Please let me know if te dates are ok and wors for you."
    private var subject = PassthroughSubject<FocusSnapshot, Never>()
    private var current = FocusSnapshot.inactive

    private func snapshot(selected: String, element: String = "composer", preceding: String = "Dear Richard, ") -> FocusSnapshot {
        let input = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "net.whatsapp.WhatsApp", elementIdentifier: element, precedingText: preceding,
            selection: NSRange(location: 14, length: (selected as NSString).length),
            selectedText: selected, hostSelection: NSRange(location: 14, length: (selected as NSString).length)
        )
        return FocusSnapshot(applicationName: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp",
                             capability: selected.isEmpty ? .supported : .blocked("Text is currently selected."), context: input)
    }

    private func make(prefs: RewritePreferences = .defaults)
        -> (SelectionRewriteCoordinator, Presenter, Output, Runner, Memory) {
        let presenter = Presenter(), output = Output(), runner = Runner(), memory = Memory()
        subject = PassthroughSubject()
        let coordinator = SelectionRewriteCoordinator(
            snapshots: subject.eraseToAnyPublisher(),
            currentSnapshot: { [unowned self] in self.current },
            refreshFocus: {},
            presenter: presenter, output: output, engine: runner, memory: memory,
            preferences: { prefs }, isAppAllowed: { _ in true }, hotkey: nil, keyTap: nil,
            stableSelectionDelay: 0
        )
        let objects: [AnyObject] = [coordinator, presenter, output, runner, memory]
        Self.retained.append(contentsOf: objects)
        coordinator.start()
        return (coordinator, presenter, output, runner, memory)
    }

    private func send(_ snapshot: FocusSnapshot) async {
        current = snapshot
        subject.send(snapshot)
        await Task.yield(); await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    func test_stableSelectionShowsButtonAndPressOpensPopup() async {
        let (_, presenter, _, _, _) = make()
        await send(snapshot(selected: draft))
        XCTAssertNotNil(presenter.buttonPress)
        presenter.buttonPress?()
        XCTAssertNotNil(presenter.popupModel)
        XCTAssertEqual(presenter.popupModel?.phase, .actions)
    }

    func test_buttonOffShowsNothingUntilShortcut() async {
        var prefs = RewritePreferences.defaults
        prefs.showsButtonOnSelection = false
        let (coordinator, presenter, _, _, _) = make(prefs: prefs)
        await send(snapshot(selected: draft))
        XCTAssertNil(presenter.buttonPress)
        coordinator.handleShortcut()
        XCTAssertNotNil(presenter.popupModel)
    }

    func test_actionPreviewsThenReplacePastes() async {
        let (_, presenter, output, runner, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixGrammar)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: runner.result, unsupported: []))
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(output.pasted, [runner.result])
        XCTAssertNil(presenter.popupModel, "The popup closes after a successful replace")
    }

    func test_replaceAfterSelectionChangedCopiesInstead() async {
        let (_, presenter, output, runner, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 20_000_000)
        current = snapshot(selected: "something else entirely here")
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(output.pasted.isEmpty)
        XCTAssertEqual(output.copied, [runner.result])
    }

    func test_typingIntoHostWhileGeneratingClosesAndIgnoresResult() async {
        let (_, presenter, output, runner, _) = make()
        runner.holds = true
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 10_000_000)
        // Typing replaced the selection: the field now has a caret and different text.
        await send(snapshot(selected: ""))
        XCTAssertNil(presenter.popupModel)
        runner.gate?.resume()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(output.pasted.isEmpty)
        XCTAssertTrue(output.copied.isEmpty)
    }

    func test_memoryUsedWhenToggledAndAllowed() async {
        let (_, presenter, _, runner, memory) = make()
        memory.context = RewriteMemoryContext(facts: [.init(text: "Dinner on the 28th", source: "whatsapp", sender: "Richard")], styleExamples: [])
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.usesMemory = true
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(runner.requests.first?.memory, memory.context)
    }

    func test_memoryToggleDisabledForCloudWhenNotAllowed() async {
        let (_, presenter, _, runner, _) = make()
        runner.memoryAllowed = false
        runner.activeProviderSendsOffDevice = true
        runner.activeHostName = "api.openai.com"
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        XCTAssertEqual(presenter.popupModel?.memoryToggleEnabled, false)
        XCTAssertEqual(presenter.popupModel?.usesMemory, false)
        XCTAssertEqual(presenter.popupModel?.disclosure, "The selected text is sent to api.openai.com.")
    }

    func test_ungroundedNameBlocksReplace() async {
        let (_, presenter, output, runner, _) = make()
        runner.result = "Please let me know if the dates work for you and Arnaud."
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: runner.result, unsupported: ["Arnaud"]))
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(output.pasted.isEmpty)
    }

    func test_pasteTheHostIgnoredIsCopied() async {
        let (_, presenter, output, runner, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixGrammar)
        try? await Task.sleep(nanoseconds: 20_000_000)
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        // The field still shows the old text: the paste never landed.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(output.copied, [runner.result])
    }

    func test_clearingSelectionHidesButton() async {
        let (_, presenter, _, _, _) = make()
        await send(snapshot(selected: draft))
        XCTAssertNotNil(presenter.buttonPress)
        await send(snapshot(selected: ""))
        XCTAssertNil(presenter.buttonPress)
    }

    func test_retryWhileGeneratingIgnoresTheSupersededRun() async {
        let (_, presenter, _, runner, _) = make()
        runner.cancelFirstAfterGate = true
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 10_000_000)
        let firstGate = runner.gate
        // Retry supersedes the held first run; the second run completes straight away.
        runner.result = "Please let me know if the dates work for you soon."
        presenter.popupModel?.onRetry()
        try? await Task.sleep(nanoseconds: 20_000_000)
        // The superseded run now fails with URLError(.cancelled), as a cancelled URLSession request does.
        firstGate?.resume()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.popupModel?.phase, .preview(text: runner.result, unsupported: []))
    }

    func test_noMemoryForThisPersonNote() async {
        let (_, presenter, _, _, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.usesMemory = true
        presenter.popupModel?.onAction(.rewrite)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.popupModel?.memoryNote, "No memory for this person.")
    }

    func test_disclosureFollowsTheMemoryToggle() async {
        let (_, presenter, _, runner, _) = make()
        runner.activeProviderSendsOffDevice = true
        runner.activeHostName = "api.example.com"
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        XCTAssertEqual(presenter.popupModel?.disclosure, "The selected text is sent to api.example.com.")
        presenter.popupModel?.usesMemory = true
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(presenter.popupModel?.disclosure, "The selected text and memory facts are sent to api.example.com.")
        presenter.popupModel?.usesMemory = false
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(presenter.popupModel?.disclosure, "The selected text is sent to api.example.com.")
    }

    func test_verifySucceedsWithoutCopy() async {
        let (_, presenter, output, runner, _) = make()
        await send(snapshot(selected: draft))
        presenter.buttonPress?()
        presenter.popupModel?.onAction(.fixGrammar)
        try? await Task.sleep(nanoseconds: 20_000_000)
        presenter.popupModel?.onReplace()
        try? await Task.sleep(nanoseconds: 30_000_000)
        // The host shows the rewrite in the same field now, so the poll sees it and nothing is copied.
        current = snapshot(selected: "", preceding: "Dear Richard, " + runner.result)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(output.pasted, [runner.result])
        XCTAssertTrue(output.copied.isEmpty)
    }
}
