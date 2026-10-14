import Combine
import Foundation

/// File overview:
/// Owns the second `mlx_lm.server` that Rewrite with MLX uses. Autocomplete's server keeps a base
/// model loaded; a rewrite needs an instruct (chat) model, and asking one server for another model
/// swaps weights and evicts the autocomplete model. So rewrites get their own server, started on
/// demand by the first rewrite and stopped after `idleTimeout` without one.
///
/// The controller is a thin policy layer over an `MLXServerManager` (the same state machine
/// autocomplete uses, given its own pid file). It decides *whether* the server should run with the
/// same pure `MLXServerDesireResolver`, serializes the manager's `apply` calls, waits for the
/// server to be ready, and runs the idle timer. Built once by `CotabbyAppEnvironment`; used by
/// `MLXRewriteProvider` and stopped by the environment and `AppDelegate`.
@MainActor
final class MLXRewriteServerController {
    typealias Sleep = (Duration) async throws -> Void

    /// A smaller prompt cache than autocomplete's 1 GiB: rewrites do not reuse long prefixes.
    static let promptCacheBytes = 512 << 20
    static let defaultIdleTimeout: Duration = .seconds(300)
    /// Load (up to 120 s in the manager) plus its warm-up, with a little slack.
    static let defaultReadyTimeout: Duration = .seconds(150)
    private static let pollInterval: Duration = .milliseconds(100)

    let manager: MLXServerManager
    private let toolchain: @MainActor () -> MLXToolchainState
    private let cachedModels: @MainActor () -> [MLXCachedModel]?
    private let rejectedModels: @MainActor () -> [MLXRepoID: MLXModelCompatibility.Reason]
    private let isAppleSilicon: Bool
    private let idleTimeout: Duration
    private let readyTimeout: Duration
    private let sleep: Sleep

    /// Tail of the apply chain. Each apply waits for the previous one and runs in its own
    /// unstructured task, so a cancelled rewrite never cancels a stop halfway through its 3 s
    /// SIGTERM grace (the same reason the autocomplete pipeline has `mlxApplyChain`).
    private var applyChain: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var isShutDown = false

    init(
        manager: MLXServerManager,
        toolchain: @escaping @MainActor () -> MLXToolchainState,
        cachedModels: @escaping @MainActor () -> [MLXCachedModel]?,
        rejectedModels: @escaping @MainActor () -> [MLXRepoID: MLXModelCompatibility.Reason],
        isAppleSilicon: Bool = MLXHardware.isAppleSilicon,
        idleTimeout: Duration = defaultIdleTimeout,
        readyTimeout: Duration = defaultReadyTimeout,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.manager = manager
        self.toolchain = toolchain
        self.cachedModels = cachedModels
        self.rejectedModels = rejectedModels
        self.isAppleSilicon = isAppleSilicon
        self.idleTimeout = idleTimeout
        self.readyTimeout = readyTimeout
        self.sleep = sleep
    }

    nonisolated deinit {}

    /// What the server should do for `modelID` right now. `.mlx` is passed as the engine because
    /// this server runs whenever a rewrite needs it, independent of the autocomplete engine.
    private func desire(modelID: String) -> MLXServerDesire {
        MLXServerDesireResolver.desire(
            engine: .mlx,
            isAppleSilicon: isAppleSilicon,
            toolchain: toolchain(),
            modelID: modelID,
            cachedModels: cachedModels(),
            promptCacheBytes: Self.promptCacheBytes,
            rejectedModels: rejectedModels()
        )
    }

    /// Whether a rewrite on `modelID` could start a server: the provider's `isAvailable`.
    func canRun(modelID: String) -> Bool {
        if case .running = desire(modelID: modelID) { return true }
        return false
    }

    /// Starts (or reuses) the server for `modelID` and returns its endpoint once it is ready.
    /// Throws `RewriteError.mlxUnavailable` with the reason when it cannot run, fails, or does not
    /// become ready in time. Nothing is launched when the resolver says it cannot run.
    func readyConfiguration(modelID: String) async throws -> OpenAICompatibleEndpointConfiguration {
        guard !isShutDown else { throw RewriteError.mlxUnavailable("Cotabby is quitting.") }
        let wanted = desire(modelID: modelID)
        switch wanted {
        case .unavailable(let reason):
            throw RewriteError.mlxUnavailable(reason.message)
        case .stopped:
            // The resolver holds back while the install or the first cache scan is in progress.
            throw RewriteError.mlxUnavailable("MLX is still being checked. Try again in a moment.")
        case .running:
            break
        }
        await enqueue(wanted)

        var waited: Duration = .zero
        while true {
            switch manager.state {
            case .ready(_, let readyModel) where readyModel == modelID:
                return try manager.readyConfiguration
            case .failed(let reason, _):
                throw RewriteError.mlxUnavailable("MLX stopped: \(reason)")
            case .unavailable(let reason):
                throw RewriteError.mlxUnavailable(reason.message)
            case .idle:
                throw RewriteError.mlxUnavailable("The MLX rewrite model was stopped.")
            case .starting, .stopping, .ready:
                break
            }
            guard waited < readyTimeout else {
                throw RewriteError.mlxUnavailable("The MLX rewrite model did not load in time.")
            }
            try await sleep(Self.pollInterval)
            waited += Self.pollInterval
        }
    }

    /// Marks a rewrite as using the server and restarts the idle countdown.
    func noteUse() {
        idleTask?.cancel()
        guard !isShutDown else { return }
        idleTask = Task { [weak self, sleep, idleTimeout] in
            guard (try? await sleep(idleTimeout)) != nil, !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    func stop() async {
        idleTask?.cancel()
        idleTask = nil
        await enqueue(.stopped)
    }

    /// Blocking stop for the app's termination path. `AppDelegate` prefers
    /// `MLXServerManager.shutdownSync(_:)` over both managers so their SIGTERMs share one wait;
    /// this form serves a caller holding only the controller.
    func shutdownSync(timeoutSeconds: TimeInterval = 3) {
        prepareForShutdown()
        manager.shutdownSync(timeoutSeconds: timeoutSeconds)
    }

    /// Cancels the idle timer and refuses further starts, so a rewrite racing the quit cannot
    /// relaunch the server after it was stopped.
    func prepareForShutdown() {
        isShutDown = true
        idleTask?.cancel()
        idleTask = nil
    }

    private func enqueue(_ desire: MLXServerDesire) async {
        let previous = applyChain
        let task = Task { [manager] in
            await previous?.value
            await manager.apply(desire)
        }
        applyChain = task
        await task.value
    }
}
