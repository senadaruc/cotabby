import XCTest
@testable import Cotabby

/// The Rewrite settings persist under their own keys and start from safe defaults: local provider,
/// memory never sent to an API.
@MainActor
final class RewritePreferencesStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private static var retained: [AnyObject] = []

    override func setUp() {
        super.setUp()
        suiteName = "RewritePreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> RewritePreferencesStore {
        let store = RewritePreferencesStore(userDefaults: defaults)
        Self.retained.append(store)
        return store
    }

    func test_defaultsAreLocalAndNeverSendMemoryToTheCloud() {
        let prefs = makeStore().preferences
        XCTAssertEqual(prefs.provider, .local)
        XCTAssertFalse(prefs.sendsMemoryToAPI)
        XCTAssertTrue(prefs.showsButtonOnSelection)
        XCTAssertEqual(prefs.shortcutKeyCode, 15)
        XCTAssertEqual(prefs.shortcutModifiers, ShortcutModifierMask.control.rawValue | ShortcutModifierMask.option.rawValue)
    }

    func test_changesPersistAcrossInstances() {
        let store = makeStore()
        store.setProvider(.api)
        store.setAPIBaseURL("https://api.openai.com/v1")
        store.setAPIModelName("gpt-4.1-mini")
        store.setUsesMemoryByDefault(true)
        store.setSendsMemoryToAPI(true)
        store.setShowsButtonOnSelection(false)

        let reloaded = makeStore().preferences
        XCTAssertEqual(reloaded.provider, .api)
        XCTAssertEqual(reloaded.apiBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(reloaded.apiModelName, "gpt-4.1-mini")
        XCTAssertTrue(reloaded.usesMemoryByDefault)
        XCTAssertTrue(reloaded.sendsMemoryToAPI)
        XCTAssertFalse(reloaded.showsButtonOnSelection)
    }

    func test_actionsAndTonesInPopupOrder() {
        XCTAssertEqual(RewriteAction.actions.map(\.label), ["Fix only", "Rewrite", "Shorter", "Longer"])
        XCTAssertEqual(RewriteAction.tones.map(\.label), ["Family", "Friendly", "Close friend", "Formal", "Customer"])
        XCTAssertEqual(RewriteAction.custom("make it warmer").label, "Custom")
    }

    func test_fixTickBoxDefaultsOnAndPersists() {
        let store = makeStore()
        XCTAssertTrue(store.preferences.fixesMistakes)
        store.setFixesMistakes(false)
        XCTAssertFalse(makeStore().preferences.fixesMistakes)
    }
}
