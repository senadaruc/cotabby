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
