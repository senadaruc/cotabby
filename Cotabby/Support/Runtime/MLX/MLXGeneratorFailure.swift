import Foundation

/// File overview:
/// Decides whether a failed request to Cotabby's own loopback `mlx_lm.server` means its generator
/// died. mlx_lm turns a dead generation thread into HTTP 404 (`{"error": "generation thread
/// died"}`) while the process and `/v1/models` stay up, so process-exit monitoring never notices.
/// Cotabby's server only answers 404 or 500 to a completion when generation itself failed, which is
/// why those codes count here and would not for a user's remote endpoint. Shared by the autocomplete
/// engine and the rewrite provider so both classify the same way.
nonisolated enum MLXGeneratorFailure {
    /// A short reason when `error` shows the generator is gone, otherwise nil.
    static func reason(for error: Error) -> String? {
        guard let clientError = error as? OpenAICompatibleClientError else { return nil }
        switch clientError {
        case .server(let statusCode) where statusCode == 404 || statusCode == 500:
            return "HTTP \(statusCode)"
        case .streamError(let message) where message.contains("generation thread died"):
            return "generation thread died"
        default:
            return nil
        }
    }
}
