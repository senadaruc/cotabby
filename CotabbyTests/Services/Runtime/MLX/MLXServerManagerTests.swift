import XCTest
@testable import Cotabby

@MainActor
final class MLXServerManagerTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private var root: URL!
    private var paths: MLXPaths!
    private var launcher: MLXFakeLauncher!
    private var probe: MLXFakeProbe!
    private var sleeps: [Duration] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private let launchA = MLXServerLaunch(
        executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"), modelID: "mlx-community/a", promptCacheBytes: 1 << 30)
    private let launchB = MLXServerLaunch(
        executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"), modelID: "mlx-community/b", promptCacheBytes: 1 << 30)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-server-\(UUID().uuidString)")
        paths = MLXPaths(root: root)
        launcher = MLXFakeLauncher()
        probe = MLXFakeProbe()
        sleeps = []
        Self.retained.append(contentsOf: [launcher!, probe!] as [AnyObject])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeManager() -> MLXServerManager {
        let manager = MLXServerManager(
            paths: paths,
            launcher: launcher,
            probe: probe,
            pickPort: { 50123 },
            sleep: { [unowned self] duration in
                self.sleeps.append(duration)
                await Task.yield()
            },
            now: { [unowned self] in self.clock },
            baseEnvironment: ["HOME": "/Users/u", "PYTHONPATH": "/evil"]
        )
        Self.retained.append(manager)
        return manager
    }

    private func isReady(_ manager: MLXServerManager) -> Bool {
        if case .ready = manager.state { return true }
        return false
    }

    private func startReady(_ manager: MLXServerManager, _ launch: MLXServerLaunch) async {
        await manager.apply(.running(launch))
        await waitUntil { self.probe.waiting >= 1 }
        probe.succeedNext()
        await waitUntil { self.isReady(manager) }
    }

    func test_startLaunchesTheExactCommandAndBecomesReady() async throws {
        let manager = makeManager()
        await manager.apply(.running(launchA))
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"))
        let launch = try XCTUnwrap(launcher.launches.first)
        XCTAssertEqual(launch.executable.path, "/mlx/bin/mlx_lm.server")
        XCTAssertEqual(launch.arguments, MLXToolchainRules.serverArguments(
            modelID: "mlx-community/a", port: 50123, promptCacheBytes: 1 << 30))
        XCTAssertEqual(launch.environment["HF_HUB_OFFLINE"], "1")
        XCTAssertNil(launch.environment["PYTHONPATH"])
        XCTAssertEqual(MLXServerPIDFile(url: paths.serverPIDFile).read(), 1000)

        XCTAssertThrowsError(try manager.readyConfiguration) { error in
            XCTAssertEqual(error.localizedDescription, "MLX is loading mlx-community/a…")
        }
        await waitUntil { self.probe.waiting == 1 }
        probe.succeedNext()
        await waitUntil { manager.state == .ready(port: 50123, modelID: "mlx-community/a") }
        let configuration = try manager.readyConfiguration
        XCTAssertEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:50123/v1")
        XCTAssertEqual(configuration.modelName, "mlx-community/a")
        XCTAssertEqual(configuration.apiMode, .completions)
    }

    func test_sameDesireAgainDoesNotRelaunch() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        await manager.apply(.running(launchA))
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func test_modelChangeStopsTheOldServerAndStartsTheNew() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        await manager.apply(.running(launchB))
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/b"))
    }

    func test_stopSendsTermThenKillAfterTheGracePeriod() async {
        launcher.exitsOnTerminate = false
        let manager = makeManager()
        await startReady(manager, launchA)
        await manager.apply(.stopped)
        let process = launcher.launches[0].process
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertEqual(sleeps, Array(repeating: .milliseconds(100), count: 30))
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(MLXServerPIDFile(url: paths.serverPIDFile).read())
    }

    func test_aCooperativeServerIsNotKilled() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        await manager.apply(.stopped)
        XCTAssertEqual(launcher.launches[0].process.killCount, 0)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func test_crashesRestartWithBackoffAndTheThirdWithinTwoMinutesFails() async {
        let manager = makeManager()
        await startReady(manager, launchA)

        launcher.crash(0)
        await waitUntil { self.launcher.launches.count == 2 }
        XCTAssertEqual(sleeps, [.seconds(1)])

        clock += 10
        launcher.crash(1)
        await waitUntil { self.launcher.launches.count == 3 }
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(5)])

        clock += 10
        launcher.launches[2].process.tail = ["Traceback", "boom"]
        launcher.crash(2)
        await waitUntil { if case .failed = manager.state { return true } else { return false } }
        XCTAssertEqual(manager.state, .failed(reason: "MLX stopped unexpectedly (exit status 1).",
                                              logTail: ["Traceback", "boom"]))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(launcher.launches.count, 3, "no restarts after failing")
    }

    func test_failuresSpreadOverMoreThanTwoMinutesKeepRestarting() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        for index in 0..<4 {
            clock += 121
            launcher.crash(index)
            await waitUntil { self.launcher.launches.count == index + 2 }
        }
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(5), .seconds(30), .seconds(30)])
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"))
    }

    func test_retryAfterFailureStartsAgain() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        for index in 0..<3 {
            launcher.crash(index)
            if index < 2 { await waitUntil { self.launcher.launches.count == index + 2 } }
        }
        await waitUntil { if case .failed = manager.state { return true } else { return false } }
        await manager.apply(.running(launchA))
        XCTAssertEqual(launcher.launches.count, 3, "the same desire does not leave the failed state")
        await manager.retry()
        XCTAssertEqual(launcher.launches.count, 4)
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"))
    }

    /// Review focus 1.
    func test_stopWhileStartingTerminatesAndIgnoresLateReadiness() async {
        let manager = makeManager()
        await manager.apply(.running(launchA))
        await waitUntil { self.probe.waiting == 1 }
        await manager.apply(.stopped)
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        probe.succeedNext()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(manager.state, .idle)
    }

    func test_readinessFailureTerminatesAndRestarts() async {
        let manager = makeManager()
        await manager.apply(.running(launchA))
        await waitUntil { self.probe.waiting == 1 }
        probe.failNext()
        await waitUntil { self.launcher.launches.count == 2 }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        XCTAssertEqual(sleeps, [.seconds(1)])
    }

    func test_unavailableDesirePublishesTheReasonWithoutLaunching() async {
        let manager = makeManager()
        await manager.apply(.unavailable(.noModel))
        XCTAssertEqual(manager.state, .unavailable(.noModel))
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertThrowsError(try manager.readyConfiguration) { error in
            XCTAssertEqual(error.localizedDescription, MLXUnavailableReason.noModel.message)
        }
    }

    func test_shutdownSyncKillsAStubbornServer() async {
        launcher.exitsOnTerminate = false
        let manager = makeManager()
        await startReady(manager, launchA)
        manager.shutdownSync(timeoutSeconds: 0.05)
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        XCTAssertEqual(launcher.launches[0].process.killCount, 1)
        XCTAssertEqual(manager.state, .idle)
    }

    func test_orphanCleanupOnlySignalsOurOwnServer() async {
        let manager = makeManager()
        let pidFile = MLXServerPIDFile(url: paths.serverPIDFile)
        var signals: [Int32] = []

        pidFile.write(pid: 4242)
        await manager.cleanUpOrphan(isAlive: { _ in true }, arguments: { _ in ["/usr/bin/vim"] },
                                    signal: { _, signal in signals.append(signal) })
        XCTAssertEqual(signals, [])
        XCTAssertNil(pidFile.read())

        pidFile.write(pid: 4242)
        await manager.cleanUpOrphan(
            isAlive: { _ in true },
            arguments: { _ in ["/p/python", "/x/MLX/bin/mlx_lm.server", "--host", "127.0.0.1", "--port", "9"] },
            signal: { _, signal in signals.append(signal) })
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
        XCTAssertNil(pidFile.read())
    }

    func test_loopbackPortIsUsable() throws {
        let port = try MLXLoopbackPort.next()
        XCTAssertTrue((1024...65535).contains(port))
    }
}

