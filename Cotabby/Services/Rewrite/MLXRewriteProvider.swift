import Foundation

/// File overview:
/// Rewrites on the second, on-demand MLX server (`MLXRewriteServerController`), which runs an
/// instruct chat model on this Mac. It is the third `RewriteProviding` next to the Apple/llama
/// provider and the API provider, chosen by Settings → Rewrite → "Local (MLX)".
///
/// It reuses `OpenAICompatibleAPIClient.streamChat`, the same call the API provider makes, pointed
/// at the loopback server's chat route. The text never leaves the Mac, so `sendsOffDevice` is false
/// and memory is allowed exactly as for the other local providers. Owned by `RewriteEngine`.
@MainActor
final class MLXRewriteProvider: RewriteProviding {
    static let timeout: TimeInterval = 60
    /// Shown in the popup while the server starts (the first rewrite after idle takes ~10 s); the
    /// first streamed token replaces it.
    static let loadingNote = "Loading MLX model…"

    private let controller: MLXRewriteServerController
    private let client: OpenAICompatibleAPIClient
    private let preferences: @MainActor () -> RewritePreferences
    private let healthCheck: MLXHealthCheck

    init(
        controller: MLXRewriteServerController,
        client: OpenAICompatibleAPIClient,
        preferences: @escaping @MainActor () -> RewritePreferences,
        healthCheck: @escaping MLXHealthCheck = MLXHealthProbe.check(port:)
    ) {
        self.healthCheck = healthCheck
        self.controller = controller
        self.client = client
        self.preferences = preferences
    }

    nonisolated deinit {}

    /// Apple Silicon, mlx-lm ready, and the chosen model downloaded and compatible: exactly when
    /// the resolver would launch it.
    var isAvailable: Bool { controller.canRun(modelID: preferences().mlxModelID) }
    var sendsOffDevice: Bool { false }
    var unavailableReason: String? { controller.unavailableReason(modelID: preferences().mlxModelID) }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        let modelID = preferences().mlxModelID
        // Always sent first: the popup would otherwise sit on "Rewriting…" for the whole start-up,
        // and the first streamed token replaces it. It is never part of the returned text.
        onPartial(Self.loadingNote)
        // Counted as in flight so the idle timer cannot stop the server under a running rewrite.
        controller.beginUse()
        defer { controller.endUse() }
        let configuration = try await controller.readyConfiguration(modelID: modelID)
        let prompt = RewritePromptBuilder.instructPrompt(request)
        do {
            return try await client.streamChat(
                configuration: configuration,
                apiKey: nil,
                messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
                timeout: Self.timeout,
                onPartialRawText: onPartial
            )
        } catch let error as OpenAICompatibleClientError {
            // A 404 may mean the generator died or just that this request failed; `/health` decides.
            if let reason = MLXGeneratorFailure.reason(for: error), let port = configuration.baseURL.port,
               await healthCheck(port) != .healthy {
                controller.manager.reportBroken(port: port, reason: reason)
                throw RewriteError.mlxUnavailable("MLX is restarting…")
            }
            throw error
        }
    }
}
