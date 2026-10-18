import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// File overview:
/// Runs an MLX model inside Cotabby, the in-process counterpart of `LlamaRuntimeCore`. Autocomplete
/// sends a request per keystroke and abandons most of them, so the per-request overhead decides
/// latency more than raw model speed. Running in process removes the HTTP round trip, the server's
/// own tokenization and cache lookup, and makes cancellation immediate. In the spike that preceded
/// this file (Gemma 4 E4B, 258 keystroke requests) it produced the first token in 25 ms and ten
/// tokens in 218 ms, against 29 ms and 266 ms for the llama engine and about twice that for the
/// Python `mlx_lm.server`.
///
/// The cache is one list of full-size KV caches. Gemma 4 builds rotating caches for its sliding
/// window layers, which cannot be trimmed once they wrap; plain caches keep every position and the
/// model's own attention mask still limits those layers to the window. Each request keeps the
/// prompt prefix it shares with the previous one (`MLXPromptCachePlan`) and decodes only the rest.
///
/// Thread model: one generation at a time, serialized by `workLock` and run on whatever thread the
/// caller provides (the manager uses detached tasks). Cancellation is per operation: `abort(_:)`
/// marks an operation id, and the prefill and decode loops check it between chunks and tokens.
nonisolated final class MLXRuntimeCore: @unchecked Sendable {
    /// What a generation reads its prompt from.
    enum PromptInput: Sendable {
        /// A base-model continuation prompt, tokenized with the model's special tokens (BOS).
        case text(String)
        /// Messages rendered through the model's chat template (instruct models).
        case chat(system: String, user: String)
    }

    /// Prompt tokens decoded per model call while prefilling, as mlx-lm does.
    static let prefillChunkTokens = 512

    private let workLock = NSLock()
    private let abortLock = NSLock()
    private var abortedOperations: Set<UInt64> = []
    private var nextOperation: UInt64 = 0

    private var context: ModelContext?
    private var eosTokenIDs: Set<Int> = []
    private var cache: [KVCache] = []
    private var cachedPrompt: [Int] = []

    // MARK: - Model lifecycle

    /// Loads the model in `directory` (a Hugging Face snapshot) and drops any previous one.
    func load(directory: URL, cacheLimitBytes: Int) async throws {
        Memory.cacheLimit = cacheLimitBytes
        let loaded = try await LLMModelFactory.shared.load(from: directory, using: TransformersTokenizerLoader())
        var eos = loaded.configuration.eosTokenIds
        for name in [loaded.tokenizer.eosToken, "<end_of_turn>", "<turn|>"].compactMap({ $0 }) {
            if let id = loaded.tokenizer.convertTokenToId(name) { eos.insert(id) }
        }
        workLock.withLock {
            context = loaded
            eosTokenIDs = eos
            resetCacheLocked()
        }
    }

    func unload() {
        workLock.withLock {
            context = nil
            cache = []
            cachedPrompt = []
        }
        Memory.clearCache()
    }

    func resetPromptCache() {
        workLock.withLock { resetCacheLocked() }
    }

    // MARK: - Cancellation

    func beginOperation() -> UInt64 {
        abortLock.withLock {
            nextOperation &+= 1
            return nextOperation
        }
    }

    /// Thread-safe and non-blocking: the running loop sees it at its next chunk or token.
    func abort(_ operation: UInt64) {
        _ = abortLock.withLock { abortedOperations.insert(operation) }
    }

    private func isAborted(_ operation: UInt64) -> Bool {
        abortLock.withLock { abortedOperations.contains(operation) }
    }

    private func finish(_ operation: UInt64) {
        _ = abortLock.withLock { abortedOperations.remove(operation) }
    }

    // MARK: - Work

    /// Decodes `prompt` into the cache without sampling, so a later request that extends it only
    /// decodes the new tokens (the focus-time warm-up).
    func prefill(_ prompt: PromptInput, operation: UInt64) throws {
        defer { finish(operation) }
        try workLock.withLock {
            guard let context else { throw LlamaRuntimeError.unavailable("The MLX model is not loaded.") }
            let tokens = try promptTokens(prompt, context: context)
            _ = try decodePromptLocked(tokens, model: context.model, operation: operation)
        }
    }

    /// Generates a continuation of `prompt` under `options`, reporting the cumulative text after
    /// each token through `onPartial`. Returns what was generated when the operation is aborted;
    /// the caller decides whether that is a cancellation.
    func generate(
        _ prompt: PromptInput,
        options: LlamaGenerationOptions,
        operation: UInt64,
        onPartial: (@Sendable (String) -> Void)?
    ) throws -> LlamaGenerationOutput {
        defer { finish(operation) }
        return try workLock.withLock {
            guard let context else { throw LlamaRuntimeError.unavailable("The MLX model is not loaded.") }
            let model = context.model
            let tokenizer = context.tokenizer
            let tokens = try promptTokens(prompt, context: context)
            guard let logits = try decodePromptLocked(tokens, model: model, operation: operation) else {
                return LlamaGenerationOutput(text: "", averageLogprob: nil, suppressedByLowConfidence: false, stopReason: "cancelled")
            }

            let parameters = GenerateParameters(
                temperature: Float(options.temperature),
                topP: Float(options.topP),
                topK: options.topK,
                minP: Float(options.minP),
                repetitionPenalty: options.repetitionPenalty > 1 ? Float(options.repetitionPenalty) : nil,
                repetitionContextSize: 64,
                seed: options.seed.map(UInt64.init)
            )
            let sampler = parameters.sampler()
            var processor = parameters.processor()
            processor?.prompt(MLXArray(tokens.map(Int32.init)))

            func sample(_ logits: MLXArray) -> (token: MLXArray, argmax: MLXArray) {
                var row = logits[0..., -1, 0...]
                let argmax = argMax(row, axis: -1)
                row = processor?.process(logits: row) ?? row
                let token = sampler.sample(logits: row)
                processor?.didSample(token: token)
                return (token, argmax)
            }

            let decodeStart = DispatchTime.now().uptimeNanoseconds
            var next = sample(logits)
            asyncEval([next.token, next.argmax])
            var generated: [Int] = []
            var text = ""
            var stopReason = "budget_exhausted"

            while generated.count < options.maxPredictionTokens {
                if isAborted(operation) || Task.isCancelled { stopReason = "cancelled"; break }
                let current = next
                // Queue the following token before reading this one, so the GPU computes it while
                // this thread detokenizes and checks the stop rules (as mlx-lm's loop does).
                let stepLogits = model(current.token.reshaped(1, 1), cache: cache)
                next = sample(stepLogits)
                asyncEval([next.token, next.argmax] + cache.flatMap(\.state))

                let token = current.token.item(Int.self)
                if eosTokenIDs.contains(token) { stopReason = "eos"; break }
                if options.stopAtArgmaxEOG, !generated.isEmpty, eosTokenIDs.contains(current.argmax.item(Int.self)) {
                    stopReason = "argmax_eog"
                    break
                }
                generated.append(token)
                let decoded = tokenizer.decode(tokenIds: generated, skipSpecialTokens: true)
                // A character split across byte tokens decodes as U+FFFD until its last byte arrives.
                if decoded.hasSuffix("\u{FFFD}") { continue }
                text = decoded

                if options.singleLine, let newline = text.firstIndex(where: \.isNewline) {
                    text = String(text[..<newline])
                    stopReason = "newline"
                    break
                }
                onPartial?(text)
                if let verdict = DecodeStopPolicy.verdict(
                    accumulated: text,
                    tokensGenerated: generated.count,
                    minimumTokens: options.sentenceStopMinimumTokens,
                    minimumWords: options.sentenceStopMinimumWords
                ) {
                    stopReason = verdict.rawValue
                    break
                }
                if !options.stopSequences.isEmpty, options.stopSequences.contains(where: { text.contains($0) }) {
                    stopReason = "stop_sequence"
                    break
                }
            }

            var output = LlamaGenerationOutput(text: text, averageLogprob: nil, suppressedByLowConfidence: false)
            output.tokensGenerated = generated.count
            output.decodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000
            output.stopReason = stopReason
            return output
        }
    }

    // MARK: - Private

    private func promptTokens(_ prompt: PromptInput, context: ModelContext) throws -> [Int] {
        switch prompt {
        case .text(let text):
            return context.tokenizer.encode(text: text, addSpecialTokens: true)
        case .chat(let system, let user):
            return try context.tokenizer.applyChatTemplate(messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ])
        }
    }

    /// Brings the cache to `tokens`, decoding only what it does not share with the cached prompt,
    /// and returns the logits of the last token. Nil when the operation was aborted; the cache is
    /// then emptied, since a half-decoded prompt matches no known token list.
    private func decodePromptLocked(_ tokens: [Int], model: any LanguageModel, operation: UInt64) throws -> MLXArray? {
        guard !tokens.isEmpty else { throw LlamaRuntimeError.generationFailed("The prompt is empty.") }
        let plan = MLXPromptCachePlan.decision(
            cachedPrompt: cachedPrompt,
            cacheLength: cache.first?.offset ?? 0,
            newPrompt: tokens,
            canTrim: !cache.isEmpty && cache.allSatisfy(\.isTrimmable)
        )
        if plan.rebuild {
            resetCacheLocked()
        } else if plan.trimCount > 0 {
            for layer in cache { _ = layer.trim(plan.trimCount) }
        }
        // Until the new prompt is fully decoded the cache matches no prompt we could name.
        cachedPrompt = []

        var offset = plan.reusedTokens
        var logits: MLXArray?
        while offset < tokens.count {
            if isAborted(operation) || Task.isCancelled {
                resetCacheLocked()
                return nil
            }
            let end = min(tokens.count, offset + Self.prefillChunkTokens)
            let chunk = MLXArray(tokens[offset ..< end].map(Int32.init)).reshaped(1, end - offset)
            let chunkLogits = model(chunk, cache: cache)
            // MLX's `eval` computes these lazily built arrays on the GPU now; it runs no code.
            eval([chunkLogits] + cache.flatMap(\.state))
            logits = chunkLogits
            offset = end
        }
        cachedPrompt = tokens
        return logits
    }

    /// Full-size caches for every layer the model caches, so any prefix can be trimmed back to.
    private func resetCacheLocked() {
        cachedPrompt = []
        guard let model = context?.model, let fresh = try? model.newCache(parameters: nil) else {
            cache = []
            return
        }
        cache = fresh.map { $0 is RotatingKVCache ? KVCacheSimple() : $0 }
    }
}

/// Loads a model folder's tokenizer with swift-transformers, the integration mlx-swift-lm documents.
private struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
