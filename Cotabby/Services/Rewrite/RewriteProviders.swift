import Foundation

/// File overview:
/// The models a rewrite can run on, behind one narrow protocol so `RewriteEngine` chooses between
/// them without knowing how each talks to its model. `APIRewriteProvider` lives here;
/// `LocalRewriteProvider` is in `LocalRewriteProvider.swift`.
@MainActor
protocol RewriteProviding: AnyObject {
    /// Whether this provider can run a rewrite right now (a model is configured and reachable in
    /// principle; network errors still surface as thrown errors).
    var isAvailable: Bool { get }
    /// Whether the text leaves this Mac (a LAN or public host), for the popup's disclosure.
    var sendsOffDevice: Bool { get }
    /// Runs the rewrite. `onPartial` receives the cumulative raw text while it streams.
    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String
}

/// Rewrites through the user's OpenAI-compatible API (OpenAI, OpenRouter, a vLLM or GPUStack
/// gateway, Ollama). Configuration comes from `RewritePreferencesStore`, the key from its own
/// Keychain item, so changing it never touches autocomplete's endpoint. Owned by `RewriteEngine`.
@MainActor
final class APIRewriteProvider: RewriteProviding {
    static let timeout: TimeInterval = 20

    private let client: OpenAICompatibleAPIClient
    private let preferences: @MainActor () -> RewritePreferences
    private let credentials: OpenAICompatibleCredentialStoring

    init(client: OpenAICompatibleAPIClient, preferences: @escaping @MainActor () -> RewritePreferences,
         credentials: OpenAICompatibleCredentialStoring) {
        self.client = client
        self.preferences = preferences
        self.credentials = credentials
    }

    deinit {}

    /// Built fresh from the current preferences on every read, so a Settings edit takes effect on
    /// the next rewrite without a reload step. `try?` maps an invalid URL to nil, which reads as
    /// "not configured" rather than surfacing a parse error in the popup.
    private var configuration: OpenAICompatibleEndpointConfiguration? {
        let prefs = preferences()
        return try? OpenAICompatibleEndpointConfiguration(
            baseURLString: prefs.apiBaseURL, modelName: prefs.apiModelName, apiMode: .chatCompletions
        )
    }

    var isAvailable: Bool { configuration.map { !$0.modelName.isEmpty } ?? false }

    /// Anything that is not loopback counts as leaving the Mac, including LAN hosts, because the
    /// disclosure is about the text leaving this device, not about the internet.
    var sendsOffDevice: Bool { configuration.map { $0.hostScope != .loopback } ?? true }

    var hostName: String? { configuration?.baseURL.host }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let configuration, !configuration.modelName.isEmpty else { throw RewriteError.noProvider }
        let prompt = RewritePromptBuilder.instructPrompt(request)
        return try await client.streamChat(
            configuration: configuration,
            apiKey: try? credentials.readAPIKey(),
            messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
            timeout: Self.timeout,
            onPartialRawText: onPartial
        )
    }
}
