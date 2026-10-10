import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// File overview:
/// Rewrites on this Mac: Apple Intelligence when it is available (it follows instructions), otherwise
/// the selected local llama model with the base-model example prompt (weaker; the Settings pane
/// labels it "basic quality"). Shares the llama runtime with autocomplete like `AnswerDraftEngine`:
/// a rewrite waits for an in-flight suggestion and resets the prompt cache once. Owned by
/// `RewriteEngine`.
@MainActor
final class LocalRewriteProvider: RewriteProviding {
    private let runtimeManager: LlamaRuntimeManager
    private let hasLocalModel: @MainActor () -> Bool
    private let availability: FoundationModelAvailabilityService

    init(runtimeManager: LlamaRuntimeManager, hasLocalModel: @escaping @MainActor () -> Bool,
         availability: FoundationModelAvailabilityService) {
        self.runtimeManager = runtimeManager
        self.hasLocalModel = hasLocalModel
        self.availability = availability
    }

    nonisolated deinit {}

    var usesAppleIntelligence: Bool {
        if #available(macOS 26.0, *) {
            #if canImport(FoundationModels)
            return availability.isAvailable && availability.systemLanguageModel != nil
            #endif
        }
        return false
    }

    var isAvailable: Bool { usesAppleIntelligence || hasLocalModel() }
    var sendsOffDevice: Bool { false }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), usesAppleIntelligence, let model = availability.systemLanguageModel {
            let prompt = RewritePromptBuilder.instructPrompt(request)
            // A fresh session per rewrite: a transcript carried between rewrites would mix one
            // draft's facts into the next.
            let session = LanguageModelSession(model: model, instructions: prompt.system)
            let response = try await session.respond(
                to: prompt.user, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: Self.tokenBudget(request))
            )
            onPartial(response.content)
            return response.content
        }
        #endif
        guard hasLocalModel() else { throw RewriteError.noProvider }
        var options = LlamaGenerationOptions(
            maxPredictionTokens: Self.tokenBudget(request), temperature: 0.3, topK: 40, topP: 0.9, minP: 0.05,
            repetitionPenalty: 1.05, seed: 42
        )
        // A rewrite can be several sentences; autocomplete's stop at the first sentence end would cut it.
        options.sentenceStopMinimumTokens = .max
        options.stopSequences = RewritePromptBuilder.baseStopSequences
        let output = try await runtimeManager.generate(
            prompt: RewritePromptBuilder.basePrompt(request), options: options,
            onPartialRawText: { text in Task { @MainActor in onPartial(text) } }
        )
        return output.text
    }

    /// About 1.5× the selection's tokens (≈4 characters per token) plus a margin, capped.
    static func tokenBudget(_ request: RewriteRequest) -> Int {
        min(800, request.selection.count * 3 / 8 + 48)
    }
}
