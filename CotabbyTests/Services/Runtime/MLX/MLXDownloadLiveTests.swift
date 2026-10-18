import XCTest
@testable import Cotabby

/// The one MLX test that talks to Hugging Face: downloads a 75 MB model into a temporary cache with
/// the live HTTP transfer, interrupts it, resumes it, then loads it in the in-process runtime and
/// generates. Skipped unless `RUN_MLX_DOWNLOAD_LIVE=1` (pass `TEST_RUNNER_RUN_MLX_DOWNLOAD_LIVE=1`
/// to xcodebuild), because it needs the network and Apple Silicon.
final class MLXDownloadLiveTests: XCTestCase {
    private let repo = MLXRepoID("mlx-community/SmolLM-135M-Instruct-4bit")!

    func test_downloadResumeLoadAndGenerate() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_MLX_DOWNLOAD_LIVE"] == "1", "live download test")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await HuggingFaceAPIClient.fetchSnapshot(repoId: repo.value)
        let weights = try XCTUnwrap(snapshot.files.first { $0.path == "model.safetensors" })
        XCTAssertEqual(weights.blobID.count, 64, "an LFS file is stored under its sha256")

        // Interrupt the weights download once a third has arrived.
        let partial = root.appendingPathComponent("\(repo.cacheFolderName)/blobs/\(weights.blobID).incomplete")
        let interrupted = Task {
            try await MLXSnapshotDownloader.download(snapshot, repo: repo, cacheRoot: root) { remote, local, offset in
                try await MLXHTTPFileTransfer.transfer(remote: remote, local: local, offset: offset)
            }
        }
        while ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
            < weights.size / 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        interrupted.cancel()
        _ = await interrupted.result
        let kept = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(kept, 0, "the partial file stays")
        XCTAssertLessThan(kept, weights.size)

        var resumedFrom: Int64?
        try await MLXSnapshotDownloader.download(snapshot, repo: repo, cacheRoot: root) { remote, local, offset in
            if remote.lastPathComponent == "model.safetensors" { resumedFrom = offset }
            try await MLXHTTPFileTransfer.transfer(remote: remote, local: local, offset: offset)
        }
        XCTAssertEqual(resumedFrom, kept, "the weights resumed where they stopped")

        let scan = MLXCacheScanner.scanDetailed(cacheRoot: root, supportedModelTypes: nil)
        let model = try XCTUnwrap(scan.models.first, "listed: \(scan)")
        let core = MLXRuntimeCore()
        try await core.load(directory: model.snapshotURL, cacheLimitBytes: 256 << 20)
        let output = try core.generate(
            .text("The capital of France is"),
            options: LlamaGenerationOptions(maxPredictionTokens: 4, temperature: 0, topK: 1, topP: 1, minP: 0, repetitionPenalty: 1),
            operation: core.beginOperation(), onPartial: nil)
        core.unload()
        XCTAssertFalse(output.text.isEmpty)
    }
}
