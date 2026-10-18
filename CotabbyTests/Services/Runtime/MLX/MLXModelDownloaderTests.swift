import XCTest
@testable import Cotabby

@MainActor
final class MLXModelDownloaderTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private var cacheRoot: URL!

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

    /// A remote repo: file path to content. Blob ids are derived from the path so they are stable.
    private static func remote(_ files: [String: Data], revision: String = "rev1") -> MLXRemoteSnapshot {
        MLXRemoteSnapshot(
            revision: revision,
            files: files.keys.sorted().map {
                MLXRemoteSnapshot.File(path: $0, size: Int64(files[$0]!.count), blobID: blobID($0))
            })
    }

    private static func blobID(_ path: String) -> String { "blob-" + path.replacingOccurrences(of: "/", with: "_") }

    private static func modelFiles(type: String = "gemma4", weights: Int = 64) -> [String: Data] {
        [
            "config.json": Data("{\"model_type\":\"\(type)\"}".utf8),
            "model.safetensors": Data((0..<weights).map { UInt8($0 % 251) }),
            "tokenizer.json": Data("{}".utf8)
        ]
    }

    /// A transfer that serves `files` from memory, appending from `offset` like the HTTP one.
    private static func serving(
        _ files: [String: Data], calls: TransferLog? = nil, failWith error: Error? = nil
    ) -> MLXSnapshotDownloader.Transfer {
        { remote, local, offset in
            let path = remote.path.components(separatedBy: "/resolve/").last!.split(separator: "/", maxSplits: 1).last.map(String.init)!
            calls?.record(path: path, offset: offset)
            if let error { throw error }
            let bytes = files[path]!.dropFirst(Int(offset))
            if offset == 0 { FileManager.default.createFile(atPath: local.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: local)
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.close()
        }
    }

    private func makeDownloader(
        snapshot: @escaping MLXModelDownloader.SnapshotFetch = { _ in MLXRemoteSnapshot(revision: "rev1", files: []) },
        gated: @escaping (String) async throws -> Bool = { _ in false },
        config: @escaping MLXModelDownloader.ConfigFetch = { _ in Data("{\"model_type\":\"gemma4\"}".utf8) },
        transfer: @escaping MLXSnapshotDownloader.Transfer = { _, _, _ in XCTFail("no transfer expected") },
        supported: Set<String> = ["gemma4", "llama", "qwen3"]
    ) -> MLXModelDownloader {
        let downloader = MLXModelDownloader(
            cacheRoot: cacheRoot, fileManager: .default,
            fetchSnapshot: snapshot, fetchIsGated: gated, fetchConfig: config, transfer: transfer,
            isSupportedModelType: { supported.contains($0) }, pollInterval: .milliseconds(20))
        Self.retained.append(downloader)
        return downloader
    }

    // MARK: - Cache

    func test_refreshFiltersByTheRuntimeArchitectures() async throws {
        try writeCachedModel("a/gemma", type: "gemma4")
        try writeCachedModel("a/other", type: "mamba_x")
        let downloader = makeDownloader()
        XCTAssertNil(downloader.cachedModels, "nil until the first scan")
        await downloader.refreshCache()
        XCTAssertEqual(downloader.cachedModels?.map(\.repoID.value), ["a/gemma"])
        XCTAssertEqual(downloader.rejectedModels, [MLXRepoID("a/other")!: .unsupportedArchitecture("mamba_x")])
    }

    func test_refreshPublishesRejectedModels() async throws {
        try writeCachedModel("a/gemma", type: "gemma4")
        try writeCachedModel("a/gemma-embed", type: "gemma4")
        let downloader = makeDownloader()
        await downloader.refreshCache()
        XCTAssertEqual(downloader.rejectedModels, [MLXRepoID("a/gemma-embed")!: .embeddingModel])
    }

    func test_theRealRegistryKnowsGemma4AndNotAnInventedType() async {
        let gemma = await MLXRuntimeCore.supportsModelType("gemma4")
        let invented = await MLXRuntimeCore.supportsModelType("not_a_model_type")
        XCTAssertTrue(gemma)
        XCTAssertFalse(invented)
    }

    // MARK: - Custom repo check

    func test_validationRejectsBadIDsWithoutNetwork() async {
        let downloader = makeDownloader(snapshot: { _ in XCTFail("no network for a bad id"); return Self.remote([:]) })
        let result = await downloader.validateCustomRepo("../../etc")
        XCTAssertEqual(result, .invalidID)
    }

    func test_validationClassifiesRepos() async {
        let missing = makeDownloader(snapshot: { _ in throw HuggingFaceAPIClient.APIError.httpError(statusCode: 404) })
        let missingResult = await missing.validateCustomRepo("a/b")
        XCTAssertEqual(missingResult, .notFoundOrPrivate(MLXRepoID("a/b")!))

        let gated = makeDownloader(snapshot: { _ in Self.remote(["config.json": Data("{}".utf8)]) }, gated: { _ in true })
        let gatedResult = await gated.validateCustomRepo("a/b")
        XCTAssertEqual(gatedResult, .gated(MLXRepoID("a/b")!))

        let gguf = makeDownloader(snapshot: { _ in Self.remote(["config.json": Data("{}".utf8), "m.gguf": Data(count: 9)]) })
        let ggufResult = await gguf.validateCustomRepo("a/b")
        XCTAssertEqual(ggufResult, .incompatible(MLXRepoID("a/b")!, .missingWeights))

        let files = Self.modelFiles()
        let good = makeDownloader(snapshot: { _ in Self.remote(files) })
        let goodResult = await good.validateCustomRepo("https://huggingface.co/a/b")
        XCTAssertEqual(goodResult, .valid(MLXRepoID("a/b")!, totalBytes: Self.remote(files).totalBytes, isInstruct: false))
    }

    func test_validationRejectsEmbeddingRepo() async {
        let files = Self.modelFiles()
        let downloader = makeDownloader(snapshot: { _ in Self.remote(files) })
        let result = await downloader.validateCustomRepo("mlx-community/Qwen3-Embedding-0.6B")
        XCTAssertEqual(result, .incompatible(MLXRepoID("mlx-community/Qwen3-Embedding-0.6B")!, .embeddingModel))
    }

    func test_validationRejectsAModelTypeTheRuntimeCannotBuild() async {
        let files = Self.modelFiles()
        let downloader = makeDownloader(
            snapshot: { _ in Self.remote(files) },
            config: { _ in Data("{\"model_type\":\"mamba_x\"}".utf8) })
        let result = await downloader.validateCustomRepo("a/b")
        XCTAssertEqual(result, .incompatible(MLXRepoID("a/b")!, .unsupportedArchitecture("mamba_x")))
    }

    func test_validationMarksInstructReposAndMapsConfig404() async {
        let files = Self.modelFiles()
        let instruct = makeDownloader(snapshot: { _ in Self.remote(files) })
        let result = await instruct.validateCustomRepo("a/gemma-it")
        XCTAssertEqual(result, .valid(MLXRepoID("a/gemma-it")!, totalBytes: Self.remote(files).totalBytes, isInstruct: true))

        let gone = makeDownloader(
            snapshot: { _ in Self.remote(files) },
            config: { _ in throw HuggingFaceAPIClient.APIError.httpError(statusCode: 404) })
        let goneResult = await gone.validateCustomRepo("a/b")
        XCTAssertEqual(goneResult, .incompatible(MLXRepoID("a/b")!, .missingConfig))
    }

    // MARK: - Download

    func test_downloadWritesTheHuggingFaceCacheLayoutAndListsTheModel() async throws {
        let files = Self.modelFiles()
        let downloader = makeDownloader(snapshot: { _ in Self.remote(files) }, transfer: Self.serving(files))
        downloader.startDownload(MLXRepoID("a/b")!)
        XCTAssertEqual(downloader.download?.isActive, true)
        await waitUntil { downloader.download == nil && downloader.cachedModels?.isEmpty == false }

        XCTAssertEqual(downloader.cachedModels?.map(\.repoID.value), ["a/b"])
        let repo = cacheRoot.appendingPathComponent("models--a--b")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8), "rev1")
        let link = repo.appendingPathComponent("snapshots/rev1/model.safetensors")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../../blobs/blob-model.safetensors")
        XCTAssertEqual(try Data(contentsOf: link), files["model.safetensors"])
        let blobs = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("blobs").path)
        XCTAssertFalse(blobs.contains { $0.hasSuffix(".incomplete") })
    }

    func test_downloadResumesAPartialBlobFromItsSize() async throws {
        let files = Self.modelFiles(weights: 1_000)
        let blobs = cacheRoot.appendingPathComponent("models--a--b/blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try files["model.safetensors"]!.prefix(400)
            .write(to: blobs.appendingPathComponent("blob-model.safetensors.incomplete"))
        let log = TransferLog()
        let downloader = makeDownloader(snapshot: { _ in Self.remote(files) }, transfer: Self.serving(files, calls: log))
        downloader.startDownload(MLXRepoID("a/b")!)
        await waitUntil { downloader.download == nil && downloader.cachedModels?.isEmpty == false }

        XCTAssertEqual(log.offsets["model.safetensors"], 400)
        XCTAssertEqual(try Data(contentsOf: blobs.appendingPathComponent("blob-model.safetensors")), files["model.safetensors"])
    }

    func test_downloadSkipsBlobsTheCacheAlreadyHolds() async throws {
        let files = Self.modelFiles()
        let blobs = cacheRoot.appendingPathComponent("models--a--b/blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try files["model.safetensors"]!.write(to: blobs.appendingPathComponent("blob-model.safetensors"))
        let log = TransferLog()
        let downloader = makeDownloader(snapshot: { _ in Self.remote(files) }, transfer: Self.serving(files, calls: log))
        downloader.startDownload(MLXRepoID("a/b")!)
        await waitUntil { downloader.download == nil && downloader.cachedModels?.isEmpty == false }
        XCTAssertNil(log.offsets["model.safetensors"], "a complete blob is not downloaded again")
        XCTAssertEqual(log.offsets.keys.sorted(), ["config.json", "tokenizer.json"])
    }

    func test_downloadFailureShowsTheError() async {
        let files = Self.modelFiles()
        let downloader = makeDownloader(
            snapshot: { _ in Self.remote(files) },
            transfer: Self.serving(files, failWith: MLXSnapshotDownloadError.http(statusCode: 503)))
        downloader.startDownload(MLXRepoID("a/b")!)
        await waitUntil { downloader.download?.isActive == false }
        XCTAssertEqual(downloader.download?.failure, "Hugging Face returned HTTP 503.")
        XCTAssertEqual(downloader.cachedModels, [])
    }

    func test_aShortFileFailsAndStaysForTheNextAttempt() async throws {
        let files = Self.modelFiles(weights: 100)
        var short = files
        short["model.safetensors"] = files["model.safetensors"]!.prefix(60)
        let downloader = makeDownloader(snapshot: { _ in Self.remote(files) }, transfer: Self.serving(short))
        downloader.startDownload(MLXRepoID("a/b")!)
        await waitUntil { downloader.download?.isActive == false }
        XCTAssertEqual(downloader.download?.failure, "model.safetensors arrived with 60 of 100 bytes. Try again.")
        let partial = cacheRoot.appendingPathComponent("models--a--b/blobs/blob-model.safetensors.incomplete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("models--a--b/refs/main").path))
    }

    func test_finishedDownloadOfUnsupportedArchitectureReportsIt() async {
        let files = Self.modelFiles(type: "mamba_x")
        let downloader = makeDownloader(snapshot: { _ in Self.remote(files) }, transfer: Self.serving(files))
        downloader.startDownload(MLXRepoID("a/b")!)
        await waitUntil { downloader.download?.isActive == false }
        XCTAssertEqual(
            downloader.download?.failure,
            "Downloaded, but it can't be used. Architecture “mamba_x” isn't supported by Cotabby's MLX runtime.")
        XCTAssertEqual(downloader.cachedModels?.isEmpty, true)
    }

    func test_progressAndCancel() async throws {
        let snapshot = MLXRemoteSnapshot(
            revision: "rev1", files: [.init(path: "model.safetensors", size: 1_000, blobID: "x")])
        let downloader = makeDownloader(
            snapshot: { _ in snapshot },
            transfer: { _, local, _ in
                try Data(count: 500).write(to: local)
                try await Task.sleep(for: .seconds(60))
            })
        downloader.startDownload(MLXRepoID("a/b")!)
        await waitUntil { downloader.download?.fraction == 0.5 }
        downloader.startDownload(MLXRepoID("c/d")!)
        XCTAssertEqual(downloader.download?.repoID.value, "a/b", "one download at a time")
        downloader.cancelDownload()
        await waitUntil { downloader.download == nil }
        let partial = cacheRoot.appendingPathComponent("models--a--b/blobs/x.incomplete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "the partial file stays to resume")
    }

    // MARK: - Delete

    func test_deletingActiveModelRefreshesCacheWithoutIt() async throws {
        try writeCachedModel("a/b")
        let downloader = makeDownloader()
        await downloader.refreshCache()
        XCTAssertEqual(downloader.cachedModels?.count, 1)
        await downloader.delete(MLXRepoID("a/b")!)
        XCTAssertEqual(downloader.cachedModels, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("models--a--b").path))
    }

    /// A scan that read the disk before the delete finishes after it. The first scan reads the
    /// model, then holds; the delete's own scan runs and publishes the list without it; releasing
    /// the stale scan must not bring the model back.
    func test_staleRefreshCannotResurrectADeletedModel() async throws {
        try writeCachedModel("a/b")
        let calls = CallCounter()
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let downloader = MLXModelDownloader(
            cacheRoot: cacheRoot, fileManager: .default,
            fetchSnapshot: { _ in MLXRemoteSnapshot(revision: "r", files: []) }, fetchIsGated: { _ in false },
            isSupportedModelType: { _ in true },
            pollInterval: .milliseconds(20),
            scanCache: { root in
                let models = MLXCacheScanner.scanDetailed(cacheRoot: root, supportedModelTypes: nil)
                if calls.next() == 1 {
                    enteredSignal.yield()
                    for await _ in release { break }
                }
                return models
            }
        )
        Self.retained.append(downloader)
        let stale = Task { await downloader.refreshCache() }
        for await _ in entered { break }

        await downloader.delete(MLXRepoID("a/b")!)
        XCTAssertEqual(downloader.cachedModels, [])

        releaseSignal.yield()
        await stale.value
        XCTAssertEqual(downloader.cachedModels, [], "the older scan saw the model before the delete and must not publish it")
    }

    /// Deleting the repo that is downloading must stop the download first, so the partial files
    /// cannot reappear once the folder is gone.
    func test_deletingTheActiveDownloadCancelsItFirst() async throws {
        let snapshot = MLXRemoteSnapshot(
            revision: "rev1", files: [.init(path: "model.safetensors", size: 1_000, blobID: "x")])
        let downloader = makeDownloader(
            snapshot: { _ in snapshot },
            transfer: { _, local, _ in
                try Data(count: 500).write(to: local)
                try await Task.sleep(for: .seconds(60))
            })
        downloader.startDownload(MLXRepoID("a/b")!)
        await waitUntil { downloader.download?.fraction == 0.5 }

        await downloader.delete(MLXRepoID("a/b")!)

        XCTAssertNil(downloader.download, "the delete waited for the download to stop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("models--a--b").path))
        XCTAssertEqual(downloader.cachedModels, [])
    }
}

/// Which files a fake transfer was asked for, and from which offset. Locked because the transfer
/// runs off the main actor.
private final class TransferLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int64] = [:]

    var offsets: [String: Int64] { lock.withLock { storage } }

    func record(path: String, offset: Int64) {
        lock.withLock { storage[path] = offset }
    }
}

/// Counts calls from a `@Sendable` closure. The lock makes the count safe to bump from the detached scan.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns the 1-based number of this call.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
