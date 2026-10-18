import Foundation

/// File overview:
/// The one rule that turns "what the user chose" plus "what this Mac has" into "which MLX model the
/// in-process runtime should hold". `CotabbyAppEnvironment` re-evaluates it whenever an input
/// publishes and hands the answer to `MLXRuntimeManager.apply(_:)`. Pure, so every combination is
/// pinned by a test. Unlike the server it replaces, nothing has to be installed: the runtime is
/// part of the app, so a downloaded, compatible model is all it needs.
nonisolated enum MLXRuntimeDesireResolver {
    static func desire(
        engine: SuggestionEngineKind,
        isAppleSilicon: Bool,
        modelID: String,
        cachedModels: [MLXCachedModel]?,
        cacheLimitBytes: Int,
        rejectedModels: [MLXRepoID: MLXModelCompatibility.Reason] = [:]
    ) -> MLXRuntimeDesire {
        guard engine == .mlx else { return .stopped }
        guard isAppleSilicon else { return .unavailable(.unsupportedHardware) }
        guard let repoID = MLXRepoID(modelID) else { return .unavailable(.noModel) }
        // The first cache scan has not finished: wait rather than claim the model is missing.
        guard let cachedModels else { return .stopped }
        guard let cached = cachedModels.first(where: { $0.repoID == repoID }) else {
            // Downloaded but turned away by the compatibility rule: say why, not "download it".
            if let reason = rejectedModels[repoID] {
                return .unavailable(.modelIncompatible(repoID, reason.message))
            }
            return .unavailable(.modelNotDownloaded(repoID))
        }
        return .load(MLXRuntimeLoad(modelID: repoID.value, directory: cached.snapshotURL, cacheLimitBytes: cacheLimitBytes))
    }
}
