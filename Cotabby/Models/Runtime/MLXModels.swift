import Foundation

/// File overview:
/// Shared values for the MLX engine: what this Mac can run, which models it offers, and the states
/// the runtime and downloads publish. Settings, the router and the MLX services all read these, so
/// they live in `Models/` rather than inside any one service.

/// Whether this build can run MLX. MLX needs Apple Silicon's GPU; a compile-time check is enough
/// because the MLX runtime is only built for arm64.
nonisolated enum MLXHardware {
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()
}

/// A validated Hugging Face model repo id ("owner/name"). It reaches download URLs and a cache
/// folder name, so only Hugging Face's own name alphabet is accepted, never path syntax. A pasted model-page URL is reduced to its id.
nonisolated struct MLXRepoID: Equatable, Hashable, Sendable, CustomStringConvertible {
    let owner: String
    let name: String

    var value: String { "\(owner)/\(name)" }
    var description: String { value }
    /// The folder `huggingface_hub` caches this repo under.
    var cacheFolderName: String { "models--\(owner)--\(name)" }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let host = url.host {
            guard host == "huggingface.co" || host == "www.huggingface.co" else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            text = "\(parts[0])/\(parts[1])"
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Self.isValidComponent(parts[0]), Self.isValidComponent(parts[1]) else {
            return nil
        }
        owner = parts[0]
        name = parts[1]
    }

    init?(cacheFolderName: String) {
        guard cacheFolderName.hasPrefix("models--") else { return nil }
        let parts = cacheFolderName.dropFirst("models--".count).components(separatedBy: "--")
        guard parts.count == 2 else { return nil }
        self.init("\(parts[0])/\(parts[1])")
    }

    /// Hugging Face allows letters, digits, `-`, `_` and `.`, forbids `--` and `..`, and names
    /// cannot start with `-` or `.`; at most 96 characters.
    private static func isValidComponent(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 96,
              let first = text.unicodeScalars.first,
              first != "-", first != ".",
              !text.contains("--"), !text.contains("..")
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return text.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}

/// One model Cotabby recommends, shown even before it is downloaded.
nonisolated struct MLXCatalogEntry: Equatable, Sendable, Identifiable {
    let repoID: MLXRepoID
    let displayName: String
    let approximateBytes: Int64
    let note: String
    let isRecommended: Bool
    var id: String { repoID.value }
}

/// A usable MLX model found in the Hugging Face cache (produced by `MLXCacheScanner`).
nonisolated struct MLXCachedModel: Equatable, Sendable, Identifiable {
    let repoID: MLXRepoID
    let snapshotURL: URL
    let sizeBytes: Int64
    let modelType: String
    let isInstruct: Bool
    var id: String { repoID.value }
}

/// One row of the Settings model list: a curated or cached model, downloaded or not.
nonisolated struct MLXModelOption: Equatable, Sendable, Identifiable {
    let repoID: MLXRepoID
    let displayName: String
    let sizeBytes: Int64
    let isDownloaded: Bool
    let isRecommended: Bool
    let note: String?
    var id: String { repoID.value }
}

/// The curated list and the rule that merges it with what the cache holds. A pure namespace: the
/// downloader publishes the cached models and the pane asks this type for the rows to show.
nonisolated enum MLXModelCatalog {
    static let instructNote = "Instruct model: base models complete text better."

    static let curated: [MLXCatalogEntry] = [
        MLXCatalogEntry(
            repoID: MLXRepoID("mlx-community/gemma-4-e4b-5bit")!,
            displayName: "Gemma 4 E4B (5-bit)",
            approximateBytes: 6_100_000_000,
            note: "Recommended. Same model family as the Open Source default.",
            isRecommended: true
        ),
        MLXCatalogEntry(
            repoID: MLXRepoID("mlx-community/gemma-4-e2b-6bit")!,
            displayName: "Gemma 4 E2B (6-bit)",
            approximateBytes: 4_700_000_000,
            note: "Smaller and faster.",
            isRecommended: false
        )
    ]

    /// Curated entries first, in catalog order, then every other cached model sorted by id.
    static func options(cached: [MLXCachedModel], curated: [MLXCatalogEntry] = curated) -> [MLXModelOption] {
        let cachedByID = Dictionary(cached.map { ($0.repoID, $0) }, uniquingKeysWith: { first, _ in first })
        let curatedIDs = Set(curated.map(\.repoID))
        let curatedRows = curated.map { entry in
            let hit = cachedByID[entry.repoID]
            return MLXModelOption(
                repoID: entry.repoID,
                displayName: entry.displayName,
                sizeBytes: hit?.sizeBytes ?? entry.approximateBytes,
                isDownloaded: hit != nil,
                isRecommended: entry.isRecommended,
                note: entry.note
            )
        }
        let otherRows = cached
            .filter { !curatedIDs.contains($0.repoID) }
            .sorted { $0.repoID.value.localizedCaseInsensitiveCompare($1.repoID.value) == .orderedAscending }
            .map { model in
                MLXModelOption(
                    repoID: model.repoID,
                    displayName: model.repoID.value,
                    sizeBytes: model.sizeBytes,
                    isDownloaded: true,
                    isRecommended: false,
                    note: model.isInstruct ? instructNote : nil
                )
            }
        return curatedRows + otherRows
    }

    /// The model to select when the user picks MLX without having chosen one: a downloaded
    /// curated model first, then any downloaded model, else nil (the pane then offers downloads).
    static func defaultSelection(cached: [MLXCachedModel]) -> MLXRepoID? {
        let cachedIDs = Set(cached.map(\.repoID))
        if let curatedHit = curated.first(where: { cachedIDs.contains($0.repoID) }) {
            return curatedHit.repoID
        }
        return cached.first?.repoID
    }
}

/// Why no MLX model is loaded although MLX is the selected engine.
nonisolated enum MLXUnavailableReason: Equatable, Sendable {
    case unsupportedHardware
    case noModel
    case modelNotDownloaded(MLXRepoID)
    /// The model is downloaded but `MLXModelCompatibility` rejected it; the string is the reason.
    case modelIncompatible(MLXRepoID, String)

    var message: String {
        switch self {
        case .unsupportedHardware: return "MLX needs a Mac with Apple Silicon."
        case .noModel: return "Choose an MLX model in Settings → Engine & Model."
        case .modelNotDownloaded(let id): return "Download \(id.value) in Settings → Engine & Model."
        case .modelIncompatible(let id, let reason): return "\(id.value) can't run on MLX: \(reason)"
        }
    }
}

/// The in-process MLX runtime's lifecycle as the router, Settings and the menu bar see it.
nonisolated enum MLXRuntimeState: Equatable, Sendable {
    case idle
    case unavailable(MLXUnavailableReason)
    case loading(modelID: String)
    case ready(modelID: String)
    case failed(reason: String)

    var summary: String {
        switch self {
        case .idle: return "Not loaded"
        case .unavailable(let reason): return reason.message
        case .loading(let modelID): return "Loading \(modelID)…"
        case .ready(let modelID): return "Running \(modelID)"
        case .failed(let reason): return reason
        }
    }

    /// Text for the Settings attention dot and callout. Nil while the model is loaded, loading, or
    /// simply not selected: none of those need the user to act.
    var problem: String? {
        switch self {
        case .unavailable(let reason): return reason.message
        case .failed(let reason): return reason
        case .idle, .loading, .ready: return nil
        }
    }

    /// The `.unavailable` message a suggestion request gets while the model is not ready.
    var notReadyMessage: String {
        switch self {
        case .loading(let modelID): return "MLX is loading \(modelID)…"
        case .unavailable(let reason): return reason.message
        case .failed(let reason): return "MLX stopped: \(reason)"
        case .idle: return "MLX is not running."
        case .ready: return "MLX is ready."
        }
    }

    var readyModelID: String? {
        if case .ready(let modelID) = self { return modelID }
        return nil
    }
}

/// Exactly what the runtime should hold in memory. Equality decides whether a loaded model must be
/// replaced.
nonisolated struct MLXRuntimeLoad: Equatable, Sendable {
    let modelID: String
    /// The model's snapshot directory in the Hugging Face cache.
    let directory: URL
    /// How much memory MLX may keep in its buffer cache between requests
    /// (`cotabbyMLXPromptCacheBytes`).
    let cacheLimitBytes: Int
}

/// What the resolver asks of the runtime: nothing, explain why not, or hold this model.
nonisolated enum MLXRuntimeDesire: Equatable, Sendable {
    /// MLX is not selected, or a prerequisite is still being checked.
    case stopped
    /// MLX is selected but cannot run; the reason is shown to the user.
    case unavailable(MLXUnavailableReason)
    case load(MLXRuntimeLoad)
}

/// One model download as the pane shows it.
nonisolated struct MLXDownloadState: Equatable, Sendable {
    let repoID: MLXRepoID
    /// 0...1 once the total size is known; nil before that.
    var fraction: Double?
    var failure: String?
    var isActive: Bool
}
