import Foundation

/// File overview:
/// Rewrites with the MLX model autocomplete uses, on whichever server can serve it. There is no
/// rewrite-only model: the model is `suggestionSettings.mlxModelID`.
///
/// - If autocomplete is on MLX and its server is `.ready`, the rewrite goes to that server. No
///   second process, no second copy of the weights.
/// - Otherwise the on-demand `MLXRewriteServerController` starts a second server on the same model
///   (the first rewrite after idle takes ~10 s) and stops it after it has been idle for a while.
///
/// The prompt follows the model: an instruct or chat model (`MLXModelCompatibility.isInstructName`)
/// gets the instruct prompt through `streamChat`; a base model gets the base prompt with the example
/// through the completions route, with the rewrite stop sequences and a budget from the selection.
/// Weaker on base models, which the Settings pane says. The text never leaves the Mac, so
/// `sendsOffDevice` is false and memory is allowed as for the other local providers. Follow-up E's
/// broken-generator report goes to whichever server served the request. Owned by `RewriteEngine`.
@MainActor
final class MLXRewriteProvider: RewriteProviding {
    static let timeout: TimeInterval = 60
    /// Shown in the popup while the on-demand server starts; the first streamed token replaces it.
    static let loadingNote = "Loading MLX model…"

    private let controller: MLXRewriteServerController
    private let autocompleteServer: MLXServerManager
    private let autocompleteEngine: @MainActor () -> SuggestionEngineKind
    private let modelID: @MainActor () -> String
    private let client: OpenAICompatibleAPIClient
    private let healthCheck: MLXHealthCheck

    init(
        controller: MLXRewriteServerController,
        autocompleteServer: MLXServerManager,
        autocompleteEngine: @escaping @MainActor () -> SuggestionEngineKind,
        modelID: @escaping @MainActor () -> String,
        client: OpenAICompatibleAPIClient,
        healthCheck: @escaping MLXHealthCheck = MLXHealthProbe.check(port:)
    ) {
        self.controller = controller
        self.autocompleteServer = autocompleteServer
        self.autocompleteEngine = autocompleteEngine
        self.modelID = modelID
        self.client = client
        self.healthCheck = healthCheck
    }

    nonisolated deinit {}

    /// Autocomplete's server when autocomplete is on MLX and that server is ready; nil otherwise.
    private var sharedConfiguration: OpenAICompatibleEndpointConfiguration? {
        guard autocompleteEngine() == .mlx else { return nil }
        return try? autocompleteServer.readyConfiguration
    }

    /// A ready autocomplete server, or Apple Silicon with mlx-lm ready and the model downloaded and
    /// compatible: exactly when a rewrite could be served.
    var isAvailable: Bool { sharedConfiguration != nil || controller.canRun(modelID: modelID()) }
    var sendsOffDevice: Bool { false }
    var unavailableReason: String? {
        sharedConfiguration != nil ? nil : controller.unavailableReason(modelID: modelID())
    }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        if let shared = sharedConfiguration {
            return try await send(request, to: shared, server: autocompleteServer, onPartial: onPartial)
        }
        // Always sent first: the popup would otherwise sit on "Rewriting…" for the whole start-up,
        // and the first streamed token replaces it. It is never part of the returned text.
        onPartial(Self.loadingNote)
        // Counted as in flight so the idle timer cannot stop the server under a running rewrite.
        controller.beginUse()
        defer { controller.endUse() }
        let configuration = try await controller.readyConfiguration(modelID: modelID())
        return try await send(request, to: configuration, server: controller.manager, onPartial: onPartial)
    }

    /// Streams the rewrite to `configuration`'s server, shaped for the model that server runs.
    private func send(
        _ request: RewriteRequest,
        to configuration: OpenAICompatibleEndpointConfiguration,
        server: MLXServerManager,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        do {
            if Self.isInstruct(modelID: configuration.modelName) {
                let prompt = RewritePromptBuilder.instructPrompt(request)
                return try await client.streamChat(
                    configuration: configuration,
                    apiKey: nil,
                    messages: [.init(role: "system", content: prompt.system), .init(role: "user", content: prompt.user)],
                    timeout: Self.timeout,
                    onPartialRawText: onPartial
                )
            }
            return try await client.generate(
                configuration: configuration,
                apiKey: nil,
                prompt: RewritePromptBuilder.basePrompt(request),
                options: LocalEndpointRewriteProvider.completionOptions(for: request),
                onPartialRawText: onPartial
            )
        } catch let error as OpenAICompatibleClientError {
            // A 404 may mean the generator died or just that this request failed; `/health` decides.
            if let reason = MLXGeneratorFailure.reason(for: error), let port = configuration.baseURL.port {
                let health = await healthCheck(port)
                // A cancelled rewrite says nothing about the server (see the engine's same guard).
                if Task.isCancelled || health == .cancelled { throw CancellationError() }
                guard health != .healthy else { throw error }
                server.reportBroken(port: port, reason: reason)
                throw RewriteError.mlxUnavailable("MLX is restarting…")
            }
            throw error
        }
    }

    /// Whether the repo name ("gemma-4-e4b-it-4bit" in "org/gemma-4-e4b-it-4bit") marks an
    /// instruction-following model. Unknown names count as base: the base prompt works on both,
    /// the instruct prompt only on chat-tuned models.
    static func isInstruct(modelID: String) -> Bool {
        let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return MLXModelCompatibility.isInstructName(name)
    }
}
