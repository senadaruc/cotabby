import AppKit
import XCTest
@testable import Cotabby

/// File overview:
/// Translate on Select's state machine through stubs: gesture → read → gate → one translation →
/// strip, and everything that must hide, supersede or skip it. Language detection is the real
/// on-device `NaturalLanguage`, so the sentences below are chosen to be detected confidently.
@MainActor
final class SelectionTranslationCoordinatorTests: XCTestCase {
    private static var retained: [AnyObject] = []

    @MainActor
    private final class Presenter: SelectionTranslationPresenting {
        var model: SelectionTranslationStripModel?
        var isVisible = false
        private(set) var showCalls = 0
        var lastWandFrame: CGRect?
        var lastLineRect: CGRect?
        func show(model: SelectionTranslationStripModel, selectionRect: CGRect?, lineRect: CGRect, wandFrame: CGRect?) {
            self.model = model; isVisible = true; showCalls += 1
            lastWandFrame = wandFrame; lastLineRect = lineRect
        }
        func refit() {}
        func hide() { isVisible = false; model = nil }
    }

    @MainActor
    private final class Reader: SelectionReading {
        var capture: SelectedTextCapture?
        private(set) var calls = 0
        func read(frontmost pid: pid_t, bundleIdentifier: String, mouseUp: CGPoint?) -> SelectedTextCapture? {
            calls += 1
            return capture
        }
    }

    @MainActor
    private final class Events: SelectionEventObserving {
        var onSelectionGesture: (@MainActor (CGPoint) -> Void)?
        var onPlainClick: (@MainActor () -> Void)?
        var onMouseDown: (@MainActor () -> Void)?
        var onKeyDown: (@MainActor (CGKeyCode, NSEvent.ModifierFlags) -> Void)?
        var onAppActivated: (@MainActor () -> Void)?
        private(set) var started = false
        func start() { started = true }
        func stop() { started = false }
    }

    private struct RecordedRequest { let text: String; let source: String?; let target: String }

    @MainActor
    private final class Runner: SelectionTranslationRunning {
        var activeProviderSendsOffDevice = false
        var activeHostName: String?
        /// What each call returns, in order; the last entry repeats. Empty: `result`.
        var results: [String] = []
        var result = "Tracy is ready for you 24/7 to help with any questions."
        var echo = false
        var holds = false
        var error: Error?
        var gate: CheckedContinuation<Void, Never>?
        private(set) var calls = 0
        private(set) var requests: [RecordedRequest] = []
        func translate(_ text: String, sourceLanguage: String?, into target: String,
                       onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            requests.append(RecordedRequest(text: text, source: sourceLanguage, target: target))
            calls += 1
            let index = calls - 1
            if holds && index == 0 { await withCheckedContinuation { gate = $0 } }
            if let error { throw error }
            if echo { return text }
            let output = results.isEmpty ? result : results[min(index, results.count - 1)]
            onPartial(output)
            return output
        }
    }

    @MainActor
    private final class Output: SelectionTranslationTextOutput {
        var copied: [String] = []
        func copyToClipboard(_ text: String) { copied.append(text) }
    }

    private let dutch = "Tracy staat 24/7 voor je klaar om je te helpen met eventuele vragen."
    private let otherDutch = "Vergeet niet morgenochtend je paraplu mee te nemen naar het werk."
    private let english = "Thanks for your message, I will reply tomorrow."

    private var current = FocusSnapshot.inactive
    private var allowed = true
    private var override: Bool?
    private var wand: CGRect?
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: TranslationPreferencesStore!

