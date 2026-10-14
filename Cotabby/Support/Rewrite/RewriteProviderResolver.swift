import Foundation

/// File overview:
/// Turns the user's Rewrite Model choice into the concrete provider that will run. Pure and
/// stateless so the one interesting rule, "Same as autocomplete" follows the autocomplete engine,
/// is testable without engines, settings or MainActor state. Used by `RewriteEngine` (which
/// provider runs, what memory policy applies) and the Rewrite settings pane (which row is shown as
/// active).
nonisolated enum RewriteProviderResolver {
    /// `sameAsAutocomplete` maps each autocomplete engine to the rewrite provider that reuses its
    /// model; every other choice is returned unchanged. The result is never `sameAsAutocomplete`.
    static func resolve(_ kind: RewriteProviderKind, autocompleteEngine: SuggestionEngineKind) -> RewriteProviderKind {
        guard kind == .sameAsAutocomplete else { return kind }
        switch autocompleteEngine {
        case .appleIntelligence: return .appleIntelligence
        case .llamaOpenSource: return .openSource
        case .openAICompatible: return .localEndpoint
        case .mlx: return .mlx
        }
    }
}
