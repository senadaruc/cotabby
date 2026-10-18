import Combine
import Foundation
import Logging

/// The work `MLXRuntimeManager` hands to the model runtime. `MLXRuntimeCore` is the production
/// conformer; tests drive the manager with a fake instead of loading weights.
nonisolated protocol MLXRuntimeCoreProtocol: AnyObject, Sendable {
    func load(directory: URL, cacheLimitBytes: Int) async throws
    func unload()
    func resetPromptCache()
    func beginOperation() -> UInt64
    func abort(_ operation: UInt64)
    func prefill(_ prompt: MLXRuntimeCore.PromptInput, operation: UInt64) throws
    func generate(
        _ prompt: MLXRuntimeCore.PromptInput,
        options: LlamaGenerationOptions,
        operation: UInt64,
        onPartial: (@Sendable (String) -> Void)?
    ) throws -> LlamaGenerationOutput
}

extension MLXRuntimeCore: MLXRuntimeCoreProtocol {}

/// File overview:
/// Owns the one MLX model Cotabby keeps in memory and publishes its state to the router, Settings
/// and the menu bar. It conforms to `LlamaRuntimeGenerating`, so autocomplete runs MLX through the
/// same `LlamaSuggestionEngine` as llama.cpp: streamed partials, focus-time prefill, and the rule
/// that a cancelled keystroke keeps the cache all come with it.
///
/// Two users can want the model. Autocomplete asks through `apply(_:)` whenever its inputs change;
/// Rewrite borrows it through `withRewriteModel` and, when autocomplete is not on MLX, the model
/// is loaded for the rewrite and released after `rewriteIdleSeconds` without one. Both use the
/// model the settings name, so there is never a second copy of the weights.
@MainActor
final class MLXRuntimeManager: ObservableObject, LlamaRuntimeGenerating {
    /// How long a model loaded only for Rewrite stays in memory after the last rewrite.
    static let rewriteIdleSeconds: TimeInterval = 300
    /// How long a rewrite waits for the model to load before giving up.
    static let rewriteReadyTimeoutSeconds: TimeInterval = 150

    @Published private(set) var state: MLXRuntimeState = .idle

    private let core: any MLXRuntimeCoreProtocol
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var autocompleteDesire: MLXRuntimeDesire = .stopped
    private var rewriteLoad: MLXRuntimeLoad?
    private var rewriteLeases = 0
    private var rewriteIdleTask: Task<Void, Never>?
    private var loaded: MLXRuntimeLoad?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0

