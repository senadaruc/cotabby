import Combine
import Foundation
import Logging

/// File overview:
/// Owns everything about MLX model files:
/// - which usable models the Hugging Face cache holds (`cachedModels`);
/// - one download at a time, with byte progress and cancel;
/// - checking a custom repo id before downloading it;
/// - deleting a model.
/// Downloads run in Swift (`MLXSnapshotDownloader`) into the huggingface_hub cache layout, so a
/// model downloaded by Python tools is reused and a cancelled download resumes next time. Which
/// architectures count as usable is asked of mlx-swift-lm's model registry, the code that will
/// load the model. Owned by `CotabbyAppEnvironment`; the Settings pane observes it.

/// The answer to "can Cotabby download this custom repo?", shown under the Settings text field.
/// A value type because the pane only renders it; it owns no state and no network access.
nonisolated enum MLXRepoValidation: Equatable, Sendable {
    case valid(MLXRepoID, totalBytes: Int64, isInstruct: Bool)
    case invalidID
    case notFoundOrPrivate(MLXRepoID)
    case gated(MLXRepoID)
    case incompatible(MLXRepoID, MLXModelCompatibility.Reason)
    case networkError(String)

    /// Nil for `.valid`; otherwise the sentence the pane shows under the field.
    var message: String? {
        switch self {
        case .valid: return nil
        case .invalidID: return "Enter a Hugging Face model id like mlx-community/gemma-4-e4b-5bit."
        case .notFoundOrPrivate(let id): return "\(id.value) was not found, or it is private."
        case .gated(let id): return "\(id.value) needs a Hugging Face login, which Cotabby does not support yet."
        case .incompatible(let id, let reason): return "\(id.value): \(reason.message)"
        case .networkError(let message): return "Could not reach Hugging Face: \(message)"
        }
    }
}

/// The download and cache manager behind the MLX model list. It is `@MainActor` because the
/// Settings pane observes its published state; the heavy work (directory scans, the download
/// itself) runs off the main actor and only the resulting values are published back.
/// Its collaborators are injected closures, so tests replace the network with fakes.
@MainActor
final class MLXModelDownloader: ObservableObject {
    typealias SnapshotFetch = (String) async throws -> MLXRemoteSnapshot
    typealias GatedFetch = (String) async throws -> Bool
    /// Downloads one small file (`config.json`) of a remote repo: repo id, then file path.
    typealias ConfigFetch = (String) async throws -> Data
    /// Whether the bundled mlx-swift-lm can build a model of this `model_type`.
    typealias ModelTypeSupport = @Sendable (String) async -> Bool
    /// The cache scan, injectable so a test can hold one scan after it has read the disk.
    typealias CacheScan = @Sendable (URL) async -> MLXCacheScanResult

    /// Nil until the first scan finishes, so the server wiring waits instead of reporting the
    /// selected model as missing during launch.
    @Published private(set) var cachedModels: [MLXCachedModel]?
    /// Complete downloads the compatibility rule turned away, with the reason. Published together
    /// with `cachedModels` so the UI and the server wiring never see one without the other.
    @Published private(set) var rejectedModels: [MLXRepoID: MLXModelCompatibility.Reason] = [:]
    @Published private(set) var download: MLXDownloadState?

    private let cacheRoot: URL
    private let fileManager: FileManager
    private let fetchSnapshot: SnapshotFetch
    private let fetchIsGated: GatedFetch
    private let fetchConfig: ConfigFetch
    private let transfer: MLXSnapshotDownloader.Transfer
    private let isSupportedModelType: ModelTypeSupport
    private let pollInterval: Duration
    private let scanCache: CacheScan
    private var downloadTask: Task<Void, Never>?
    /// Bumped by every `refreshCache`. Scans run off the main actor, so two can overlap; a scan
    /// that started before a delete could finish last and publish the deleted model again. Only
    /// the newest refresh may publish.
    private var refreshGeneration: UInt64 = 0