// The three doubles below are internal (not private) so the Task 12 wiring test can reuse them.

@MainActor
final class MLXFakeProcess: MLXRunningProcess {
    let processIdentifier: Int32
    var isRunning = true
    var exitsOnTerminate = true
    var tail: [String] = []
    private(set) var terminateCount = 0
    private(set) var killCount = 0

    init(pid: Int32) { processIdentifier = pid }

    func terminate() {
        terminateCount += 1
        if exitsOnTerminate { isRunning = false }
    }

    func forceKill() {
        killCount += 1
        isRunning = false
    }

    func stderrTail() -> [String] { tail }
}

@MainActor
final class MLXFakeLauncher: MLXProcessLaunching {
    struct Launch {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let process: MLXFakeProcess
        let onExit: @MainActor (Int32) -> Void
    }

    private(set) var launches: [Launch] = []
    var exitsOnTerminate = true

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any MLXRunningProcess {
        let process = MLXFakeProcess(pid: Int32(1000 + launches.count))
        process.exitsOnTerminate = exitsOnTerminate
        launches.append(Launch(executable: executable, arguments: arguments, environment: environment,
                               process: process, onExit: onExit))
        return process
    }

    /// Simulates launch `index` dying on its own.
    func crash(_ index: Int, status: Int32 = 1) {
        launches[index].process.isRunning = false
        launches[index].onExit(status)
    }
}

/// Each readiness wait suspends until the test resolves it, so tests control exactly when (and
/// whether) a server becomes ready, including after it was stopped.
@MainActor
final class MLXFakeProbe: MLXReadinessProbing {
    private var pending: [CheckedContinuation<Void, Error>] = []
    var waiting: Int { pending.count }

    func waitUntilReady(port: Int, modelID: String, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func succeedNext() { pending.removeFirst().resume() }
    func failNext() { pending.removeFirst().resume(throwing: MLXServerError.readinessTimedOut) }
}
