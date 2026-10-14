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
        store.setCloudProvider(.custom)
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
        XCTAssertEqual(RewriteAction.tones.map(\.label), ["Family", "Friendly", "Close friend", "Formal", "Customer"])
        XCTAssertEqual(RewriteAction.refinements.map(\.label), ["Shorter", "Longer"])
        XCTAssertEqual(RewriteAction.custom("make it warmer").label, "Custom")
    }

    func test_fixTickBoxDefaultsOnAndPersists() {
        let store = makeStore()
        XCTAssertTrue(store.preferences.fixesMistakes)
        store.setFixesMistakes(false)
        XCTAssertFalse(makeStore().preferences.fixesMistakes)
    }

    // MARK: - Cloud providers

    func test_newInstallsStartOnClaude() {
        XCTAssertEqual(makeStore().preferences.cloudProvider, .anthropic)
        XCTAssertEqual(makeStore().preferences.apiModelName, "claude-opus-5-5")
    }

    /// A user who set up an endpoint before providers existed keeps it as Custom.
    func test_legacyEndpointBecomesCustom() {
        defaults.set("https://gpustack.local/v1", forKey: "cotabbyRewriteAPIBaseURL")
        defaults.set("qwen3", forKey: "cotabbyRewriteAPIModelName")
        let prefs = makeStore().preferences
        XCTAssertEqual(prefs.cloudProvider, .custom)
        XCTAssertEqual(prefs.apiModelName, "qwen3")
        XCTAssertEqual(prefs.effectiveBaseURL, "https://gpustack.local/v1")
    }

    func test_eachProviderRemembersItsOwnModel() {
        let store = makeStore()
        store.setCloudProvider(.anthropic)
        store.setAPIModelName("claude-haiku-5-5")
        store.setCloudProvider(.openAI)
        store.setAPIModelName("some-openai-model")
        store.setCloudProvider(.anthropic)
        XCTAssertEqual(store.preferences.apiModelName, "claude-haiku-5-5")
        let reloaded = makeStore().preferences
        XCTAssertEqual(reloaded.cloudProvider, .anthropic)
        XCTAssertEqual(reloaded.apiModelName, "claude-haiku-5-5")
    }

    func test_providerCatalog() {
        XCTAssertEqual(RewriteCloudProvider.anthropic.baseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(RewriteCloudProvider.openAI.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(RewriteCloudProvider.gemini.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertNil(RewriteCloudProvider.custom.baseURL)
        XCTAssertEqual(RewriteCloudProvider.custom.keychainSuffix, "rewrite-endpoint", "keeps the key saved before providers existed")
        XCTAssertEqual(RewriteCloudProvider.openAI.keychainSuffix, "rewrite-endpoint.openAI")
        XCTAssertTrue(RewriteCloudProvider.anthropic.suggestedModels.contains("claude-sonnet-5-5"))
    }

    func test_mlxModelDefaultsToTheInstructModelAndPersists() {
        let store = makeStore()
        XCTAssertEqual(store.preferences.mlxModelID, "mlx-community/gemma-4-e4b-it-4bit")
        store.setProvider(.mlx)
        store.setMLXModelID("mlx-community/other-it")
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.preferences.provider, .mlx)
        XCTAssertEqual(reloaded.preferences.mlxModelID, "mlx-community/other-it")
        XCTAssertEqual(defaults.string(forKey: "cotabbyRewriteMLXModel"), "mlx-community/other-it")
    }

    func test_storedMLXProviderFallsBackToLocalWithoutAppleSilicon() {
        defaults.set("mlx", forKey: "cotabbyRewriteProvider")
        XCTAssertEqual(RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: false).preferences.provider, .local)
        XCTAssertEqual(RewritePreferencesStore(userDefaults: defaults, isAppleSilicon: true).preferences.provider, .mlx)
    }
}
