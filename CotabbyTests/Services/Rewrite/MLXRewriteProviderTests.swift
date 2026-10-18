import XCTest
@testable import Cotabby

/// The MLX rewrite provider borrows the in-process runtime's model: it explains why it cannot run,
/// shapes the prompt for base and instruct models, and never loads a second copy of autocomplete's
/// model. A fake core stands in for the weights.
@MainActor
final class MLXRewriteProviderTests: XCTestCase {
    private let baseModel = "mlx-community/gemma-4-e4b-5bit"
    private let instructModel = "mlx-community/gemma-4-e4b-it-4bit"
    private let directory = URL(fileURLWithPath: "/hub/snapshots/abc")

    private func cached(_ id: String) -> [MLXCachedModel] {
        [MLXCachedModel(repoID: MLXRepoID(id)!, snapshotURL: directory, sizeBytes: 1, modelType: "gemma4", isInstruct: id.contains("-it-"))]
    }

    private func makeProvider(
        model: String, cachedModels: [MLXCachedModel]?, appleSilicon: Bool = true, core: FakeMLXRuntimeCore = FakeMLXRuntimeCore()
    ) -> (MLXRewriteProvider, MLXRuntimeManager, FakeMLXRuntimeCore) {
        let runtime = MLXRuntimeManager(core: core, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let provider = MLXRewriteProvider(
            runtime: runtime, modelID: { model }, cachedModels: { cachedModels }, rejectedModels: { [:] },
            cacheLimitBytes: { 1 << 30 }, isAppleSilicon: appleSilicon)
        return (provider, runtime, core)
    }

    private func request(_ selection: String = "can u send it") -> RewriteRequest {
        RewriteRequest(selection: selection, action: .rewrite, memory: .empty)
    }

    func test_aModelThatIsNotDownloadedIsExplainedAndNothingLoads() async {
        let (provider, _, core) = makeProvider(model: baseModel, cachedModels: [])
        XCTAssertFalse(provider.isAvailable)
        XCTAssertEqual(provider.unavailableReason, "Download \(baseModel) in Settings → Engine & Model.")
        do {
            _ = try await provider.rewrite(request(), onPartial: { _ in })
            XCTFail("expected unavailable")
        } catch RewriteError.unavailable {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(core.loads.isEmpty)
    }

    func test_intelIsUnavailable() {
        let (provider, _, _) = makeProvider(model: baseModel, cachedModels: cached(baseModel), appleSilicon: false)
        XCTAssertEqual(provider.unavailableReason, "MLX needs a Mac with Apple Silicon.")
    }

    func test_aBaseModelGetsTheBasePromptAndItsStopTextIsCut() async throws {
        let core = FakeMLXRuntimeCore()
        core.generatedText = "Can you send it?\nDraft: next"
        let (provider, _, _) = makeProvider(model: baseModel, cachedModels: cached(baseModel), core: core)
        var partials: [String] = []
        let text = try await provider.rewrite(request(), onPartial: { partials.append($0) })
        XCTAssertEqual(text, "Can you send it?")
        XCTAssertEqual(partials.first, MLXRewriteProvider.loadingNote, "the model had to load first")
        XCTAssertEqual(core.loads, [directory])
        guard case .text(let prompt) = core.prompts.first else { return XCTFail("expected a base prompt") }
        XCTAssertTrue(prompt.hasSuffix("Rewritten:"))
        XCTAssertEqual(core.options.first?.stopSequences, RewritePromptBuilder.baseStopSequences)
    }

    func test_anInstructModelGetsItsChatTemplate() async throws {
        let (provider, _, core) = makeProvider(model: instructModel, cachedModels: cached(instructModel))
        _ = try await provider.rewrite(request(), onPartial: { _ in })
        guard case .chat(let system, let user) = core.prompts.first else { return XCTFail("expected chat input") }
        XCTAssertFalse(system.isEmpty)
        XCTAssertTrue(user.contains("can u send it"))
    }

    func test_autocompletesLoadedModelIsReusedWithoutALoadingNote() async throws {
        let (provider, runtime, core) = makeProvider(model: baseModel, cachedModels: cached(baseModel))
        runtime.apply(.load(MLXRuntimeLoad(modelID: baseModel, directory: directory, cacheLimitBytes: 1 << 30)))
        for _ in 0..<300 where runtime.state != .ready(modelID: baseModel) { try await Task.sleep(for: .milliseconds(10)) }
        var partials: [String] = []
        _ = try await provider.rewrite(request(), onPartial: { partials.append($0) })
        XCTAssertFalse(partials.contains(MLXRewriteProvider.loadingNote))
        XCTAssertEqual(core.loads.count, 1)
    }
}
