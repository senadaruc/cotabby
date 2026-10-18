import XCTest
@testable import Cotabby

final class MLXRuntimeDesireResolverTests: XCTestCase {
    private let model = MLXCachedModel(
        repoID: MLXRepoID("mlx-community/gemma-4-e4b-5bit")!, snapshotURL: URL(fileURLWithPath: "/hub/snapshots/abc"),
        sizeBytes: 1, modelType: "gemma4", isInstruct: false
    )

    private func desire(
        engine: SuggestionEngineKind = .mlx,
        appleSilicon: Bool = true,
        modelID: String = "mlx-community/gemma-4-e4b-5bit",
        cached: [MLXCachedModel]?? = .none,
        rejected: [MLXRepoID: MLXModelCompatibility.Reason] = [:]
    ) -> MLXRuntimeDesire {
        MLXRuntimeDesireResolver.desire(
            engine: engine, isAppleSilicon: appleSilicon, modelID: modelID,
            cachedModels: cached ?? [model], cacheLimitBytes: 1 << 30, rejectedModels: rejected
        )
    }

    func test_aDownloadedModelIsLoadedFromItsSnapshotWithNothingToInstall() {
        XCTAssertEqual(desire(), .load(MLXRuntimeLoad(
            modelID: "mlx-community/gemma-4-e4b-5bit", directory: URL(fileURLWithPath: "/hub/snapshots/abc"), cacheLimitBytes: 1 << 30)))
    }

    func test_anotherEngineStopsTheRuntime() {
        XCTAssertEqual(desire(engine: .llamaOpenSource), .stopped)
    }

    func test_intelIsUnsupported() {
        XCTAssertEqual(desire(appleSilicon: false), .unavailable(.unsupportedHardware))
    }

    func test_noModelOrAMissingDownloadIsExplained() {
        XCTAssertEqual(desire(modelID: ""), .unavailable(.noModel))
        let other = MLXRepoID("mlx-community/other")!
        XCTAssertEqual(desire(modelID: other.value), .unavailable(.modelNotDownloaded(other)))
    }

    func test_waitsForTheFirstCacheScan() {
        XCTAssertEqual(desire(cached: .some(nil)), .stopped)
    }

    func test_aRejectedModelSaysWhy() {
        let id = MLXRepoID("a/embed")!
        XCTAssertEqual(
            desire(modelID: "a/embed", cached: [], rejected: [id: .embeddingModel]),
            .unavailable(.modelIncompatible(id, "Embedding model: it can't write text.")))
    }
}