    override func setUp() async throws {
        suiteName = "SelectionTranslationCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = TranslationPreferencesStore(userDefaults: defaults)
        store.setTranslatesSelection(true)
        store.setReadingLanguage("en")
        current = .inactive
        allowed = true
        override = nil
        wand = nil
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func capture(_ text: String, rect: CGRect? = CGRect(x: 50, y: 300, width: 200, height: 18)) -> SelectedTextCapture {
        SelectedTextCapture(
            text: text, rect: rect, lineRect: nil, bundleIdentifier: "com.apple.mail", processIdentifier: 123,
            isSecure: false, source: .selectedText
        )
    }

    private struct Rig {
        let coordinator: SelectionTranslationCoordinator
        let presenter: Presenter
        let reader: Reader
        let events: Events
        let runner: Runner
        let output: Output
    }

    private func make(debounce: UInt64 = 0) -> Rig {
        let presenter = Presenter(), reader = Reader(), events = Events(), runner = Runner(), output = Output()
        reader.capture = capture(dutch)
        let coordinator = SelectionTranslationCoordinator(
            preferences: store,
            currentSnapshot: { [unowned self] in self.current },
            frontmostApplication: { (123, "com.apple.mail") },
            pointerLocation: { CGPoint(x: 100, y: 100) },
            isAppAllowed: { [unowned self] _ in self.allowed },
            windowOverride: { [unowned self] _, _ in self.override },
            wandFrame: { [unowned self] in self.wand },
            presenter: presenter, reader: reader, events: events, engine: runner, output: output,
            hotkey: nil, ownBundleIdentifier: "com.cotabby.test", debounce: debounce
        )
        let objects: [AnyObject] = [coordinator, presenter, reader, events, runner, output]
        Self.retained.append(contentsOf: objects)
        coordinator.start()
        return Rig(coordinator: coordinator, presenter: presenter, reader: reader, events: events, runner: runner, output: output)
    }

    /// The Task hops (debounce, translate) and on-device language detection need a beat.
    private func settle() async {
        await Task.yield(); await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private func select(_ events: Events) async {
        events.onSelectionGesture?(CGPoint(x: 60, y: 310))
        await settle()
    }

    func test_gestureReadsTranslatesAndShowsTheStrip() async {
        let rig = make(); let presenter = rig.presenter; let reader = rig.reader; let events = rig.events; let runner = rig.runner
        await select(events)
        XCTAssertEqual(reader.calls, 1)
        XCTAssertEqual(runner.requests.first?.text, dutch)
        XCTAssertEqual(runner.requests.first?.source, "Dutch")
        XCTAssertEqual(runner.requests.first?.target, "English")
        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(presenter.model?.phase, .shown(runner.result))
    }

    func test_textAlreadyInTheTargetLanguageShowsNothing() async {
        let rig = make(); let presenter = rig.presenter; let reader = rig.reader; let events = rig.events; let runner = rig.runner
        reader.capture = capture(english)
        await select(events)
        XCTAssertEqual(runner.calls, 0)
        XCTAssertEqual(presenter.showCalls, 0)
    }

    func test_dismissedSelectionStaysHiddenUntilTheSelectionChanges() async {
        let rig = make(); let presenter = rig.presenter; let reader = rig.reader; let events = rig.events; let runner = rig.runner
        await select(events)
        events.onKeyDown?(53, [])
        XCTAssertFalse(presenter.isVisible)
        await select(events)
        XCTAssertEqual(presenter.showCalls, 1)
        XCTAssertEqual(runner.calls, 1)
        reader.capture = capture(otherDutch)
        await select(events)
        XCTAssertEqual(presenter.showCalls, 2)
        XCTAssertTrue(presenter.isVisible)
    }

    func test_shortcutShowsADismissedSelectionAgain() async {
        let rig = make(); let coordinator = rig.coordinator; let presenter = rig.presenter; let events = rig.events
        await select(events)
        events.onKeyDown?(53, [])
        coordinator.handleShortcut()
        await settle()
        XCTAssertEqual(presenter.showCalls, 2)
        XCTAssertTrue(presenter.isVisible)
    }

    func test_secondGestureSupersedesARunningTranslation() async {
        let rig = make(); let presenter = rig.presenter; let reader = rig.reader; let events = rig.events; let runner = rig.runner
        runner.holds = true
        runner.results = ["first", "second"]
        await select(events)
        reader.capture = capture(otherDutch)
        await select(events)
        XCTAssertEqual(presenter.model?.phase, .shown("second"))
        runner.gate?.resume()
        runner.gate = nil
        await settle()
        XCTAssertEqual(presenter.model?.phase, .shown("second"))
    }

    func test_keyMouseAndAppSwitchHideTheStrip() async {
        let rig = make(); let presenter = rig.presenter; let reader = rig.reader; let events = rig.events
        let hides: [(String, () -> Void)] = [
            ("key", { events.onKeyDown?(0, []) }),
            ("mouse", { events.onMouseDown?() }),
            ("app", { events.onAppActivated?() })
        ]
        for (index, (name, hide)) in hides.enumerated() {
            // A different text each round so the dismissed selection does not suppress the next show.
            reader.capture = capture(index.isMultiple(of: 2) ? dutch : otherDutch)
            await select(events)
            XCTAssertTrue(presenter.isVisible, name)
            hide()
            XCTAssertFalse(presenter.isVisible, name)
        }
    }

    func test_editableSnapshotIsPreferredOverTheReader() async {
        let rig = make(); let presenter = rig.presenter; let reader = rig.reader; let events = rig.events
        let caret = CGRect(x: 40, y: 200, width: 2, height: 18)
        let input = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "com.apple.mail", processIdentifier: 123, caretRect: caret,
            selectedText: dutch, selectionRect: CGRect(x: 40, y: 200, width: 300, height: 18)
        )
        current = FocusSnapshot(applicationName: "Mail", bundleIdentifier: "com.apple.mail",
                                capability: .supported, context: input)
        await select(events)
        XCTAssertEqual(reader.calls, 0)
        XCTAssertEqual(presenter.lastLineRect, caret)
        XCTAssertTrue(presenter.isVisible)
    }

    func test_cachedTranslationIsShownWithoutAnotherCall() async {
        let rig = make(); let presenter = rig.presenter; let reader = rig.reader; let events = rig.events; let runner = rig.runner
        await select(events)
        events.onKeyDown?(53, [])
        reader.capture = capture(otherDutch)
        await select(events)
        reader.capture = capture(dutch)
        await select(events)
        XCTAssertEqual(runner.calls, 2)
        XCTAssertEqual(presenter.model?.phase, .shown(runner.results.last ?? runner.result))
    }

    func test_echoIsHiddenForAutomaticAndNoticedForShortcut() async {
        let rig = make(); let coordinator = rig.coordinator; let presenter = rig.presenter; let events = rig.events; let runner = rig.runner
        runner.echo = true
        await select(events)
        XCTAssertFalse(presenter.isVisible)
        coordinator.handleShortcut()
        await settle()
        XCTAssertEqual(presenter.model?.phase, .notice("Already in English"))
    }

    func test_copyPutsTheTranslationOnTheClipboard() async {
        let rig = make(); let presenter = rig.presenter; let events = rig.events; let runner = rig.runner; let output = rig.output
        await select(events)
        presenter.model?.onCopy()
        XCTAssertEqual(output.copied, [runner.result])
        XCTAssertEqual(presenter.model?.phase, .copied(runner.result))
    }

    func test_windowOverrideOffAndDisallowedAppShowNothing() async {
        let rig = make(); let presenter = rig.presenter; let reader = rig.reader; let events = rig.events
        override = false
        await select(events)
        XCTAssertEqual(presenter.showCalls, 0)
        override = nil
        allowed = false
        await select(events)
        XCTAssertEqual(presenter.showCalls, 0)
        XCTAssertEqual(reader.calls, 0)
    }

    func test_turningTheSettingOffHidesTheStripAndStopsObserving() async {
        let rig = make(); let presenter = rig.presenter; let events = rig.events
        XCTAssertTrue(events.started)
        await select(events)
        XCTAssertTrue(presenter.isVisible)
        store.setTranslatesSelection(false)
        XCTAssertFalse(presenter.isVisible)
        XCTAssertFalse(events.started)
    }

    func test_hideHidesTheStrip() async {
        let rig = make(); let coordinator = rig.coordinator; let presenter = rig.presenter; let events = rig.events
        await select(events)
        coordinator.hide()
        XCTAssertFalse(presenter.isVisible)
    }

    func test_credentialFieldSnapshotIsNeverReadNorTranslated() async {
        let rig = make()
        let input = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "com.apple.mail", processIdentifier: 123, selectedText: dutch
        )
        current = FocusSnapshot(applicationName: "Mail", bundleIdentifier: "com.apple.mail",
                                capability: .blocked(CredentialFieldDetector.blockedReason), context: input)
        await select(rig.events)
        XCTAssertEqual(rig.reader.calls, 0)
        XCTAssertEqual(rig.runner.calls, 0)
        XCTAssertEqual(rig.presenter.showCalls, 0)
    }

    func test_triggerChangedDuringDebounceCancelsTheGesture() async {
        let rig = make(debounce: 50_000_000)
        rig.events.onSelectionGesture?(CGPoint(x: 60, y: 310))
        store.setSelectionTrigger(.shortcut)
        try? await Task.sleep(nanoseconds: 120_000_000)
        await settle()
        XCTAssertEqual(rig.runner.calls, 0)
        XCTAssertEqual(rig.presenter.showCalls, 0)
    }
}
