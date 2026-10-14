import Foundation

/// File overview:
/// Runs one rewrite on the provider the user chose in Settings → Rewrite, and returns text ready to
/// replace the selection (`RewriteOutputCleaner`). It is also the last guard for memory: when the
/// provider is the API and the user has not allowed sending memory there, the request's memory is
/// dropped here, whatever the popup asked for, so a UI bug can never leak facts off the Mac.
/// Built by `CotabbyAppEnvironment`, used by `SelectionRewriteCoordinator`.
@MainActor
final class RewriteEngine {
    private let local: RewriteProviding
    private let api: RewriteProviding
    private let mlx: RewriteProviding
    private let preferences: @MainActor () -> RewritePreferences

    init(local: RewriteProviding, api: RewriteProviding, mlx: RewriteProviding, preferences: @escaping @MainActor () -> RewritePreferences) {
        self.local = local
        self.api = api
        self.mlx = mlx
        self.preferences = preferences
    }

    nonisolated deinit {}

    var activeProvider: RewriteProviding {
        switch preferences().provider {
        case .local: return local
        case .api: return api
        case .mlx: return mlx
        }
    }

    /// Whether memory may be part of a rewrite with the current provider.
    var memoryAllowed: Bool {
        let prefs = preferences()
        // MLX runs on this Mac like the other local models, so memory never leaves it.
        return prefs.provider != .api || prefs.sendsMemoryToAPI
    }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard request.selection.count <= SelectionRewriteEligibility.maximumCharacters else { throw RewriteError.selectionTooLong }
        let provider = activeProvider
        guard provider.isAvailable else { throw RewriteError.noProvider }
        var safeRequest = request
        if !memoryAllowed {
            safeRequest = RewriteRequest(selection: request.selection, action: request.action, memory: .empty)
            safeRequest.language = request.language
        }
        let raw = try await provider.rewrite(safeRequest, onPartial: onPartial)
        guard let cleaned = RewriteOutputCleaner.clean(raw, selection: request.selection, action: request.action) else {
            throw RewriteError.unusableOutput
        }
        return cleaned
    }
}
