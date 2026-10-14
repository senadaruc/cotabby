import Combine
import Darwin
import Foundation
import Logging

/// File overview:
/// Owns Cotabby's `mlx_lm.server` child process. It launches the server on a free loopback port,
/// waits until the model is loaded, restarts it with backoff after a crash, stops it
/// (SIGTERM, then SIGKILL after 3 s), and cleans up a server orphaned by an earlier crash of
/// Cotabby. It publishes one `MLXServerState` that Settings and the router read.
///
/// Owned by `CotabbyAppEnvironment` for the app's lifetime. It never decides *whether* MLX should
/// run; `MLXServerDesireResolver` does, and the environment calls `apply(_:)` with the answer.
/// The process, readiness probe, port, clock and sleep are injected so the whole lifecycle is
/// testable without Python.
///
/// Concurrency: everything runs on the main actor. Every launch bumps `generation`, and so does
/// every intended stop. A readiness answer, exit callback or restart timer that belongs to an
/// older generation is ignored, which is what keeps a slow probe from reviving a stopped server.

/// Why the server could not be started or kept ready. Its `errorDescription` is what the user sees
/// in the Settings callout, so each message says what happened, not how the code failed.
nonisolated enum MLXServerError: LocalizedError, Equatable {
    case noFreePort
    case readinessTimedOut
    case warmUpFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .noFreePort: return "No free local port for MLX."
        case .readinessTimedOut: return "The model did not load within 2 minutes."
        case .warmUpFailed(let code): return "The first test completion failed (HTTP \(code))."
        }
    }
}

/// The pid of the server Cotabby launched, kept on disk so the next launch can find a server
/// orphaned when Cotabby crashed or was force-quit.
nonisolated struct MLXServerPIDFile {
    let url: URL

    func write(pid: Int32) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(pid)\n".utf8).write(to: url, options: .atomic)
    }

    func read() -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Asks the kernel for a free loopback port by binding 127.0.0.1:0, then releases it for the
/// server. Another process could take it in between; the server then fails to bind, exits, and
/// the restart picks a new port.
nonisolated enum MLXLoopbackPort {
    static func next() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw MLXServerError.noFreePort }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        guard bound == 0 else { throw MLXServerError.noFreePort }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else { throw MLXServerError.noFreePort }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Reads another process's state through BSD calls; used only for orphan cleanup. A caseless enum
/// because it holds no state: each call is one `kill` or `sysctl` probe of a pid.
nonisolated enum MLXProcessInspector {
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// The process's argv via `sysctl(KERN_PROCARGS2)`; nil if it exited or is not ours to read.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return MLXToolchainRules.parseProcArgs(Array(buffer.prefix(size)))
    }

    /// True when `pid` has a TCP socket whose local port is `port`. libproc lists a process's file
    /// descriptors; each socket descriptor is then asked for its details. Kernel ports come back in
    /// network byte order, so they are swapped before comparing.
    static func ownsTCPSocket(pid: Int32, port: Int) -> Bool {
        // First call sizes the list, second call fills it. The fd count can change in between, so
        // only the entries the second call reports are read.
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return false }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(), count: Int(listSize) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, listSize)
        guard filled > 0 else { return false }
        let count = Int(filled) / MemoryLayout<proc_fdinfo>.stride
        for descriptor in descriptors.prefix(count) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            // A descriptor can close between the list and this call; a short read means no answer.
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP
            else { continue }
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if localPort == port { return true }
        }
        return false
    }
}

/// The state machine around one `mlx_lm.server` child. It is owned by `CotabbyAppEnvironment` (one
/// per app) and collaborates with the resolver (what to run), the launcher and probe (how to run
/// and check it, injected so tests use fakes), and the pid file (orphan recovery). Views and the
/// router only read its published `state`.
@MainActor
final class MLXServerManager: ObservableObject {
    typealias Sleep = (Duration) async throws -> Void

