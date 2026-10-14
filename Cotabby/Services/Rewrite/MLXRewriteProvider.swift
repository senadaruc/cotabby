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

    init(
        controller: MLXRewriteServerController,
        client: OpenAICompatibleAPIClient,
        preferences: @escaping @MainActor () -> RewritePreferences
    ) {
        self.controller = controller
        self.client = client
        self.preferences = preferences
    }

    nonisolated deinit {}

    /// Apple Silicon, mlx-lm ready, and the chosen model downloaded and compatible: exactly when
    /// the resolver would launch it.
    var isAvailable: Bool { controller.canRun(modelID: preferences().mlxModelID) }
    var sendsOffDevice: Bool { false }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        let modelID = preferences().mlxModelID
        // The popup would otherwise sit on "Rewriting…" for the whole start-up.
        if case .ready = controller.manager.state {} else { onPartial(Self.loadingNote) }
        controller.noteUse()
        // Restart the idle countdown when the rewrite ends too, so a long one is not cut off.
        defer { controller.noteUse() }
        let configuration = try await controller.readyConfiguration(modelID: modelID)
        let prompt = RewritePromptBuilder.instructPrompt(request)
        return try await client.streamChat(
            configuration: configuration,
            apiKey: nil,
            messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
            timeout: Self.timeout,
            onPartialRawText: onPartial
        )
    }
}
