import Foundation
@testable import Cotabby

/// Stands in for `MLXRuntimeCore` so `MLXRuntimeManager` and its users are tested without weights.
/// Records what it was asked to load and generate; `generationBlocksUntilAborted` holds a
/// generation until its operation is aborted, for cancellation tests.
final class FakeMLXRuntimeCore: MLXRuntimeCoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads: [URL] = []
    private var _cacheLimits: [Int] = []
    private var _unloads = 0
    private var _resets = 0
    private var _aborted: Set<UInt64> = []
    private var _started = false
    private var _prompts: [MLXRuntimeCore.PromptInput] = []
    private var _options: [LlamaGenerationOptions] = []
    private var next: UInt64 = 0
    private var _residency: [Bool] = []
    var loadError: Error?
    /// When set, `load` waits until `releaseLoad()` is called, to test what happens mid-load.
    var loadBlocks = false
    private var loadReleased = false
    var generationBlocksUntilAborted = false
    /// What a (non-warm-up) generation returns.
    var generatedText = "generated"

    var loads: [URL] { lock.withLock { _loads } }
    var cacheLimits: [Int] { lock.withLock { _cacheLimits } }
    var unloads: Int { lock.withLock { _unloads } }
    var promptCacheResets: Int { lock.withLock { _resets } }
    var abortedOperations: Set<UInt64> { lock.withLock { _aborted } }
    var generationStarted: Bool { lock.withLock { _started } }
    var prompts: [MLXRuntimeCore.PromptInput] { lock.withLock { _prompts } }
    var options: [LlamaGenerationOptions] { lock.withLock { _options } }
    /// Every `setResident` call, in order.
    var residencyChanges: [Bool] { lock.withLock { _residency } }

    func releaseLoad() { lock.withLock { loadReleased = true } }

    func load(directory: URL, cacheLimitBytes: Int) async throws {
        if let loadError { throw loadError }
        // Ignores cancellation, as a real load that is already reading weights may.
        while loadBlocks, !lock.withLock({ loadReleased }) { usleep(5_000) }
        lock.withLock { _loads.append(directory); _cacheLimits.append(cacheLimitBytes) }
    }
    func setResident(_ resident: Bool) async { lock.withLock { _residency.append(resident) } }
    func unload() { lock.withLock { _unloads += 1 } }
    func resetPromptCache() { lock.withLock { _resets += 1 } }
    func beginOperation() -> UInt64 { lock.withLock { next += 1; return next } }
    func abort(_ operation: UInt64) { _ = lock.withLock { _aborted.insert(operation) } }
    func prefill(_ prompt: MLXRuntimeCore.PromptInput, operation: UInt64) throws {}
    func generate(
        _ prompt: MLXRuntimeCore.PromptInput, options: LlamaGenerationOptions, operation: UInt64,
        onPartial: (@Sendable (String) -> Void)?
    ) throws -> LlamaGenerationOutput {
        if case .text(let text) = prompt, text == "Warm up." {
            return LlamaGenerationOutput(text: "", averageLogprob: nil, suppressedByLowConfidence: false)
        }
        lock.withLock { _started = true; _prompts.append(prompt); _options.append(options) }
        if generationBlocksUntilAborted {
            while !lock.withLock({ _aborted.contains(operation) }) { Thread.sleep(forTimeInterval: 0.005) }
            return LlamaGenerationOutput(text: "", averageLogprob: nil, suppressedByLowConfidence: false, stopReason: "cancelled")
        }
        onPartial?(generatedText)
        return LlamaGenerationOutput(text: generatedText, averageLogprob: nil, suppressedByLowConfidence: false)
    }
}