    init(
        core: any MLXRuntimeCoreProtocol = MLXRuntimeCore(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.core = core
        self.sleep = sleep
    }

    nonisolated deinit {}

    // MARK: - What should be loaded

    /// Autocomplete's wish, re-evaluated by `CotabbyAppEnvironment` whenever an input changes.
    func apply(_ desire: MLXRuntimeDesire) {
        guard desire != autocompleteDesire else { return }
        autocompleteDesire = desire
        reconcile()
    }

    /// Loads the wanted model again after a failed load (Settings' Retry).
    func retry() {
        guard case .failed = state, let target else { return }
        startLoading(target)
    }

    /// Unloads the model now; used when the app quits.
    func shutdown() {
        loadTask?.cancel()
        rewriteIdleTask?.cancel()
        loaded = nil
        core.unload()
        state = .idle
    }

    /// Runs `body` with the model `load` names in memory, loading it first when needed. When
    /// autocomplete does not hold the same model, the model stays loaded for
    /// `rewriteIdleSeconds` after the last rewrite and is then released.
    func withRewriteModel<T>(_ load: MLXRuntimeLoad, _ body: () async throws -> T) async throws -> T {
        rewriteLeases += 1
        rewriteLoad = load
        rewriteIdleTask?.cancel()
        rewriteIdleTask = nil
        reconcile()
        defer {
            rewriteLeases -= 1
            if rewriteLeases == 0 { scheduleRewriteRelease() }
        }
        try await waitUntilReady(modelID: load.modelID, timeout: Self.rewriteReadyTimeoutSeconds)
        return try await body()
    }

    private func scheduleRewriteRelease() {
        rewriteIdleTask?.cancel()
        rewriteIdleTask = Task { [weak self, sleep] in
            do { try await sleep(Self.rewriteIdleSeconds) } catch { return }
            guard let self, self.rewriteLeases == 0 else { return }
            self.rewriteLoad = nil
            self.rewriteIdleTask = nil
            self.reconcile()
        }
    }

    /// Autocomplete's model wins; otherwise a rewrite's, while one is running or idling.
    private var target: MLXRuntimeLoad? {
        if case .load(let load) = autocompleteDesire { return load }
        return rewriteLoad
    }

    private func reconcile() {
        guard let target else {
            loadTask?.cancel()
            loadTask = nil
            if loaded != nil {
                loaded = nil
                core.unload()
                CotabbyLogger.runtime.info("MLX model unloaded")
            }
            if case .unavailable(let reason) = autocompleteDesire {
                state = .unavailable(reason)
            } else {
                state = .idle
            }
            return
        }
        if target == loaded, case .ready = state { return }
        if case .loading(let modelID) = state, modelID == target.modelID, loadTask != nil { return }
        startLoading(target)
    }

    private func startLoading(_ load: MLXRuntimeLoad) {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        loaded = nil
        state = .loading(modelID: load.modelID)
        let core = self.core
        CotabbyLogger.runtime.info("MLX model loading", metadata: ["model": .string(load.modelID)])
        let loadStart = Date()
        loadTask = Task { [weak self] in
            do {
                try await core.load(directory: load.directory, cacheLimitBytes: load.cacheLimitBytes)
                // Compile the GPU kernels now, so the first suggestion does not pay for it.
                try await Task.detached(priority: .utility) {
                    _ = try core.generate(.text("Warm up."), options: Self.warmUpOptions, operation: core.beginOperation(), onPartial: nil)
                }.value
                core.resetPromptCache()
                guard let self, generation == self.loadGeneration else { return }
                self.loaded = load
                self.loadTask = nil
                self.state = .ready(modelID: load.modelID)
                CotabbyLogger.runtime.info("MLX model loaded", metadata: [
                    "model": .string(load.modelID),
                    "load_ms": .stringConvertible(Int(Date().timeIntervalSince(loadStart) * 1000))
                ])
            } catch {
                guard let self, generation == self.loadGeneration, !Task.isCancelled else { return }
                self.loadTask = nil
                self.state = .failed(reason: "\(load.modelID) could not be loaded: \(error.localizedDescription)")
                CotabbyLogger.runtime.error("MLX model load failed: \(error.localizedDescription)")
            }
        }
    }

    private static let warmUpOptions = LlamaGenerationOptions(
        maxPredictionTokens: 2, temperature: 0, topK: 1, topP: 1, minP: 0, repetitionPenalty: 1
    )

    /// Waits until `modelID` is loaded, or throws the reason it will not be.
    private func waitUntilReady(modelID: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch state {
            case .ready(let loadedID) where loadedID == modelID:
                return
            case .failed(let reason):
                throw RewriteError.unavailable(reason)
            case .unavailable(let reason):
                throw RewriteError.unavailable(reason.message)
            default:
                break
            }
            guard Date() < deadline else { throw RewriteError.unavailable("MLX took too long to load \(modelID).") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - LlamaRuntimeGenerating

    func generate(prompt: String, cachedPrefixBytes: Int?, options: LlamaGenerationOptions) async throws -> LlamaGenerationOutput {
        try await generate(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options, onPartialRawText: nil)
    }

    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions,
        onPartialRawText: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput {
        try await run(.text(prompt), options: options, onPartial: onPartialRawText)
    }

    /// A rewrite or other non-autocomplete generation on the loaded model, with chat input when the
    /// model is instruction-tuned.
    func generate(
        _ prompt: MLXRuntimeCore.PromptInput,
        options: LlamaGenerationOptions,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput {
        try await run(prompt, options: options, onPartial: onPartial)
    }

    func resetPromptCache() {
        core.resetPromptCache()
    }

    func prefill(prompt: String, cachedPrefixBytes: Int?, options: LlamaGenerationOptions) async throws {
        guard case .ready = state else { throw LlamaRuntimeError.unavailable(state.notReadyMessage) }
        let core = self.core
        let operation = core.beginOperation()
        let task = Task.detached(priority: .utility) { try core.prefill(.text(prompt), operation: operation) }
        try await withTaskCancellationHandler {
            try await task.value
            if Task.isCancelled { throw LlamaRuntimeError.cancelled }
        } onCancel: {
            task.cancel()
            core.abort(operation)
        }
    }

    private func run(
        _ prompt: MLXRuntimeCore.PromptInput,
        options: LlamaGenerationOptions,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput {
        guard case .ready = state else { throw LlamaRuntimeError.unavailable(state.notReadyMessage) }
        let core = self.core
        let operation = core.beginOperation()
        let task = Task.detached(priority: .userInitiated) {
            try core.generate(prompt, options: options, operation: operation, onPartial: onPartial)
        }
        return try await withTaskCancellationHandler {
            let output = try await task.value
            if Task.isCancelled || output.stopReason == "cancelled" { throw LlamaRuntimeError.cancelled }
            return output
        } onCancel: {
            task.cancel()
            core.abort(operation)
        }
    }
}
