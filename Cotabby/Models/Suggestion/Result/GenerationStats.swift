import Foundation

/// How one generation went: how many tokens it produced, how long prompt processing took, why it
/// stopped, and which model answered.
///
/// Why its own value: these facts are known in different places (the llama runtime counts tokens
/// and times the decode; the router knows which engine and model ran) but are read together by the
/// performance tuner, which learns each model's speed, and by the Recent Requests list. Riding on
/// `SuggestionResult` lets them reach both without new plumbing through every engine.
struct GenerationStats: Equatable, Sendable {
    var tokensGenerated: Int
    /// True when `tokensGenerated` is estimated from the text (engines that do not report tokens).
    var isTokenCountEstimated: Bool
    /// Time before the first output token, or nil when the engine cannot separate it.
    var prefillMilliseconds: Double?
    var stopReason: String?
    /// `engine|model`, the key the performance tuner learns under; set by the router.
    var modelKey: String?

    /// Average characters per token for the estimate: close for English BPE vocabularies, and only
    /// used for engines whose own counts are unavailable, so the timing is marked coarse anyway.
    static let estimatedCharactersPerToken = 4

    static func estimated(fromText text: String) -> GenerationStats {
        GenerationStats(
            tokensGenerated: max(1, (text.count + estimatedCharactersPerToken - 1) / estimatedCharactersPerToken),
            isTokenCountEstimated: true
        )
    }

    init(
        tokensGenerated: Int,
        isTokenCountEstimated: Bool,
        prefillMilliseconds: Double? = nil,
        stopReason: String? = nil,
        modelKey: String? = nil
    ) {
        self.tokensGenerated = tokensGenerated
        self.isTokenCountEstimated = isTokenCountEstimated
        self.prefillMilliseconds = prefillMilliseconds
        self.stopReason = stopReason
        self.modelKey = modelKey
    }

    /// The key a profile is stored under: the engine and the model, since one GGUF served by the
    /// in-process runtime and the same file behind an HTTP server run at very different speeds.
    static func modelKey(engine: SuggestionEngineKind, modelName: String) -> String {
        "\(engine.rawValue)|\(modelName)"
    }
}
