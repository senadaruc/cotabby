import Foundation

/// File overview:
/// Reads the Hugging Face cache the way huggingface_hub lays it out and decides which cached repos
/// are models `mlx_lm.server` can run for autocomplete. Pure apart from reading the folder it is
/// given, so tests build fixture trees in a temp directory. Lives in `Support/` because it is a
/// rule ("what counts as a usable MLX model"), not a service with state.
///
/// Cache layout: `<root>/models--<owner>--<name>/{blobs/<sha>[.incomplete], refs/main,
/// snapshots/<revision>/<file> -> ../../blobs/<sha>}`.
nonisolated enum MLXCacheScanner {
    /// Same precedence as huggingface_hub. GUI apps rarely inherit these variables (launchd does
    /// not read shell profiles), so the default path is the common case.
    static func cacheRoot(environment: [String: String], home: URL) -> URL {
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            return URL(fileURLWithPath: hubCache, isDirectory: true)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome, isDirectory: true).appendingPathComponent("hub", isDirectory: true)
        }
        return home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Repo names that mark a model which is not a text generator.
    private static let excludedNameFragments = ["embed", "rerank", "tts", "whisper", "speech", "asr", "audio"]
    /// `architectures` entries that mark a non-generative head.
    private static let excludedArchitectureFragments = ["Embedding", "SequenceClassification", "Speech", "CTC", "Audio"]
    private static let tokenizerFiles = ["tokenizer.json", "tokenizer.model", "tokenizer_config.json"]

    /// Every usable model, sorted by repo id. `supportedModelTypes` is nil when mlx-lm is not
    /// installed yet; the type filter is then skipped (nothing can run anyway, and hiding the
    /// user's models would read as "your download vanished").
    static func scan(
        cacheRoot: URL,
        supportedModelTypes: Set<String>?,
        fileManager: FileManager = .default
    ) -> [MLXCachedModel] {
        guard let folders = try? fileManager.contentsOfDirectory(atPath: cacheRoot.path) else { return [] }
        return folders.compactMap { folder -> MLXCachedModel? in
            guard let repoID = MLXRepoID(cacheFolderName: folder) else { return nil }
            let lowerName = repoID.name.lowercased()
            guard !excludedNameFragments.contains(where: { lowerName.contains($0) }) else { return nil }
            let repoURL = cacheRoot.appendingPathComponent(folder, isDirectory: true)
            guard !hasIncompleteBlob(repoURL, fileManager: fileManager),
                  let snapshot = currentSnapshot(repoURL, fileManager: fileManager),
                  let files = try? fileManager.contentsOfDirectory(atPath: snapshot.path),
                  files.contains("config.json"),
                  files.contains(where: { $0.hasSuffix(".safetensors") }),
                  files.contains(where: { tokenizerFiles.contains($0) }),
                  let config = readConfig(snapshot.appendingPathComponent("config.json")),
                  let modelType = config["model_type"] as? String
            else { return nil }
            let architectures = config["architectures"] as? [String] ?? []
            guard !architectures.contains(where: { arch in excludedArchitectureFragments.contains(where: { arch.contains($0) }) })
            else { return nil }
            if let supportedModelTypes, !supportedModelTypes.contains(modelType) { return nil }
            return MLXCachedModel(
                repoID: repoID,
                snapshotURL: snapshot,
                sizeBytes: snapshotBytes(snapshot, files: files, fileManager: fileManager),
                modelType: modelType,
                isInstruct: isInstructName(repoID.name)
            )
        }
        .sorted { $0.repoID.value.localizedCaseInsensitiveCompare($1.repoID.value) == .orderedAscending }
    }

    /// "-it", "instruct" or "chat" as a whole `-`/`_`/`.` separated token.
    static func isInstructName(_ name: String) -> Bool {
        let tokens = name.lowercased().split(whereSeparator: { "-_.".contains($0) })
        return tokens.contains { $0 == "it" || $0 == "instruct" || $0 == "chat" }
    }

    /// Bytes of a repo's blobs, finished and partial, for download progress.
    static func downloadedBytes(repo: MLXRepoID, cacheRoot: URL, fileManager: FileManager = .default) -> Int64 {
        let blobs = cacheRoot.appendingPathComponent("\(repo.cacheFolderName)/blobs", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: blobs.path) else { return 0 }
        return names.reduce(Int64(0)) { sum, name in
            let size = (try? fileManager.attributesOfItem(atPath: blobs.appendingPathComponent(name).path)[.size]) as? NSNumber
            return sum + (size?.int64Value ?? 0)
        }
    }

    static func progress(downloadedBytes: Int64, totalBytes: Int64) -> Double? {
        guard totalBytes > 0 else { return nil }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }

    // MARK: - Private

    private static func hasIncompleteBlob(_ repo: URL, fileManager: FileManager) -> Bool {
        let names = (try? fileManager.contentsOfDirectory(atPath: repo.appendingPathComponent("blobs").path)) ?? []
        return names.contains { $0.hasSuffix(".incomplete") }
    }

    /// The revision `refs/main` names, else the most recently modified snapshot.
    private static func currentSnapshot(_ repo: URL, fileManager: FileManager) -> URL? {
        let snapshots = repo.appendingPathComponent("snapshots", isDirectory: true)
        if let revision = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty {
            let url = snapshots.appendingPathComponent(revision, isDirectory: true)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        let revisions = (try? fileManager.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return revisions
            .map { snapshots.appendingPathComponent($0, isDirectory: true) }
            .max { modificationDate($0, fileManager) < modificationDate($1, fileManager) }
    }

    private static func modificationDate(_ url: URL, _ fileManager: FileManager) -> Date {
        ((try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
    }

    private static func readConfig(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Snapshot files are symlinks into `blobs/`; sizes are read from the link targets.
    private static func snapshotBytes(_ snapshot: URL, files: [String], fileManager: FileManager) -> Int64 {
        files.reduce(Int64(0)) { sum, name in
            let target = snapshot.appendingPathComponent(name).resolvingSymlinksInPath()
            let size = (try? fileManager.attributesOfItem(atPath: target.path)[.size]) as? NSNumber
            return sum + (size?.int64Value ?? 0)
        }
    }
}
