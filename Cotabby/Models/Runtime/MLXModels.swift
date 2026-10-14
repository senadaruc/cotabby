import Foundation

/// File overview:
/// Shared values for the MLX engine: what this Mac can run, where Cotabby keeps its MLX install,
/// which models it offers, and the states the toolchain, server and downloads publish. Settings,
/// the router and the MLX services all read these, so they live in `Models/` rather than inside
/// any one service.

/// Whether this build can run MLX. MLX needs Apple Silicon. A compile-time check is enough: an
/// x86_64 Cotabby (Intel, or Rosetta) cannot rely on an arm64 Python stack being usable either.
nonisolated enum MLXHardware {
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()
}

/// The sampling fields `mlx_lm.server` accepts beyond OpenAI's basics. The MLX engine fills them
/// from the same request values the llama runtime samples with, so both local engines condition
/// alike. The client encodes them only when present, so hosted endpoints never see keys they
/// might reject.
nonisolated struct MLXCompletionOptions: Equatable, Sendable {
    let topK: Int
    let minP: Double
    let repetitionPenalty: Double
    /// Nil lets the server pick; Cotabby passes the request's seed so a replay is reproducible.
    let seed: Int?
    /// Server-side stop strings. `["\n"]` for single-line fields stands in for the llama runtime's
    /// newline-token masking; empty for multi-line fields.
    let stop: [String]
}
