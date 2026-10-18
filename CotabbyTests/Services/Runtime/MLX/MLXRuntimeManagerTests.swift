import XCTest
@testable import Cotabby

/// The manager's lifecycle and cancellation rules, driven with a fake core instead of real weights.
@MainActor
final class MLXRuntimeManagerTests: XCTestCase {
    private let load = MLXRuntimeLoad(modelID: "mlx-community/gemma-4-e4b-5bit", directory: URL(fileURLWithPath: "/models/e4b"), cacheLimitBytes: 1 << 30)

    func test_loadingAModelMakesTheRuntimeReady() async throws {
        let core = FakeMLXRuntimeCore()
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        XCTAssertEqual(manager.state, .loading(modelID: load.modelID))
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        XCTAssertEqual(core.loads, [load.directory])
        XCTAssertEqual(core.cacheLimits, [load.cacheLimitBytes])
    }

    func test_theSameDesireDoesNotReload() async throws {
        let core = FakeMLXRuntimeCore()
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        manager.apply(.stopped)
        manager.apply(.load(load))
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        XCTAssertEqual(core.loads.count, 2, "deselecting unloads; selecting again loads once")
        manager.apply(.load(load))
        XCTAssertEqual(core.loads.count, 2)
    }

    func test_aFailedLoadSaysWhy() async throws {
        let core = FakeMLXRuntimeCore()
        core.loadError = LlamaRuntimeError.generationFailed("bad weights")
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        try await waitUntil { manager.state.problem != nil }
        XCTAssertTrue(manager.state.problem?.contains("bad weights") == true)
    }

    func test_deselectingUnloadsAndAnUnavailableReasonIsShown() async throws {
        let core = FakeMLXRuntimeCore()
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        manager.apply(.unavailable(.unsupportedHardware))
        XCTAssertEqual(manager.state, .unavailable(.unsupportedHardware))
        XCTAssertEqual(core.unloads, 1)
    }

    func test_generatingBeforeTheModelIsReadyIsUnavailable() async {
        let manager = MLXRuntimeManager(core: FakeMLXRuntimeCore())
        do {
            _ = try await manager.generate(prompt: "Hi", cachedPrefixBytes: nil, options: Self.options)
            XCTFail("expected unavailable")
        } catch LlamaRuntimeError.unavailable {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_aCancelledGenerationAbortsItsOperationAndReportsCancelled() async throws {
        let core = FakeMLXRuntimeCore()
        core.generationBlocksUntilAborted = true
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        let task = Task { try await manager.generate(prompt: "Hi", cachedPrefixBytes: nil, options: Self.options) }
        try await waitUntil { core.generationStarted }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancelled")
        } catch LlamaRuntimeError.cancelled {
        }
        XCTAssertFalse(core.abortedOperations.isEmpty)
        XCTAssertEqual(core.promptCacheResets, 1, "only the warm-up resets the cache; a cancel keeps it")
    }

    func test_aRewriteLoadsTheModelAndReleasesItWhenIdle() async throws {
        let core = FakeMLXRuntimeCore()
        let idle = IdleGate()
        let manager = MLXRuntimeManager(core: core, sleep: { _ in try await idle.wait() })
        let text = try await manager.withRewriteModel(load) {
            try await manager.generate(.text("Draft:"), options: Self.options, onPartial: nil).text
        }
        XCTAssertEqual(text, "generated")
        XCTAssertEqual(manager.state, .ready(modelID: load.modelID))
        await idle.open()
        try await waitUntil { manager.state == .idle }
        XCTAssertEqual(core.unloads, 1)
    }

    func test_aRewriteOnAutocompletesModelDoesNotLoadItAgain() async throws {
        let core = FakeMLXRuntimeCore()
        let manager = MLXRuntimeManager(core: core, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        manager.apply(.load(load))
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        _ = try await manager.withRewriteModel(load) { "done" }
        XCTAssertEqual(core.loads.count, 1)
    }

    private static let options = LlamaGenerationOptions(maxPredictionTokens: 4, temperature: 0, topK: 1, topP: 1, minP: 0, repetitionPenalty: 1)

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met")
    }
    // MARK: - Memory pressure

    func test_memoryWarningReleasesTheReservationButKeepsTheModel() async throws {
        let core = FakeMLXRuntimeCore()
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        manager.handleMemoryPressure(.warning)
        try await waitUntil { core.residencyChanges == [false] }
        XCTAssertEqual(manager.state, .ready(modelID: load.modelID), "MLX keeps working while macOS may reclaim pages")
        XCTAssertEqual(core.unloads, 0)
        manager.handleMemoryPressure(.normal)
        try await waitUntil { core.residencyChanges == [false, true] }
    }

    func test_criticalPressureUnloadsAndReloadsWhenMemoryIsBack() async throws {
        let core = FakeMLXRuntimeCore()
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        manager.handleMemoryPressure(.critical)
        XCTAssertEqual(manager.state, .unavailable(.memoryPressure))
        XCTAssertEqual(core.unloads, 1)
        manager.handleMemoryPressure(.normal)
        try await waitUntil { manager.state == .ready(modelID: self.load.modelID) }
        XCTAssertEqual(core.loads.count, 2)
    }

    func test_aDesireChangeDuringCriticalPressureDoesNotLoad() async throws {
        let core = FakeMLXRuntimeCore()
        let manager = MLXRuntimeManager(core: core)
        manager.handleMemoryPressure(.critical)
        manager.apply(.load(load))
        XCTAssertEqual(manager.state, .unavailable(.memoryPressure))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(core.loads, [])
    }

    func test_aLoadInterruptedByCriticalPressureFreesItsWeights() async throws {
        let core = FakeMLXRuntimeCore()
        core.loadBlocks = true
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        manager.handleMemoryPressure(.critical)
        core.releaseLoad()
        try await waitUntil { core.loads.count == 1 && core.unloads == 2 }
        XCTAssertEqual(manager.state, .unavailable(.memoryPressure), "the finished load must not make MLX ready")
    }

    func test_deselectingWhileLoadingNeverBecomesReady() async throws {
        let core = FakeMLXRuntimeCore()
        core.loadBlocks = true
        let manager = MLXRuntimeManager(core: core)
        manager.apply(.load(load))
        manager.apply(.stopped)
        core.releaseLoad()
        try await waitUntil { core.loads.count == 1 && core.unloads >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.state, .idle)
    }
}

private actor IdleGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async throws {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }

}
