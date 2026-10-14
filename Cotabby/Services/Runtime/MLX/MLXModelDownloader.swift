import Combine
import Foundation
import Logging

/// File overview:
/// Owns everything about MLX model files:
/// - which usable models the Hugging Face cache holds (`cachedModels`);
/// - one download at a time, with byte progress and cancel;
/// - checking a custom repo id before downloading it;
/// - deleting a model.
/// Downloads run the toolchain's own Python with `huggingface_hub.snapshot_download`, so files
/// land exactly where `mlx_lm.server` looks and a cancelled download resumes next time. Owned by
/// `CotabbyAppEnvironment`; the Settings pane observes it.

/// The answer to "can Cotabby download this custom repo?", shown under the Settings text field.
/// A value type because the pane only renders it; it owns no state and no network access.
nonisolated enum MLXRepoValidation: Equatable, Sendable {
    case valid(MLXRepoID, totalBytes: Int64)
    case invalidID
    case notFoundOrPrivate(MLXRepoID)
    case gated(MLXRepoID)
    case notMLX(MLXRepoID)
    case networkError(String)

    /// Nil for `.valid`; otherwise the sentence the pane shows under the field.
    var message: String? {
        switch self {
        case .valid: return nil
        case .invalidID: return "Enter a Hugging Face model id like mlx-community/gemma-4-e4b-5bit."
        case .notFoundOrPrivate(let id): return "\(id.value) was not found, or it is private."
        case .gated(let id): return "\(id.value) needs a Hugging Face login, which Cotabby does not support yet."
        case .notMLX(let id): return "\(id.value) has no MLX weights (config.json and .safetensors files)."
        case .networkError(let message): return "Could not reach Hugging Face: \(message)"
        }
    }
}

/// The download and cache manager behind the MLX model list. It is `@MainActor` because the
/// Settings pane observes its published state; the heavy work (directory scans, the Python
/// download itself) runs off the main actor and only the resulting values are published back.
/// Its collaborators are injected closures, so tests replace the network and the process with fakes.
@MainActor
final class MLXModelDownloader: ObservableObject {
    typealias RepoFilesFetch = (String) async throws -> [HFRepoFile]
    typealias GatedFetch = (String) async throws -> Bool
    typealias RunProcess = (URL, [String], [String: String], Duration) async throws -> MLXProcessResult

    /// Nil until the first scan finishes, so the server wiring waits instead of reporting the
    /// selected model as missing during launch.
    @Published private(set) var cachedModels: [MLXCachedModel]?
    @Published private(set) var download: MLXDownloadState?

    private let cacheRoot: URL
    private let fileManager: FileManager
    private let fetchRepoFiles: RepoFilesFetch
    private let fetchIsGated: GatedFetch
    private let runProcess: RunProcess
    private let pollInterval: Duration
    /// The architectures the installed mlx-lm supports, cached per Python (asked once, ~1 s).
    private var supportedTypes: (python: URL, types: Set<String>?)?
    private var downloadTask: Task<Void, Never>?

    init(
        cacheRoot: URL,
        fileManager: FileManager = .default,
        fetchRepoFiles: @escaping RepoFilesFetch = { try await HuggingFaceAPIClient.fetchRepoFiles(repoId: $0) },
        fetchIsGated: @escaping GatedFetch = { try await HuggingFaceAPIClient.isGated(repoId: $0) },
        runProcess: @escaping RunProcess = { executable, arguments, environment, timeout in
            try await MLXProcessRunner.run(
                executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        },
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.cacheRoot = cacheRoot
        self.fileManager = fileManager
        self.fetchRepoFiles = fetchRepoFiles
        self.fetchIsGated = fetchIsGated
        self.runProcess = runProcess
        self.pollInterval = pollInterval
    }

    static func live() -> MLXModelDownloader {
        MLXModelDownloader(cacheRoot: MLXCacheScanner.cacheRoot(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ))
    }

    func refreshCache(toolchain: MLXToolchain?) async {
        let types: Set<String>?
        if let toolchain {
            if let cached = supportedTypes, cached.python == toolchain.pythonExecutable {
                types = cached.types
            } else {
                types = await loadSupportedTypes(python: toolchain.pythonExecutable)
                // Cache only a real answer: a probe that failed or was cancelled must be retried
                // next time, not remembered as "unknown" (which turns the type filter off).
                if types != nil { supportedTypes = (toolchain.pythonExecutable, types) }
            }
        } else {
            types = nil
        }
        let root = cacheRoot
        cachedModels = await Task.detached(priority: .utility) {
            MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: types)
        }.value
    }

