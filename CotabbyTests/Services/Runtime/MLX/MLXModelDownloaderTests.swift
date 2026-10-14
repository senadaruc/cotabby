import XCTest
@testable import Cotabby

@MainActor
final class MLXModelDownloaderTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private var cacheRoot: URL!
    private let toolchain = MLXToolchain(
        serverExecutable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"),
        pythonExecutable: URL(fileURLWithPath: "/mlx/python"),
        version: "0.32.0", isCotabbyInstall: true)

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    /// Writes a complete cached model the way huggingface_hub would leave it.
    private func writeCachedModel(_ id: String, type: String = "gemma4") throws {
        let repo = cacheRoot.appendingPathComponent(MLXRepoID(id)!.cacheFolderName)
        let snapshot = repo.appendingPathComponent("snapshots/rev")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try "rev".write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        try "{\"model_type\":\"\(type)\"}".write(to: snapshot.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "w".write(to: snapshot.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
        try "{}".write(to: snapshot.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
    }

    private func makeDownloader(
        files: @escaping (String) async throws -> [HFRepoFile] = { _ in [] },
        gated: @escaping (String) async throws -> Bool = { _ in false },
        run: @escaping MLXModelDownloader.RunProcess = { _, _, _, _ in MLXProcessResult(status: 0, stdout: "[\"gemma4\"]", stderrTail: []) }
    ) -> MLXModelDownloader {
        let downloader = MLXModelDownloader(
            cacheRoot: cacheRoot, fileManager: .default,
            fetchRepoFiles: files, fetchIsGated: gated, runProcess: run, pollInterval: .milliseconds(20))
        Self.retained.append(downloader)
        return downloader
    }

    func test_refreshFiltersByTheInstalledArchitectures() async throws {
        try writeCachedModel("a/gemma", type: "gemma4")
        try writeCachedModel("a/other", type: "mamba_x")
        let downloader = makeDownloader()
        XCTAssertNil(downloader.cachedModels, "nil until the first scan")
        await downloader.refreshCache(toolchain: toolchain)
        XCTAssertEqual(downloader.cachedModels?.map(\.repoID.value), ["a/gemma"])
        await downloader.refreshCache(toolchain: nil)
        XCTAssertEqual(downloader.cachedModels?.count, 2, "without mlx-lm the type filter is skipped")
    }

    func test_validationRejectsBadIDsWithoutNetwork() async {
        let downloader = makeDownloader(files: { _ in XCTFail("no network for a bad id"); return [] })
        let result = await downloader.validateCustomRepo("../../etc")
        XCTAssertEqual(result, .invalidID)
    }

    func test_validationClassifiesRepos() async {
        let missing = makeDownloader(files: { _ in throw HuggingFaceAPIClient.APIError.httpError(statusCode: 404) })
        let missingResult = await missing.validateCustomRepo("a/b")
        XCTAssertEqual(missingResult, .notFoundOrPrivate(MLXRepoID("a/b")!))

        let gated = makeDownloader(files: { _ in [HFRepoFile(path: "config.json", size: 1)] }, gated: { _ in true })
        let gatedResult = await gated.validateCustomRepo("a/b")
        XCTAssertEqual(gatedResult, .gated(MLXRepoID("a/b")!))

        let gguf = makeDownloader(files: { _ in [HFRepoFile(path: "config.json", size: 1), HFRepoFile(path: "m.gguf", size: 9)] })
        let ggufResult = await gguf.validateCustomRepo("a/b")
        XCTAssertEqual(ggufResult, .notMLX(MLXRepoID("a/b")!))

        let good = makeDownloader(files: { _ in
            [HFRepoFile(path: "config.json", size: 1), HFRepoFile(path: "model.safetensors", size: 99)]
        })
        let goodResult = await good.validateCustomRepo("https://huggingface.co/a/b")
        XCTAssertEqual(goodResult, .valid(MLXRepoID("a/b")!, totalBytes: 100))
    }

    func test_downloadRunsTheToolchainPythonAndRefreshes() async throws {
        var calls: [(URL, [String], [String: String])] = []
        let downloader = makeDownloader(
            files: { _ in [HFRepoFile(path: "model.safetensors", size: 100)] },
            run: { [unowned self] executable, arguments, environment, _ in
                calls.append((executable, arguments, environment))
                if arguments.last == "a/b" { try self.writeCachedModel("a/b") }
                return MLXProcessResult(status: 0, stdout: "[\"gemma4\"]", stderrTail: [])
            }
        )
        downloader.startDownload(MLXRepoID("a/b")!, toolchain: toolchain)
        XCTAssertEqual(downloader.download?.isActive, true)
        await waitUntil { downloader.download == nil && downloader.cachedModels?.isEmpty == false }
        let download = try XCTUnwrap(calls.first { $0.1.last == "a/b" })
        XCTAssertEqual(download.0.path, "/mlx/python")
        XCTAssertEqual(download.1, ["-I", "-c", MLXToolchainRules.downloadScript, "a/b"])
        XCTAssertNil(download.2["HF_HUB_OFFLINE"])
        XCTAssertEqual(downloader.cachedModels?.map(\.repoID.value), ["a/b"])
    }

    func test_downloadFailureKeepsTheLastErrorLine() async {
        let downloader = makeDownloader(run: { _, arguments, _, _ in
            arguments.last == "a/b"
                ? MLXProcessResult(status: 1, stdout: "", stderrTail: ["Traceback", "RepositoryNotFoundError: a/b"])
                : MLXProcessResult(status: 0, stdout: "[]", stderrTail: [])
        })
        downloader.startDownload(MLXRepoID("a/b")!, toolchain: toolchain)
        await waitUntil { downloader.download?.isActive == false }
        XCTAssertEqual(downloader.download?.failure, "RepositoryNotFoundError: a/b")
    }

    func test_progressAndCancel() async throws {
        let downloader = makeDownloader(
            files: { _ in [HFRepoFile(path: "model.safetensors", size: 1000)] },
            run: { [unowned self] _, arguments, _, _ in
                guard arguments.last == "a/b" else { return MLXProcessResult(status: 0, stdout: "[]", stderrTail: []) }
                let blobs = self.cacheRoot.appendingPathComponent("models--a--b/blobs")
                try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
                try Data(count: 500).write(to: blobs.appendingPathComponent("x.incomplete"))
                try await Task.sleep(for: .seconds(60))
                return MLXProcessResult(status: 0, stdout: "", stderrTail: [])
            }
        )
        downloader.startDownload(MLXRepoID("a/b")!, toolchain: toolchain)
        await waitUntil { downloader.download?.fraction == 0.5 }
        downloader.startDownload(MLXRepoID("c/d")!, toolchain: toolchain)
        XCTAssertEqual(downloader.download?.repoID.value, "a/b", "one download at a time")
        downloader.cancelDownload()
        await waitUntil { downloader.download == nil }
    }

    /// Review focus 2.
    func test_deletingActiveModelRefreshesCacheWithoutIt() async throws {
        try writeCachedModel("a/b")
        let downloader = makeDownloader()
        await downloader.refreshCache(toolchain: toolchain)
        XCTAssertEqual(downloader.cachedModels?.count, 1)
        await downloader.delete(MLXRepoID("a/b")!, toolchain: toolchain)
        XCTAssertEqual(downloader.cachedModels, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("models--a--b").path))
    }
}
