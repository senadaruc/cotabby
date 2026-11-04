import Foundation

/// File overview:
/// Runs one rewrite on the provider the user chose in Settings → Rewrite, and returns text ready to
/// replace the selection (`RewriteOutputCleaner`). "Same as autocomplete" is resolved here against
/// the current autocomplete engine (`RewriteProviderResolver`), so every decision (which provider
/// runs, what the disclosure names, whether memory may be used) is made on the concrete provider
/// that will run. The default never sends a rewrite off this Mac on its own: with autocomplete on an
/// endpoint on another host it resolves to the on-device fallback. The single place that maps the
/// preference to a provider, so the coordinator, the popup's disclosure and the Settings pane always
/// agree on where the text goes.
///
/// It is also the last guard for memory: when the destination sends text off this Mac (the API, or
/// a Local Endpoint on a LAN or public host) and the user has not allowed sending memory there, the
/// request's memory is dropped here, whatever the popup asked for, so a UI bug can never leak facts
/// off the Mac. Apple Intelligence, Open Source and MLX never leave the Mac.
/// Built by `CotabbyAppEnvironment`, used by `SelectionRewriteCoordinator` and the Rewrite pane.
@MainActor
final class RewriteEngine {
    private let appleIntelligence: RewriteProviding
    private let openSource: RewriteProviding
    private let localEndpoint: RewriteProviding
    private let mlx: RewriteProviding
    private let api: RewriteProviding
    private let autocompleteEngine: @MainActor () -> SuggestionEngineKind
    private let endpointHostScope: @MainActor () -> OpenAICompatibleHostScope?
    private let preferences: @MainActor () -> RewritePreferences

    init(
        appleIntelligence: RewriteProviding,
        openSource: RewriteProviding,
        localEndpoint: RewriteProviding,
        mlx: RewriteProviding,
        api: RewriteProviding,
        autocompleteEngine: @escaping @MainActor () -> SuggestionEngineKind,
        endpointHostScope: @escaping @MainActor () -> OpenAICompatibleHostScope?,
        preferences: @escaping @MainActor () -> RewritePreferences
    ) {
        self.appleIntelligence = appleIntelligence
        self.openSource = openSource
        self.localEndpoint = localEndpoint
        self.mlx = mlx
        self.api = api
        self.autocompleteEngine = autocompleteEngine
        self.endpointHostScope = endpointHostScope
        self.preferences = preferences
    }

    nonisolated deinit {}

    /// The concrete provider kind the current choice runs on; never `sameAsAutocomplete`. Read per
    /// rewrite rather than cached, so a change in Settings applies to the next one.
    var resolvedKind: RewriteProviderKind { resolve(preferences().provider) }

    /// True while "Same as autocomplete" runs on this Mac because autocomplete's endpoint is on
    /// another host. The Settings row and its note say so.
    var sameAsAutocompleteStaysOnDevice: Bool {
        RewriteProviderResolver.sameAsAutocompleteStaysOnDevice(
            autocompleteEngine: autocompleteEngine(), endpointHostScope: endpointHostScope())
    }

    private func resolve(_ kind: RewriteProviderKind) -> RewriteProviderKind {
        RewriteProviderResolver.resolve(
            kind,
            autocompleteEngine: autocompleteEngine(),
            endpointHostScope: endpointHostScope(),
            appleIntelligenceAvailable: appleIntelligence.isAvailable
        )
    }

    /// The provider for a kind (`sameAsAutocomplete` is resolved first). The Settings pane asks it
    /// for availability and the reason a row is disabled.
    func provider(for kind: RewriteProviderKind) -> RewriteProviding {
        switch resolve(kind) {
        case .appleIntelligence: return appleIntelligence
        case .openSource: return openSource
        case .localEndpoint: return localEndpoint
        case .mlx: return mlx
        case .api: return api
        case .sameAsAutocomplete: return openSource // unreachable: the resolver never returns it
        }
    }

    var activeProvider: RewriteProviding { provider(for: resolvedKind) }

    /// Resolves the current choice once, for a popup to disclose and then run every rewrite on.
    func destination() -> RewriteDestination {
        let kind = resolvedKind
        let provider = provider(for: kind)
        return RewriteDestination(
            kind: kind, sendsOffDevice: provider.sendsOffDevice, hostName: provider.hostName, endpointURL: provider.endpointURL)
    }

    /// Whether memory may be part of a rewrite with the current provider.
    var memoryAllowed: Bool { memoryAllowed(for: destination()) }

    /// Whether memory may be part of a rewrite on `destination`: always for the providers on this
    /// Mac, and for the API or an off-device endpoint only when the user allowed it.
    func memoryAllowed(for destination: RewriteDestination) -> Bool {
        switch destination.kind {
        case .appleIntelligence, .openSource, .mlx: return true
        case .localEndpoint: return !destination.sendsOffDevice || preferences().sendsMemoryToAPI
        case .api, .sameAsAutocomplete: return preferences().sendsMemoryToAPI
        }
    }

    /// Rewrites on the current choice (resolved now).
    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        try await rewrite(request, to: destination(), onPartial: onPartial)
    }

    /// Rewrites on `destination`, the one a popup resolved and disclosed. If its provider would now
    /// send the text somewhere else (the endpoint's URL, port included, was edited meanwhile), nothing
    /// is sent.
    func rewrite(
        _ request: RewriteRequest,
        to destination: RewriteDestination,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard request.selection.count <= SelectionRewriteEligibility.maximumCharacters else { throw RewriteError.selectionTooLong }
        let provider = provider(for: destination.kind)
        // The whole URL, not just the host: another port or path on the same machine is another server.
        guard provider.sendsOffDevice == destination.sendsOffDevice, provider.hostName == destination.hostName,
              provider.endpointURL == destination.endpointURL else {
            throw RewriteError.destinationChanged
        }
        guard provider.isAvailable else {
            if let reason = provider.unavailableReason { throw RewriteError.unavailable(reason) }
            throw RewriteError.noProvider
        }
        var safeRequest = request
        // Only the memory is dropped; the tone a refinement keeps, the language and the tick box stay.
        if !memoryAllowed(for: destination) { safeRequest.memory = .empty }
        let raw = try await provider.rewrite(safeRequest, onPartial: onPartial)
        guard let cleaned = RewriteOutputCleaner.clean(raw, selection: request.selection, action: request.action) else {
            throw RewriteError.unusableOutput
        }
        return cleaned
    }
}