    init(
        cacheRoot: URL,
        fileManager: FileManager = .default,
        fetchSnapshot: @escaping SnapshotFetch = { try await HuggingFaceAPIClient.fetchSnapshot(repoId: $0) },
        fetchIsGated: @escaping GatedFetch = { try await HuggingFaceAPIClient.isGated(repoId: $0) },
        fetchConfig: @escaping ConfigFetch = {
            try await HuggingFaceAPIClient.fetchFileData(repoId: $0, path: "config.json")
        },
        transfer: @escaping MLXSnapshotDownloader.Transfer = { remote, local, offset in
            try await MLXHTTPFileTransfer.transfer(remote: remote, local: local, offset: offset)
        },
        isSupportedModelType: @escaping ModelTypeSupport = { await MLXRuntimeCore.supportsModelType($0) },
        pollInterval: Duration = .milliseconds(500),
        scanCache: @escaping CacheScan = { root in
            MLXCacheScanner.scanDetailed(cacheRoot: root, supportedModelTypes: nil)
        }
    ) {
        self.cacheRoot = cacheRoot
        self.fileManager = fileManager
        self.fetchSnapshot = fetchSnapshot
        self.fetchIsGated = fetchIsGated
        self.fetchConfig = fetchConfig
        self.transfer = transfer
        self.isSupportedModelType = isSupportedModelType
        self.pollInterval = pollInterval
        self.scanCache = scanCache
    }

    static func live() -> MLXModelDownloader {
        MLXModelDownloader(cacheRoot: MLXCacheScanner.cacheRoot(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ))
    }