    static let restartBackoff: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]
    static let failureWindow: TimeInterval = 120
    static let failureLimit = 3
    static let readinessTimeout: Duration = .seconds(120)
    static let stopGrace: Duration = .seconds(3)
    private static let stopPoll: Duration = .milliseconds(100)

    @Published private(set) var state: MLXServerState = .idle

    private struct RunningServer {
        let launch: MLXServerLaunch
        let port: Int
        let process: any MLXRunningProcess
    }

    private let launcher: any MLXProcessLaunching
    private let probe: any MLXReadinessProbing
    private let pickPort: () throws -> Int
    private let sleep: Sleep
    private let now: () -> Date
    private let pidFile: MLXServerPIDFile
    private let baseEnvironment: [String: String]
    /// Answers "does this pid own a TCP socket on this port?" before `.ready` is published. The
    /// port was only probed, not reserved, so another local program may have taken it.
    private let verifyListener: (Int32, Int) -> Bool

    private var desired: MLXServerDesire = .stopped
    private var current: RunningServer?
    /// The process a stop is waiting on right now (inside its SIGTERM grace). `current` is already
    /// nil by then, so `shutdownSync` needs this reference to still reach it.
    private var stoppingProcess: (any MLXRunningProcess)?
    private var generation: UInt64 = 0
    private var readinessTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    /// Failure times inside the two-minute window (decides `failed`).
    private var recentFailures: [Date] = []
    /// Failures since the last time the server became ready (decides the backoff step).
    private var consecutiveFailures = 0

    init(
        paths: MLXPaths,
        launcher: any MLXProcessLaunching,
        probe: any MLXReadinessProbing,
        pickPort: @escaping () throws -> Int = MLXLoopbackPort.next,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        verifyListener: @escaping (Int32, Int) -> Bool = MLXProcessInspector.ownsTCPSocket(pid:port:)
    ) {
        self.launcher = launcher
        self.probe = probe
        self.pickPort = pickPort
        self.sleep = sleep
        self.now = now
        self.pidFile = MLXServerPIDFile(url: paths.serverPIDFile)
        self.baseEnvironment = baseEnvironment
        self.verifyListener = verifyListener
    }

    static func live(paths: MLXPaths) -> MLXServerManager {
        MLXServerManager(paths: paths, launcher: MLXLiveProcessLauncher(), probe: MLXHTTPReadinessProbe())
    }

    /// The endpoint the MLX engine instance talks to. Only a ready server yields one; otherwise
    /// the reason surfaces as the request's `.unavailable` message (no fallback engine).
    var readyConfiguration: OpenAICompatibleEndpointConfiguration {
        get throws {
            guard case .ready(let port, let modelID) = state else {
                throw SuggestionClientError.unavailable(state.notReadyMessage)
            }
            return try OpenAICompatibleEndpointConfiguration(
                baseURLString: "http://127.0.0.1:\(port)/v1",
                modelName: modelID,
                apiMode: .completions
            )
        }
    }

    /// Moves toward `desire`. Idempotent: the same desire again changes nothing (a failed server
    /// stays failed until `retry()` or a different desire).
    func apply(_ desire: MLXServerDesire) async {
        guard desire != desired else { return }
        desired = desire
        recentFailures = []
        consecutiveFailures = 0
        await stopCurrent()
        // Another apply may have arrived while the old server was stopping; the newest wins.
        guard desired == desire else { return }
        switch desire {
        case .stopped:
            state = .idle
        case .unavailable(let reason):
            state = .unavailable(reason)
        case .running(let launch):
            start(launch)
        }
    }

    func retry() async {
        guard case .running(let launch) = desired else { return }
        recentFailures = []
        consecutiveFailures = 0
        await stopCurrent()
        guard desired == .running(launch) else { return }
        start(launch)
    }

    /// Blocking stop for `applicationWillTerminate`, where no run loop turn is left for `async`.
    func shutdownSync(timeoutSeconds: TimeInterval = 3) {
        generation &+= 1
        readinessTask?.cancel()
        restartTask?.cancel()
        desired = .stopped
        defer {
            pidFile.remove()
            state = .idle
        }
        // A server already being stopped has had its SIGTERM sent; it only needs the wait and the
        // SIGKILL fallback, so it is not terminated a second time.
        let stopping = stoppingProcess
        let running = current?.process
        current = nil
        running?.terminate()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while [running, stopping].contains(where: { $0?.isRunning == true }), Date() < deadline {
            usleep(50_000)
        }
        for process in [running, stopping] {
            if let process, process.isRunning { process.forceKill() }
        }
    }

    /// Terminates a server left running by an earlier Cotabby that crashed or was force-quit.
    /// Only a process whose live command line is our loopback `mlx_lm.server` is signalled, so a
    /// reused pid never kills an unrelated program.
    func cleanUpOrphan(
        isAlive: @escaping (Int32) -> Bool = MLXProcessInspector.isAlive,
        arguments: @escaping (Int32) -> [String]? = MLXProcessInspector.arguments(of:),
        signal: @escaping (Int32, Int32) -> Void = { pid, signal in _ = kill(pid, signal) }
    ) async {
        guard let pid = pidFile.read() else { return }
        // The file names the live server when one is running; that record belongs to it, not to an orphan.
        guard current?.process.processIdentifier != pid else { return }
        pidFile.remove()
        guard isAlive(pid),
              let processArguments = arguments(pid),
              MLXToolchainRules.isOurServer(arguments: processArguments)
        else { return }
        CotabbyLogger.runtime.warning("Stopping an MLX server left by an earlier Cotabby run", metadata: ["pid": .stringConvertible(pid)])
        signal(pid, SIGTERM)
        var waited: Duration = .zero
        while isAlive(pid), waited < Self.stopGrace {
            try? await sleep(Self.stopPoll)
            waited += Self.stopPoll
        }
        if isAlive(pid) { signal(pid, SIGKILL) }
    }

    // MARK: - Lifecycle

    private func start(_ launch: MLXServerLaunch) {
        generation &+= 1
        let launchGeneration = generation
        state = .starting(modelID: launch.modelID)
        let port: Int
        let process: any MLXRunningProcess
        do {
            port = try pickPort()
            process = try launcher.launch(
                executable: launch.executable,
                arguments: MLXToolchainRules.serverArguments(
                    modelID: launch.modelID, port: port, promptCacheBytes: launch.promptCacheBytes),
                environment: MLXToolchainRules.serverEnvironment(base: baseEnvironment),
                onExit: { [weak self] status in
                    self?.processExited(generation: launchGeneration, status: status)
                }
            )
        } catch {
            recordFailure(launch, reason: "MLX could not start: \(error.localizedDescription)", logTail: [])
            return
        }
        current = RunningServer(launch: launch, port: port, process: process)
        pidFile.write(pid: process.processIdentifier)
        CotabbyLogger.runtime.info("MLX server launched", metadata: [
            "model": .string(launch.modelID),
            "port": .stringConvertible(port),
            "pid": .stringConvertible(process.processIdentifier),
            "prompt_cache_bytes": .stringConvertible(launch.promptCacheBytes)
        ])
        let startedAt = now()
        readinessTask = Task { [weak self, probe] in
            do {
                try await probe.waitUntilReady(port: port, modelID: launch.modelID, timeout: Self.readinessTimeout)
                // A crash or stop can land while the probe is suspended. Its exit clears `current`
                // without bumping `generation`, so the identity check is what stops a dead server
                // from being published as ready.
                guard let self, self.generation == launchGeneration, !Task.isCancelled,
                      self.current?.process === process else { return }
                guard self.verifyListener(process.processIdentifier, port) else {
                    await self.failCurrent(
                        generation: launchGeneration,
                        reason: "Another program answered on MLX's port."
                    )
                    return
                }
                self.consecutiveFailures = 0
                self.state = .ready(port: port, modelID: launch.modelID)
                CotabbyLogger.runtime.info("MLX server ready", metadata: [
                    "model": .string(launch.modelID),
                    "ready_ms": .stringConvertible(Int(self.now().timeIntervalSince(startedAt) * 1000))
                ])
            } catch {
                guard let self, self.generation == launchGeneration, !(error is CancellationError) else { return }
                await self.failCurrent(
                    generation: launchGeneration,
                    reason: "MLX did not become ready: \(error.localizedDescription)"
                )
            }
        }
    }

    /// An exit nobody asked for. Intended stops bump `generation` or clear `current` first, so
    /// their exits land here and are ignored.
    private func processExited(generation exitGeneration: UInt64, status: Int32) {
        guard exitGeneration == generation, let running = current else { return }
        current = nil
        readinessTask?.cancel()
        readinessTask = nil
        pidFile.remove()
        CotabbyLogger.runtime.error("MLX server exited", metadata: ["status": .stringConvertible(status)])
        recordFailure(running.launch, reason: "MLX stopped unexpectedly (exit status \(status)).",
                      logTail: running.process.stderrTail())
    }

    /// Readiness failed: the process is still up but useless. Kill it, then count a failure.
    private func failCurrent(generation failedGeneration: UInt64, reason: String) async {
        guard let running = current else { return }
        let tail = running.process.stderrTail()
        current = nil
        await terminateTracked(running.process)
        removePIDFile(ownedBy: running.process.processIdentifier)
        guard generation == failedGeneration, desired == .running(running.launch) else { return }
        recordFailure(running.launch, reason: reason, logTail: tail)
    }

    private func recordFailure(_ launch: MLXServerLaunch, reason: String, logTail: [String]) {
        let at = now()
        recentFailures = recentFailures.filter { at.timeIntervalSince($0) < Self.failureWindow } + [at]
        consecutiveFailures += 1
        CotabbyLogger.runtime.error("MLX server failure", metadata: [
            "reason": .string(reason),
            "failures_in_window": .stringConvertible(recentFailures.count)
        ])
        guard recentFailures.count < Self.failureLimit else {
            generation &+= 1
            state = .failed(reason: reason, logTail: logTail)
            return
        }
        let delay = Self.restartBackoff[min(consecutiveFailures - 1, Self.restartBackoff.count - 1)]
        let restartGeneration = generation
        state = .starting(modelID: launch.modelID)
        restartTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            guard self.generation == restartGeneration, self.desired == .running(launch) else { return }
            self.restartTask = nil
            self.start(launch)
        }
    }

    /// Stops whatever runs now. Bumping `generation` first invalidates any pending readiness,
    /// restart or exit callback that belongs to it.
    private func stopCurrent() async {
        generation &+= 1
        readinessTask?.cancel()
        readinessTask = nil
        restartTask?.cancel()
        restartTask = nil
        guard let running = current else {
            pidFile.remove()
            return
        }
        current = nil
        state = .stopping
        await terminateTracked(running.process)
        removePIDFile(ownedBy: running.process.processIdentifier)
        CotabbyLogger.runtime.info("MLX server stopped", metadata: ["model": .string(running.launch.modelID)])
    }

    /// Runs `terminate` while keeping the process visible to `shutdownSync`.
    private func terminateTracked(_ process: any MLXRunningProcess) async {
        stoppingProcess = process
        await Self.terminate(process, sleep: sleep)
        if stoppingProcess === process { stoppingProcess = nil }
    }

    /// Removes the pid file only while it still names `pid`. A stop waits up to 3 s, and a newer
    /// `start` may have written its own pid into the same file during that wait.
    private func removePIDFile(ownedBy pid: Int32) {
        if pidFile.read() == pid { pidFile.remove() }
    }

    private static func terminate(_ process: any MLXRunningProcess, sleep: Sleep) async {
        process.terminate()
        var waited: Duration = .zero
        while process.isRunning, waited < stopGrace {
            try? await sleep(stopPoll)
            waited += stopPoll
        }
        if process.isRunning { process.forceKill() }
    }
}

