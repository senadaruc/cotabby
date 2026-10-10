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
        static let apiModelName = "cotabbyRewriteAPIModelName"
        static let usesMemory = "cotabbyRewriteUsesMemory"
        static let sendsMemoryToAPI = "cotabbyRewriteSendsMemoryToAPI"
        static let showsButton = "cotabbyRewriteShowsButton"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let defaults = RewritePreferences.defaults
        var loaded = defaults
        loaded.provider = userDefaults.string(forKey: Key.provider).flatMap(RewriteProviderKind.init(rawValue:)) ?? defaults.provider
        loaded.apiBaseURL = userDefaults.string(forKey: Key.apiBaseURL) ?? defaults.apiBaseURL
        loaded.apiModelName = userDefaults.string(forKey: Key.apiModelName) ?? defaults.apiModelName
        loaded.usesMemoryByDefault = userDefaults.object(forKey: Key.usesMemory) as? Bool ?? defaults.usesMemoryByDefault
        loaded.sendsMemoryToAPI = userDefaults.object(forKey: Key.sendsMemoryToAPI) as? Bool ?? defaults.sendsMemoryToAPI
        loaded.showsButtonOnSelection = userDefaults.object(forKey: Key.showsButton) as? Bool ?? defaults.showsButtonOnSelection
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

    func setAPIModelName(_ value: String) {
        preferences.apiModelName = value
        userDefaults.set(value, forKey: Key.apiModelName)
    }

    func setUsesMemoryByDefault(_ value: Bool) {
        preferences.usesMemoryByDefault = value
        userDefaults.set(value, forKey: Key.usesMemory)
    }

    func setSendsMemoryToAPI(_ value: Bool) {
        preferences.sendsMemoryToAPI = value
        userDefaults.set(value, forKey: Key.sendsMemoryToAPI)
    }

    func setShowsButtonOnSelection(_ value: Bool) {
        preferences.showsButtonOnSelection = value
        userDefaults.set(value, forKey: Key.showsButton)
    }
}
