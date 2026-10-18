import Foundation
import Logging
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
    /// Additive logit masks (0 or -infinity per token), built once per model from its vocabulary:
    /// tokens that contain a line break, and tokens that start with whitespace.
    private var newlineMask: MLXArray?
    private var leadingWhitespaceMask: MLXArray?
    /// Each token's decoded bytes by id, read once from the tokenizer at load, and the healing
    /// lookup built from them.
    private var vocabularyPieces: [[UInt8]] = []
    private var healingVocabulary: MLXHealingVocabulary?
    /// Keeps the loaded weights resident on the GPU between requests. Without it, the first
    /// request after about a second of idle paid 100-150 ms extra (16 of 63 one-token steps in a
    /// live TextEdit run, every one of them after more than 1.1 s idle), the cost of bringing the
    /// weights back. llama.cpp's Metal backend keeps its weights resident the same way.
    private var wiredTicket: WiredMemoryTicket?
    /// The loaded weights' size, for a new ticket after `setResident(false)`.
    private var weightsBytes = 0
    /// Pings MLX's queue while suggestions are recent, for pauses longer than wiring alone covers.
    private let keepAlive = MLXResidencyKeepAlive.standard
    private var keepAliveTimer: DispatchSourceTimer?
    /// When the last prompt was decoded and the last ping sent, in seconds of system uptime.
    private var lastWorkTime: TimeInterval?
    private var lastPingTime: TimeInterval?

    // MARK: - Model lifecycle

    /// Whether mlx-swift-lm can build a model of this `config.json` `model_type`, the check the
    /// model list uses so it offers only models `load` can run.
    static func supportsModelType(_ modelType: String) async -> Bool {
        await LLMTypeRegistry.shared.contains(modelType)
    }

    /// Loads the model in `directory` (a Hugging Face snapshot) and drops any previous one.
    func load(directory: URL, cacheLimitBytes: Int) async throws {
        Memory.cacheLimit = cacheLimitBytes
        let loaded = try await LLMModelFactory.shared.load(from: directory, using: TransformersTokenizerLoader())
        var eos = loaded.configuration.eosTokenIds
        for name in [loaded.tokenizer.eosToken, "<end_of_turn>", "<turn|>"].compactMap({ $0 }) {
            if let id = loaded.tokenizer.convertTokenToId(name) { eos.insert(id) }
        }
        var pieces: [[UInt8]] = []
        while pieces.count < 4_000_000, let token = loaded.tokenizer.convertIdToToken(pieces.count) {
            pieces.append(MLXHealingVocabulary.pieceBytes(token))
        }
        let healing = MLXHealingVocabulary(pieces: pieces)
        let bytes = Self.weightsBytes(in: directory)
        let ticket = MLXLMCommon.WiredSumPolicy().ticket(size: bytes, kind: .active)
        _ = await ticket.start()
        let previousTicket = workLock.withLock { () -> WiredMemoryTicket? in
            defer { wiredTicket = ticket; weightsBytes = bytes }
            return wiredTicket
        }
        if let previousTicket { _ = await previousTicket.end() }
        workLock.withLock {
            context = loaded
            eosTokenIDs = eos
            vocabularyPieces = pieces
            healingVocabulary = healing
            newlineMask = nil
            leadingWhitespaceMask = nil
            resetCacheLocked()
        }
        startKeepAlive()
    }

    func unload() {
        let ticket = workLock.withLock { () -> WiredMemoryTicket? in
            defer { wiredTicket = nil }
            return wiredTicket
        }
        if let ticket { Task { _ = await ticket.end() } }
        workLock.withLock {
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            lastWorkTime = nil
            lastPingTime = nil
            context = nil
            cache = []
            cachedPrompt = []
            vocabularyPieces = []
            healingVocabulary = nil
            newlineMask = nil
            leadingWhitespaceMask = nil
        }
        Memory.clearCache()
    }

    func resetPromptCache() {
        workLock.withLock { resetCacheLocked() }
    }

    /// Takes the loaded weights out of wired memory (false) so macOS may compress or page them out
    /// under memory pressure, as it can a memory-mapped llama.cpp model, or wires them again (true).
    /// Generation keeps working either way; unwired, the first request after a pause can be slower.
    func setResident(_ resident: Bool) async {
        if resident {
            let bytes = workLock.withLock { context != nil && wiredTicket == nil ? weightsBytes : 0 }
            guard bytes > 0 else { return }
            let ticket = MLXLMCommon.WiredSumPolicy().ticket(size: bytes, kind: .active)
            _ = await ticket.start()
            let stale = workLock.withLock { () -> WiredMemoryTicket? in
                // Unloaded or wired by a load while the ticket started: this one is not needed.
                guard context != nil, wiredTicket == nil else { return ticket }
                wiredTicket = ticket
                return nil
            }
            if let stale { _ = await stale.end() }
        } else {
            let ticket = workLock.withLock { () -> WiredMemoryTicket? in
                defer { wiredTicket = nil }
                return wiredTicket
            }
            if let ticket { _ = await ticket.end() }
        }
    }

    // MARK: - Residency keep-alive

    /// Checks twice a second whether a ping is due, so pings land 1 to 1.5 s after the last job.
    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.pingIfDue() }
        let previous = workLock.withLock { () -> DispatchSourceTimer? in
            defer { keepAliveTimer = timer }
            return keepAliveTimer
        }
        previous?.cancel()
        timer.resume()
    }

    /// Sends MLX a tiny GPU job when one is due. Skipped while a generation holds the lock: that
    /// generation keeps the weights resident itself.
    private func pingIfDue() {
        guard workLock.try() else { return }
        defer { workLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard context != nil, keepAlive.shouldPing(now: now, lastWork: lastWorkTime, lastPing: lastPingTime) else { return }
        MLX.eval(MLXArray(Int32(1)) + 1)
        lastPingTime = now
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
            defer { lastWorkTime = ProcessInfo.processInfo.systemUptime }
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
            defer { lastWorkTime = ProcessInfo.processInfo.systemUptime }
            let (tokens, replay) = try healedPrompt(prompt, options: options, context: context)
            guard let logits = try decodePromptLocked(tokens, model: context.model, operation: operation) else {
                return LlamaGenerationOutput(text: "", averageLogprob: nil, suppressedByLowConfidence: false, stopReason: "cancelled")
            }
            buildMasksIfNeeded(vocabularySize: logits.dim(-1))
            let sampler = MLXTokenSampler(
                options: options, promptTokens: tokens, newlineMask: newlineMask, leadingWhitespaceMask: leadingWhitespaceMask
            )
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            var decoding = Decoding(buffer: TokenHealingBuffer(replayedPrefix: replay), remainingReplay: replay, logits: logits)
            let step = Step(
                model: context.model, tokenizer: context.tokenizer, options: options, operation: operation, onPartial: onPartial
            )
            replayHealedPrefix(&decoding, sampler: sampler, step: step)
            if decoding.stopReason == nil { decodeFreely(&decoding, sampler: sampler, step: step) }

            var output = LlamaGenerationOutput(text: decoding.text, averageLogprob: nil, suppressedByLowConfidence: false)
            output.tokensGenerated = decoding.tokensGenerated
            output.decodeMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000
            output.stopReason = decoding.stopReason ?? "budget_exhausted"
            CotabbyLogger.runtime.debug(
                "MLX decode end",
                metadata: [
                    "tokens_generated": .stringConvertible(decoding.tokensGenerated),
                    "replayed_bytes": .stringConvertible(replay.count),
                    "decode_ms": .stringConvertible(Int(output.decodeMilliseconds ?? 0)),
                    "stop_reason": .string(output.stopReason ?? "")
                ]
            )
            return output
        }
    }

    /// One generation's progress, shared by its replay and free-decoding phases.
    private struct Decoding {
        var buffer: TokenHealingBuffer
        var remainingReplay: [UInt8]
        /// Logits of the last decoded position: what the next token is sampled from.
        var logits: MLXArray
        var tokensGenerated = 0
        var text = ""
        /// Set once the generation is over; nil means "budget exhausted" at the end.
        var stopReason: String?
    }

    /// What every decoding step of one request needs.
    private struct Step {
        let model: any LanguageModel
        let tokenizer: any MLXLMCommon.Tokenizer
        let options: LlamaGenerationOptions
        let operation: UInt64
        let onPartial: (@Sendable (String) -> Void)?
    }

    /// The prompt's tokens after token healing, as the llama engine applies it, and the bytes the
    /// generation must replay first. When the caret ends a word, the word's last tokens leave the
    /// prompt, so the model can choose the whole-word token instead of continuing a fragment
    /// ("net|wo"). A caret inside a word keeps the prompt as is; the whitespace mask covers it.
    private func healedPrompt(
        _ prompt: PromptInput, options: LlamaGenerationOptions, context: ModelContext
    ) throws -> (tokens: [Int], replay: [UInt8]) {
        let allTokens = try promptTokens(prompt, context: context)
        guard case .text(let text) = prompt, !options.forceWordContinuation, !vocabularyPieces.isEmpty else {
            return (allTokens, [])
        }
        let pieces = vocabularyPieces
        let healing = TokenHealingPlan(
            prompt: text, tokens: allTokens.map(Int32.init), singleLine: options.singleLine,
            piece: { pieces.indices.contains(Int($0)) ? pieces[Int($0)] : [] }
        )
        return (healing.promptTokens.map(Int.init), healing.replayBytes)
    }

    /// Replays the healed bytes one token at a time, because each step's allowed tokens depend on
    /// the bytes the previous token consumed. Usually one or two steps.
    private func replayHealedPrefix(_ decoding: inout Decoding, sampler: MLXTokenSampler, step: Step) {
        while !decoding.remainingReplay.isEmpty {
            if isAborted(step.operation) || Task.isCancelled { decoding.stopReason = "cancelled"; return }
            let candidates = healingVocabulary?.matchingTokens(prefix: decoding.remainingReplay, singleLine: step.options.singleLine) ?? []
            guard !candidates.isEmpty else { decoding.stopReason = "healing_prefix_mismatch"; return }
            let sampled = sampler.sample(decoding.logits, allowed: allowedMask(candidates, vocabularySize: decoding.logits.dim(-1)))
            let token = sampled.token.item(Int.self)
            if eosTokenIDs.contains(token) { decoding.stopReason = "eos"; return }
            let piece = pieceBytes(token, tokenizer: step.tokenizer)
            let partial = decoding.buffer.append(tokenBytes: piece)
            if decoding.buffer.hasReplayMismatch {
                decoding.text = ""
                decoding.stopReason = "healing_prefix_mismatch"
                return
            }
            decoding.remainingReplay = Array(decoding.remainingReplay.dropFirst(min(piece.count, decoding.remainingReplay.count)))
            decoding.logits = step.model(sampled.token.reshaped(1, 1), cache: cache)
            // A covering token can finish the replay and begin the new text in one piece.
            if decoding.buffer.hasVisibleBytes { decoding.tokensGenerated += 1 }
            if let partial {
                decoding.text = partial
                step.onPartial?(partial)
            }
        }
    }

    /// Samples freely until a stop rule or the token budget ends the generation. The following
    /// token is queued before the current one is read, so the GPU computes it while this thread
    /// checks the stop rules (as mlx-lm's loop does).
    private func decodeFreely(_ decoding: inout Decoding, sampler: MLXTokenSampler, step: Step) {
        var next = sampler.sample(decoding.logits)
        asyncEval([next.token, next.argmax])
        while decoding.tokensGenerated < step.options.maxPredictionTokens {
            if isAborted(step.operation) || Task.isCancelled { decoding.stopReason = "cancelled"; return }
            let current = next
            next = sampler.sample(step.model(current.token.reshaped(1, 1), cache: cache))
            asyncEval([next.token, next.argmax] + cache.flatMap(\.state))

            let token = current.token.item(Int.self)
            if eosTokenIDs.contains(token) { decoding.stopReason = "eos"; return }
            if step.options.stopAtArgmaxEOG, decoding.tokensGenerated > 0, eosTokenIDs.contains(current.argmax.item(Int.self)) {
                decoding.stopReason = "argmax_eog"
                return
            }
            decoding.tokensGenerated += 1
            // Nil while a character is split across byte tokens; the next piece completes it.
            guard let partial = decoding.buffer.append(tokenBytes: pieceBytes(token, tokenizer: step.tokenizer)) else { continue }
            decoding.text = partial
            if step.options.singleLine, let newline = partial.firstIndex(where: \.isNewline) {
                decoding.text = String(partial[..<newline])
                decoding.stopReason = "newline"
                return
            }
            step.onPartial?(partial)
            if let reason = Self.stopRule(text: partial, tokensGenerated: decoding.tokensGenerated, options: step.options) {
                decoding.stopReason = reason
                return
            }
        }
    }

    /// The llama engine's text stop rules: a natural sentence end or a chat marker
    /// (`DecodeStopPolicy`), and the request's stop sequences.
    private static func stopRule(text: String, tokensGenerated: Int, options: LlamaGenerationOptions) -> String? {
        if let verdict = DecodeStopPolicy.verdict(
            accumulated: text,
            tokensGenerated: tokensGenerated,
            minimumTokens: options.sentenceStopMinimumTokens,
            minimumWords: options.sentenceStopMinimumWords
        ) {
            return verdict.rawValue
        }
        if !options.stopSequences.isEmpty, options.stopSequences.contains(where: { text.contains($0) }) {
            return "stop_sequence"
        }
        return nil
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
        let prefillStart = DispatchTime.now().uptimeNanoseconds

        var offset = plan.reusedTokens
        var logits: MLXArray?
        // Waits for GPU work queued before this request (the previous generation's last step) so
        // the timings below measure this prompt alone.
        let queuedStart = DispatchTime.now().uptimeNanoseconds
        if let first = cache.first { eval(first.state) }
        let queuedMs = Double(DispatchTime.now().uptimeNanoseconds - queuedStart) / 1_000_000
        var graphMs = 0.0
        while offset < tokens.count {
            if isAborted(operation) || Task.isCancelled {
                resetCacheLocked()
                return nil
            }
            let end = min(tokens.count, offset + Self.prefillChunkTokens)
            let chunk = MLXArray(tokens[offset ..< end].map(Int32.init)).reshaped(1, end - offset)
            let graphStart = DispatchTime.now().uptimeNanoseconds
            let chunkLogits = model(chunk, cache: cache)
            graphMs += Double(DispatchTime.now().uptimeNanoseconds - graphStart) / 1_000_000
            // MLX's `eval` computes these lazily built arrays on the GPU now; it runs no code.
            eval([chunkLogits] + cache.flatMap(\.state))
            logits = chunkLogits
            offset = end
        }
        cachedPrompt = tokens
        CotabbyLogger.runtime.debug(
            "MLX prompt decoded",
            metadata: [
                "prompt_tokens": .stringConvertible(tokens.count),
                "reused_tokens": .stringConvertible(plan.reusedTokens),
                "decoded_tokens": .stringConvertible(tokens.count - plan.reusedTokens),
                "prefill_ms": .stringConvertible(Int(Double(DispatchTime.now().uptimeNanoseconds - prefillStart) / 1_000_000)),
                "queued_ms": .stringConvertible(Int(queuedMs)),
                "graph_ms": .stringConvertible(Int(graphMs))
            ]
        )
        return logits
    }

    /// The size of the model's weight files, which the wired-memory ticket keeps resident. A Hugging
    /// Face snapshot holds links into `blobs/`, so each file is sized at its target: sizing the links
    /// wired a few bytes, and the weights then fell out of GPU residency after about a second idle.
    static func weightsBytes(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "safetensors" }.reduce(0) { total, file in
            total + ((try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Builds the additive masks `generate` applies from the vocabulary bytes, once per model.
    /// Sized to the logits, which can be padded past the tokenizer's vocabulary.
    private func buildMasksIfNeeded(vocabularySize: Int) {
        guard newlineMask == nil else { return }
        var newline = [Float](repeating: 0, count: vocabularySize)
        var leadingWhitespace = [Float](repeating: 0, count: vocabularySize)
        for (id, piece) in vocabularyPieces.enumerated() where id < vocabularySize {
            if piece.contains(where: { $0 == 10 || $0 == 13 }) { newline[id] = -.infinity }
            if let first = piece.first, first == 32 || first == 9 || first == 10 || first == 13 {
                leadingWhitespace[id] = -.infinity
            }
        }
        newlineMask = MLXArray(newline)
        leadingWhitespaceMask = MLXArray(leadingWhitespace)
    }

    /// 0 for the allowed tokens, -infinity for every other one.
    private func allowedMask(_ allowed: [Int], vocabularySize: Int) -> MLXArray {
        var mask = [Float](repeating: -.infinity, count: vocabularySize)
        for token in allowed where token < vocabularySize { mask[token] = 0 }
        return MLXArray(mask)
    }

    private func pieceBytes(_ token: Int, tokenizer: any MLXLMCommon.Tokenizer) -> [UInt8] {
        if vocabularyPieces.indices.contains(token) { return vocabularyPieces[token] }
        return Array(tokenizer.decode(tokenIds: [token], skipSpecialTokens: true).utf8)
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

/// Samples one token from the last position of a logits array under one request's options:
/// llama's masks first, then mlx-swift-lm's repetition penalty and sampler. Also returns the raw
/// distribution's most likely token, for the "the model wants to stop" rule.
private final class MLXTokenSampler {
    private let options: LlamaGenerationOptions
    private let sampler: any LogitSampler
    private var processor: (any LogitProcessor)?
    private let newlineMask: MLXArray?
    private let leadingWhitespaceMask: MLXArray?
    private var isFirstToken = true

    init(options: LlamaGenerationOptions, promptTokens: [Int], newlineMask: MLXArray?, leadingWhitespaceMask: MLXArray?) {
        let parameters = GenerateParameters(
            temperature: Float(options.temperature),
            topP: Float(options.topP),
            topK: options.topK,
            minP: Float(options.minP),
            repetitionPenalty: options.repetitionPenalty > 1 ? Float(options.repetitionPenalty) : nil,
            repetitionContextSize: 64,
            seed: options.seed.map(UInt64.init)
        )
        self.options = options
        sampler = parameters.sampler()
        processor = parameters.processor()
        processor?.prompt(MLXArray(promptTokens.map(Int32.init)))
        self.newlineMask = newlineMask
        self.leadingWhitespaceMask = leadingWhitespaceMask
    }

    func sample(_ logits: MLXArray, allowed: MLXArray? = nil) -> (token: MLXArray, argmax: MLXArray) {
        var row = logits[0..., -1, 0...]
        let argmax = argMax(row, axis: -1)
        if let allowed { row += allowed }
        // As the llama engine does: a single-line field never gets a line break, so the model
        // writes words instead of ending at once; a caret inside a word gets a first token that
        // continues it.
        if options.singleLine, let newlineMask { row += newlineMask }
        if isFirstToken, options.forceWordContinuation, let leadingWhitespaceMask { row += leadingWhitespaceMask }
        isFirstToken = false
        row = processor?.process(logits: row) ?? row
        let token = sampler.sample(logits: row)
        processor?.didSample(token: token)
        return (token, argmax)
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
