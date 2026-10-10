import XCTest
@testable import Cotabby

/// The API provider sends the rewrite prompt to the configured model with the Keychain key, and
/// reports itself unavailable until a URL and model are set.
@MainActor
final class APIRewriteProviderTests: XCTestCase {
    private static var retained: [AnyObject] = []

    func test_unavailableUntilConfigured() {
        var prefs = RewritePreferences.defaults
        let provider = APIRewriteProvider(client: OpenAICompatibleAPIClient(), preferences: { prefs },
                                          credentials: InMemoryOpenAICompatibleCredentialStore())
        Self.retained.append(provider)
        XCTAssertFalse(provider.isAvailable)
        prefs.apiBaseURL = "https://api.example.com/v1"
        prefs.apiModelName = "gpt-4.1-mini"
        XCTAssertTrue(provider.isAvailable)
        XCTAssertTrue(provider.sendsOffDevice)
        XCTAssertEqual(provider.hostName, "api.example.com")
    }

    func test_loopbackEndpointIsNotOffDevice() {
        var prefs = RewritePreferences.defaults
        prefs.apiBaseURL = "http://127.0.0.1:11434/v1"
        prefs.apiModelName = "llama3"
        let provider = APIRewriteProvider(client: OpenAICompatibleAPIClient(), preferences: { prefs },
                                          credentials: InMemoryOpenAICompatibleCredentialStore())
        Self.retained.append(provider)
        XCTAssertFalse(provider.sendsOffDevice)
    }
}