    func refreshCache() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let root = cacheRoot
        let scan = scanCache
        let result = await Task.detached(priority: .utility) {
            await scan(root)
        }.value
        // The scan checks files and config; the architecture check asks the runtime's registry.
        var models: [MLXCachedModel] = []
        var rejected = result.rejected
        for model in result.models {
            if await isSupportedModelType(model.modelType) {
                models.append(model)
            } else {
                rejected[model.repoID] = .unsupportedArchitecture(model.modelType)
            }
        }
        // A newer refresh started while this one was suspended, so its answer is the current one.
        // Publishing this older scan could bring back a model that was just deleted.
        guard generation == refreshGeneration else { return }
        cachedModels = models
        rejectedModels = rejected
    }

    /// Checks a custom repo before any download, with the same `MLXModelCompatibility` rule the
    /// cache scan uses, so "accepted here" and "listed after download" cannot disagree. The repo's
    /// `config.json` (a few KB) is fetched for the architecture and head checks; a 404 there means
    /// the repo has no config at all.
    func validateCustomRepo(_ raw: String) async -> MLXRepoValidation {
        guard let repoID = MLXRepoID(raw) else { return .invalidID }
        do {
            let files = try await fetchSnapshot(repoID.value).files
            if try await fetchIsGated(repoID.value) { return .gated(repoID) }
            var config: [String: Any]?
            if files.contains(where: { $0.path == "config.json" }) {
                do {
                    let data = try await fetchConfig(repoID.value)
                    config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                } catch HuggingFaceAPIClient.APIError.httpError(404) {
                    return .incompatible(repoID, .missingConfig)
                }
            }
            var types: Set<String> = []
            if let modelType = config?["model_type"] as? String, await isSupportedModelType(modelType) {
                types.insert(modelType)
            }
            switch MLXModelCompatibility.verdict(
                repoName: repoID.name, fileNames: files.map(\.path), config: config, supportedModelTypes: types
            ) {
            case .incompatible(let reason):
                return .incompatible(repoID, reason)
            case .compatible(_, let isInstruct):
                return .valid(repoID, totalBytes: files.reduce(Int64(0)) { $0 + $1.size }, isInstruct: isInstruct)
            }
        } catch HuggingFaceAPIClient.APIError.httpError(let code) where [401, 403, 404].contains(code) {
            return .notFoundOrPrivate(repoID)
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    /// Starts one download; ignored while another runs.
    func startDownload(_ repoID: MLXRepoID) {
        guard downloadTask == nil else { return }
        download = MLXDownloadState(repoID: repoID, fraction: nil, failure: nil, isActive: true)
        CotabbyLogger.runtime.info("MLX model download started", metadata: ["model": .string(repoID.value)])
        downloadTask = Task { [weak self] in
            await self?.runDownload(repoID)
        }
    }

    /// Stops the download; the partial file resumes next time.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Removes the repo from the shared cache, then rescans (the server wiring reacts if it was
    /// the selected model).
    func delete(_ repoID: MLXRepoID) async {
        // A download still writing into this folder would bring the model back, so stop it and wait
        // until it has really finished before removing anything.
        if download?.repoID == repoID, download?.isActive == true {
            let task = downloadTask
            task?.cancel()
            await task?.value
        }
        let folder = cacheRoot.appendingPathComponent(repoID.cacheFolderName, isDirectory: true)
        let manager = fileManager
        // Model folders are several GB; removing them on the main actor would stall the UI.
        let failure: String? = await Task.detached(priority: .utility) { () -> String? in
            guard manager.fileExists(atPath: folder.path) else { return nil }
            do {
                try manager.removeItem(at: folder)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure {
            CotabbyLogger.runtime.error(
                "Could not delete MLX model",
                metadata: ["model": .string(repoID.value), "error": .string(failure)])
        } else {
            CotabbyLogger.runtime.info("Deleted MLX model", metadata: ["model": .string(repoID.value)])
        }
        await refreshCache()
    }

    // MARK: - Private

    private func runDownload(_ repoID: MLXRepoID) async {
        let root = cacheRoot
        let transfer = self.transfer
        let outcome: Result<Void, Error>
        do {
            let snapshot = try await fetchSnapshot(repoID.value)
            let total = snapshot.totalBytes
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    let bytes = await Task.detached(priority: .utility) {
                        MLXCacheScanner.downloadedBytes(repo: repoID, cacheRoot: root)
                    }.value
                    guard let self, self.download?.repoID == repoID, self.download?.isActive == true else { return }
                    self.download?.fraction = MLXCacheScanner.progress(downloadedBytes: bytes, totalBytes: total)
                    try? await Task.sleep(for: self.pollInterval)
                }
            }
            defer { poller.cancel() }
            // Detached work does not inherit cancellation, so forward this task's cancel to it.
            let work = Task.detached(priority: .utility) {
                try await MLXSnapshotDownloader.download(snapshot, repo: repoID, cacheRoot: root, transfer: transfer)
            }
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }

        switch outcome {
        case .success:
            // Cleared after the rescan below, once we know the model is actually usable.
            CotabbyLogger.runtime.info("MLX model downloaded", metadata: ["model": .string(repoID.value)])
        case .failure(let error) where error is CancellationError || Task.isCancelled:
            download = nil
        case .failure(let error):
            CotabbyLogger.runtime.error(
                "MLX model download failed",
                metadata: ["model": .string(repoID.value), "error": .string(error.localizedDescription)])
            download = MLXDownloadState(
                repoID: repoID, fraction: download?.fraction, failure: error.localizedDescription, isActive: false)
        }
        downloadTask = nil
        await refreshCache()
        // A finished download that the rescan does not list is one this runtime cannot load (its
        // architecture is unsupported); clearing the card silently would look like a no-op.
        if case .success = outcome, download?.repoID == repoID {
            if cachedModels?.contains(where: { $0.repoID == repoID }) == true {
                download = nil
            } else {
                // No rejection means the snapshot is missing files, i.e. the download is incomplete.
                let failure = rejectedModels[repoID].map { "Downloaded, but it can't be used. \($0.message)" }
                    ?? "The download did not complete. Try again."
                download = MLXDownloadState(
                    repoID: repoID, fraction: 1,
                    failure: failure,
                    isActive: false)
            }
        }
    }
}