// MARK: - Live process and probe

/// Starts the real `mlx_lm.server` with stdout discarded and the stderr tail kept for errors.
final class MLXLiveProcessLauncher: MLXProcessLaunching {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any MLXRunningProcess {
        // The exit arrives on a background thread; hop to the main actor for the manager.
        let (process, output) = Self.configuredProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            onExit: { @Sendable status in
                Task { @MainActor in onExit(status) }
            }
        )
        try process.run()
        return MLXLiveRunningProcess(process: process, output: output)
    }

    /// Builds the process outside the main actor. Its handlers run on background threads, and
    /// with the target's default MainActor isolation a closure formed in a main-actor method could
    /// be inferred main-actor-isolated and trip Swift's runtime isolation check there.
    nonisolated private static func configuredProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> (Process, MLXOutputCollector) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let output = MLXOutputCollector(tailLines: 20)
        // At EOF the handler is called with empty data, and it keeps being called until it is removed.
        // Removing it there and recording the close matches `MLXProcessRunner`.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                output.markStderrClosed()
            } else {
                output.appendStderr(data)
            }
        }
        process.terminationHandler = { finished in onExit(finished.terminationStatus) }
        return (process, output)
    }
}

/// Adapts a Foundation `Process` to `MLXRunningProcess`. It is created by
/// `MLXLiveProcessLauncher` and owned by the manager's `RunningServer`; it lives exactly as long as
/// that launch. It holds the stderr collector so the failure message can quote the server's last
/// lines even after the process has exited.
final class MLXLiveRunningProcess: MLXRunningProcess {
    private let process: Process
    private let output: MLXOutputCollector

