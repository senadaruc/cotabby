import Combine
import CoreGraphics
import Foundation

/// Owns the Rewrite settings and persists them in `UserDefaults`.
///
/// Its own store, like `TranslationPreferencesStore`, because nothing in autocomplete reads these
/// values: the rewrite coordinator, the engine and the Rewrite settings pane are the only readers.
/// The API key is not here; it lives in the Keychain (`KeychainOpenAICompatibleCredentialStore`
/// with the `rewrite-endpoint` suffix). Built once by `CotabbyAppEnvironment`.
@MainActor
final class RewritePreferencesStore: ObservableObject {
    @Published private(set) var preferences: RewritePreferences

    private let userDefaults: UserDefaults

    private enum Key {
        static let provider = "cotabbyRewriteProvider"
        static let apiBaseURL = "cotabbyRewriteAPIBaseURL"
        /// Before services existed: the one model name, which now belongs to `custom`.
        static let apiModelName = "cotabbyRewriteAPIModelName"
        static let cloudProvider = "cotabbyRewriteCloudProvider"
        static let modelsByProvider = "cotabbyRewriteModelsByProvider"
        /// Retired: rewrite used to have its own MLX model. It now reuses autocomplete's, so the key
        /// is only removed.
        static let legacyMLXModel = "cotabbyRewriteMLXModel"
        static let usesMemory = "cotabbyRewriteUsesMemory"
        static let sendsMemoryToAPI = "cotabbyRewriteSendsMemoryToAPI"
        static let showsButton = "cotabbyRewriteShowsButton"
        static let fixesMistakes = "cotabbyRewriteFixesMistakes"
    }

    /// `isAppleIntelligenceAvailable` only matters once: a stored `local` (the old "Apple Intelligence
    /// else Cotabby's model" choice) becomes whichever of the two it was actually running.
    init(
        userDefaults: UserDefaults = .standard,
        isAppleSilicon: Bool = MLXHardware.isAppleSilicon,
        isAppleIntelligenceAvailable: Bool = false
    ) {
        self.userDefaults = userDefaults
        let defaults = RewritePreferences.defaults
        var loaded = defaults
        let stored = userDefaults.string(forKey: Key.provider)
        if stored == "local" {
            // Written back so the choice stays put if Apple Intelligence availability changes later.
            loaded.provider = isAppleIntelligenceAvailable ? .appleIntelligence : .openSource
            userDefaults.set(loaded.provider.rawValue, forKey: Key.provider)
        } else {
            loaded.provider = stored.flatMap(RewriteProviderKind.init(rawValue:)) ?? defaults.provider
        }
        // MLX needs Apple Silicon; a stored choice (e.g. synced settings) falls back to the local
        // llama path so the picker always has a matching entry.
        if loaded.provider == .mlx, !isAppleSilicon { loaded.provider = .openSource }
        userDefaults.removeObject(forKey: Key.legacyMLXModel)
        loaded.apiBaseURL = userDefaults.string(forKey: Key.apiBaseURL) ?? defaults.apiBaseURL
        loaded.modelsByProvider = userDefaults.dictionary(forKey: Key.modelsByProvider) as? [String: String] ?? [:]
        if let stored = userDefaults.string(forKey: Key.cloudProvider).flatMap(RewriteCloudProvider.init(rawValue:)) {
            loaded.cloudProvider = stored
        } else if !loaded.apiBaseURL.isEmpty {
            // Set up before services existed: the typed endpoint stays the user's choice, as Custom.
            loaded.cloudProvider = .custom
            if let legacyModel = userDefaults.string(forKey: Key.apiModelName), loaded.modelsByProvider["custom"] == nil {
                loaded.modelsByProvider["custom"] = legacyModel
            }
        }
        loaded.usesMemoryByDefault = userDefaults.object(forKey: Key.usesMemory) as? Bool ?? defaults.usesMemoryByDefault
        loaded.sendsMemoryToAPI = userDefaults.object(forKey: Key.sendsMemoryToAPI) as? Bool ?? defaults.sendsMemoryToAPI
        loaded.showsButtonOnSelection = userDefaults.object(forKey: Key.showsButton) as? Bool ?? defaults.showsButtonOnSelection
        loaded.fixesMistakes = userDefaults.object(forKey: Key.fixesMistakes) as? Bool ?? defaults.fixesMistakes
        preferences = loaded
    }

    func setProvider(_ provider: RewriteProviderKind) {
        preferences.provider = provider
        userDefaults.set(provider.rawValue, forKey: Key.provider)
    }

    func setAPIBaseURL(_ value: String) {
        preferences.apiBaseURL = value
        userDefaults.set(value, forKey: Key.apiBaseURL)
    }

    func setCloudProvider(_ provider: RewriteCloudProvider) {
        preferences.cloudProvider = provider
        userDefaults.set(provider.rawValue, forKey: Key.cloudProvider)
    }

    /// Sets the model for the current service only.
    func setAPIModelName(_ value: String) {
        preferences.apiModelName = value
        userDefaults.set(preferences.modelsByProvider, forKey: Key.modelsByProvider)
    }

    func setUsesMemoryByDefault(_ value: Bool) {
        preferences.usesMemoryByDefault = value
        userDefaults.set(value, forKey: Key.usesMemory)
    }

    func setSendsMemoryToAPI(_ value: Bool) {
        preferences.sendsMemoryToAPI = value
        userDefaults.set(value, forKey: Key.sendsMemoryToAPI)
    }

    func setFixesMistakes(_ value: Bool) {
        preferences.fixesMistakes = value
        userDefaults.set(value, forKey: Key.fixesMistakes)
    }

    func setShowsButtonOnSelection(_ value: Bool) {
        preferences.showsButtonOnSelection = value
        userDefaults.set(value, forKey: Key.showsButton)
    }
}