    func validateCustomRepo(_ raw: String) async -> MLXRepoValidation {
        guard let repoID = MLXRepoID(raw) else { return .invalidID }
        do {
            let files = try await fetchRepoFiles(repoID.value)
            if try await fetchIsGated(repoID.value) { return .gated(repoID) }
            guard files.contains(where: { $0.path == "config.json" }),
                  files.contains(where: { $0.path.hasSuffix(".safetensors") })
            else { return .notMLX(repoID) }
            return .valid(repoID, totalBytes: files.reduce(Int64(0)) { $0 + $1.size })
        } catch HuggingFaceAPIClient.APIError.httpError(let code) where [401, 403, 404].contains(code) {
            return .notFoundOrPrivate(repoID)
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    /// Starts one download; ignored while another runs.
    func startDownload(_ repoID: MLXRepoID, toolchain: MLXToolchain) {
        guard downloadTask == nil else { return }
        download = MLXDownloadState(repoID: repoID, fraction: nil, failure: nil, isActive: true)
        CotabbyLogger.runtime.info("MLX model download started", metadata: ["model": .string(repoID.value)])
        downloadTask = Task { [weak self] in
            await self?.runDownload(repoID, toolchain: toolchain)
        }
    }

    /// Terminates the download process. huggingface_hub resumes the partial files next time.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Removes the repo from the shared cache, then rescans (the server wiring reacts if it was
    /// the selected model).
    func delete(_ repoID: MLXRepoID, toolchain: MLXToolchain?) async {
        try? fileManager.removeItem(at: cacheRoot.appendingPathComponent(repoID.cacheFolderName, isDirectory: true))
        CotabbyLogger.runtime.info("Deleted MLX model", metadata: ["model": .string(repoID.value)])
        await refreshCache(toolchain: toolchain)
    }

    // MARK: - Private

    private func runDownload(_ repoID: MLXRepoID, toolchain: MLXToolchain) async {
        let total = (try? await fetchRepoFiles(repoID.value))?.reduce(Int64(0)) { $0 + $1.size } ?? 0
        let root = cacheRoot
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

        let outcome: Result<MLXProcessResult, Error>
        do {
            outcome = .success(try await runProcess(
                toolchain.pythonExecutable,
                ["-I", "-c", MLXToolchainRules.downloadScript, repoID.value],
                MLXToolchainRules.downloadEnvironment(base: ProcessInfo.processInfo.environment),
                .seconds(6 * 60 * 60)
            ))
        } catch {
            outcome = .failure(error)
        }
        poller.cancel()

        switch outcome {
        case .success(let result) where result.status == 0:
            download = nil
            CotabbyLogger.runtime.info("MLX model downloaded", metadata: ["model": .string(repoID.value)])
        case .success(let result):
            download = MLXDownloadState(
                repoID: repoID, fraction: download?.fraction,
                failure: result.stderrTail.last ?? "The download failed.", isActive: false)
        case .failure(let error) where error is CancellationError:
            download = nil
        case .failure(let error):
            download = MLXDownloadState(
                repoID: repoID, fraction: download?.fraction, failure: error.localizedDescription, isActive: false)
        }
        downloadTask = nil
        await refreshCache(toolchain: toolchain)
    }

    private func loadSupportedTypes(python: URL) async -> Set<String>? {
        guard let result = try? await runProcess(
            python,
            ["-I", "-c", MLXToolchainRules.supportedModelTypesScript],
            MLXToolchainRules.sanitizedEnvironment(ProcessInfo.processInfo.environment),
            .seconds(30)
        ), result.status == 0,
        let names = try? JSONDecoder().decode([String].self, from: Data(result.stdout.utf8))
        else { return nil }
        return Set(names)
    }
}