    init(process: Process, output: MLXOutputCollector) {
        self.process = process
        self.output = output
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func stderrTail() -> [String] { output.stderrTail }
}

/// Polls `/v1/models` every 250 ms, then sends one 2-token completion for the exact model id so
/// the weights load now, not on the user's first keystroke (about 6 s for Gemma 4 E4B).
nonisolated struct MLXHTTPReadinessProbe: MLXReadinessProbing {
    func waitUntilReady(port: Int, modelID: String, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        let base = URL(string: "http://127.0.0.1:\(port)/v1")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        while true {
            try Task.checkCancellation()
            if let (_, response) = try? await session.data(from: base.appendingPathComponent("models")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                break
            }
            guard ContinuousClock.now < deadline else { throw MLXServerError.readinessTimedOut }
            try await Task.sleep(for: .milliseconds(250))
        }

        var request = URLRequest(url: base.appendingPathComponent("completions"))
        request.timeoutInterval = max(5, Double((deadline - ContinuousClock.now).components.seconds))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID, "prompt": "Hello", "max_tokens": 2, "stream": false
        ])
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MLXServerError.warmUpFailed(statusCode: status) }
    }
}

extension OpenAICompatibleSuggestionEngine {
    /// The MLX engine: the shared OpenAI-compatible client pointed at Cotabby's own server. The
    /// configuration is read per request, so a request made while the server is loading or
    /// failed throws `.unavailable` with the reason at once: no HTTP, and no fallback engine.
    static func mlx(client: OpenAICompatibleAPIClient, serverManager: MLXServerManager) -> OpenAICompatibleSuggestionEngine {
        OpenAICompatibleSuggestionEngine(
            client: client,
            configurationProvider: { [weak serverManager] in
                guard let serverManager else {
                    throw SuggestionClientError.unavailable("MLX is not running.")
                }
                return try serverManager.readyConfiguration
            },
            apiKeyProvider: { nil },
            backend: .mlx
        )
    }
}
