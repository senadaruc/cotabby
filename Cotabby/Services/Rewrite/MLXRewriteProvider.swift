import Foundation

/// File overview:
/// Rewrites with the MLX model autocomplete uses, on the in-process runtime. There is no
/// rewrite-only model: the model is `suggestionSettings.mlxModelID`, and the runtime holds at most
/// one copy of it. When autocomplete is on MLX the rewrite runs on the already loaded model; when
/// it is not, `MLXRuntimeManager.withRewriteModel` loads the model for the rewrite and releases it
/// after a few idle minutes.
///
/// The prompt follows the model: an instruct or chat model (`MLXModelCompatibility.isInstructName`)
/// gets the instruct prompt through its chat template; a base model gets the base prompt with the
/// example, the rewrite stop sequences and a budget from the selection. Weaker on base models,
/// which the Settings pane says. The text never leaves the Mac, so `sendsOffDevice` is false and
/// memory is allowed as for the other local providers. Owned by `RewriteEngine`.
@MainActor
final class MLXRewriteProvider: RewriteProviding {
    /// Shown in the popup while the model loads; the first streamed token replaces it.
    static let loadingNote = "Loading MLX model…"

    private let runtime: MLXRuntimeManager
    private let modelID: @MainActor () -> String
    private let cachedModels: @MainActor () -> [MLXCachedModel]?
    private let rejectedModels: @MainActor () -> [MLXRepoID: MLXModelCompatibility.Reason]
    private let cacheLimitBytes: @MainActor () -> Int
    private let isAppleSilicon: Bool

    init(
        runtime: MLXRuntimeManager,
        modelID: @escaping @MainActor () -> String,
        cachedModels: @escaping @MainActor () -> [MLXCachedModel]?,
        rejectedModels: @escaping @MainActor () -> [MLXRepoID: MLXModelCompatibility.Reason],
        cacheLimitBytes: @escaping @MainActor () -> Int,
        isAppleSilicon: Bool = MLXHardware.isAppleSilicon
    ) {
        self.runtime = runtime
        self.modelID = modelID
        self.cachedModels = cachedModels
        self.rejectedModels = rejectedModels
        self.cacheLimitBytes = cacheLimitBytes
        self.isAppleSilicon = isAppleSilicon
    }

    nonisolated deinit {}

    /// The same decision autocomplete's runtime uses, so Rewrite and autocomplete always agree on
    /// which model MLX can run and why not.
    private var desire: MLXRuntimeDesire {
        MLXRuntimeDesireResolver.desire(
            engine: .mlx,
            isAppleSilicon: isAppleSilicon,
            modelID: modelID(),
            cachedModels: cachedModels(),
            cacheLimitBytes: cacheLimitBytes(),
            rejectedModels: rejectedModels()
        )
    }

    var isAvailable: Bool {
        if case .load = desire { return true }
        return false
    }

    var sendsOffDevice: Bool { false }

    var unavailableReason: String? {
        switch desire {
        case .load: return nil
        case .unavailable(let reason): return reason.message
        case .stopped: return "MLX is still looking for its models."
        }
    }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard case .load(let load) = desire else {
            throw RewriteError.unavailable(unavailableReason ?? "MLX is not available.")
        }
        if runtime.state.readyModelID != load.modelID {
            // Without this the popup would sit on "Rewriting…" for the whole load.
            onPartial(Self.loadingNote)
        }
        let instruct = Self.isInstruct(modelID: load.modelID)
        let prompt: MLXRuntimeCore.PromptInput
        var options = LlamaGenerationOptions(
            maxPredictionTokens: RewritePromptBuilder.tokenBudget(request),
            temperature: 0.3, topK: 40, topP: 0.9, minP: 0.05, repetitionPenalty: 1.05, seed: 42
        )
        // A rewrite can be several sentences; autocomplete's stop at the first sentence end would cut it.
        options.sentenceStopMinimumTokens = .max
        if instruct {
            let instructPrompt = RewritePromptBuilder.instructPrompt(request)
            prompt = .chat(system: instructPrompt.system, user: instructPrompt.user)
        } else {
            prompt = .text(RewritePromptBuilder.basePrompt(request))
            options.stopSequences = RewritePromptBuilder.baseStopSequences
        }
        let relay = PartialRelay(deliver: onPartial)
        // Stop delivery on every exit, so no partial can arrive after this function returned.
        defer { relay.finish() }
        let stops = options.stopSequences
        let text = try await runtime.withRewriteModel(load) {
            try await runtime.generate(prompt, options: options, onPartial: { text in
                relay.send(Self.cutAtStop(text, stops: stops))
            }).text
        }
        return Self.cutAtStop(text, stops: stops)
    }

    /// The text before the first stop sequence: the runtime stops once a sequence has appeared but
    /// keeps it in the text, and a base model's "\nDraft:" must not reach the user.
    nonisolated static func cutAtStop(_ text: String, stops: [String]) -> String {
        let cut = stops.compactMap { text.range(of: $0)?.lowerBound }.min()
        return cut.map { String(text[..<$0]) } ?? text
    }

    /// Whether the repo name ("gemma-4-e4b-it-4bit" in "org/gemma-4-e4b-it-4bit") marks an
    /// instruction-following model. Unknown names count as base: the base prompt works on both,
    /// the instruct prompt only on chat-tuned models.
    static func isInstruct(modelID: String) -> Bool {
        let name = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return MLXModelCompatibility.isInstructName(name)
    }
}
