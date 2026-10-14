import Foundation

/// File overview:
/// Runs one rewrite on the provider the user chose in Settings → Rewrite, and returns text ready to
/// replace the selection (`RewriteOutputCleaner`). "Same as autocomplete" is resolved here against
/// the current autocomplete engine (`RewriteProviderResolver`), so every decision below (which
/// provider, whether memory may be used) is made on the concrete provider that will run.
///
/// It is also the last guard for memory: when the resolved provider sends text off this Mac (the
/// API, or a Local Endpoint on a LAN or public host) and the user has not allowed sending memory
/// there, the request's memory is dropped here, whatever the popup asked for, so a UI bug can never
/// leak facts off the Mac. Apple Intelligence, Open Source and MLX never leave the Mac.
/// Built by `CotabbyAppEnvironment`, used by `SelectionRewriteCoordinator` and the Rewrite pane.
@MainActor
final class RewriteEngine {
    private let appleIntelligence: RewriteProviding
    private let openSource: RewriteProviding
    private let localEndpoint: RewriteProviding
    private let mlx: RewriteProviding
    private let api: RewriteProviding
    private let autocompleteEngine: @MainActor () -> SuggestionEngineKind
    private let preferences: @MainActor () -> RewritePreferences

    init(
        appleIntelligence: RewriteProviding,
        openSource: RewriteProviding,
        localEndpoint: RewriteProviding,
        mlx: RewriteProviding,
        api: RewriteProviding,
        autocompleteEngine: @escaping @MainActor () -> SuggestionEngineKind,
        preferences: @escaping @MainActor () -> RewritePreferences
    ) {
        self.appleIntelligence = appleIntelligence
        self.openSource = openSource
        self.localEndpoint = localEndpoint
        self.mlx = mlx
        self.api = api
        self.autocompleteEngine = autocompleteEngine
        self.preferences = preferences
    }

    nonisolated deinit {}

    /// The concrete provider kind the current choice runs on; never `sameAsAutocomplete`.
    var resolvedKind: RewriteProviderKind {
        RewriteProviderResolver.resolve(preferences().provider, autocompleteEngine: autocompleteEngine())
    }

    /// The provider for a concrete kind (`sameAsAutocomplete` is resolved first). The Settings pane
    /// asks it for availability and the reason a row is disabled.
    func provider(for kind: RewriteProviderKind) -> RewriteProviding {
        switch RewriteProviderResolver.resolve(kind, autocompleteEngine: autocompleteEngine()) {
        case .appleIntelligence: return appleIntelligence
        case .openSource: return openSource
        case .localEndpoint: return localEndpoint
        case .mlx: return mlx
        case .api: return api
        case .sameAsAutocomplete: return openSource // unreachable: the resolver never returns it
        }
    }

    var activeProvider: RewriteProviding { provider(for: resolvedKind) }

    /// Whether memory may be part of a rewrite with the current provider: always for the providers
    /// on this Mac, and for the API or an off-device endpoint only when the user allowed it.
    var memoryAllowed: Bool {
        switch resolvedKind {
        case .appleIntelligence, .openSource, .mlx: return true
        case .localEndpoint: return !localEndpoint.sendsOffDevice || preferences().sendsMemoryToAPI
        case .api, .sameAsAutocomplete: return preferences().sendsMemoryToAPI
        }
    }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard request.selection.count <= SelectionRewriteEligibility.maximumCharacters else { throw RewriteError.selectionTooLong }
        let provider = activeProvider
        guard provider.isAvailable else {
            if let reason = provider.unavailableReason { throw RewriteError.mlxUnavailable(reason) }
            throw RewriteError.noProvider
        }
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
