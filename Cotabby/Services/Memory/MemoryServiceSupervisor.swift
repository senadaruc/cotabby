import Combine
import Darwin
import Foundation
import Logging

/// File overview:
/// Installs, starts, watches and stops Cotabby's conversation memory service (`MemoryService/`).
///
/// Why a supervisor: the service is a Python process with a multi-gigabyte dependency set
/// (LEANN, PyTorch, an embedding model), so Cotabby cannot assume it exists or keeps running. This
/// type owns that lifecycle so nothing else has to:
/// - **Install** is explicit (the user clicks Install after reading what it downloads): `uv`
///   creates `Memory/venv` and installs the pinned `memory-requirements.txt` from the app bundle.
///   An app update that pins different requirements marks the install stale.
/// - **Start** runs `venv/bin/python -m cotabby_memory` from the bundled source via `PYTHONPATH`,
///   with Cotabby's pid so the service exits if Cotabby dies, and waits for its `ready` line.
/// - **Watch**: an unexpected exit restarts with backoff (2, 4, 8 ... 60 s); five quick failures in
///   a row stop retrying and surface the error instead of looping.
///
/// The child process runs under Cotabby's TCC identity (macOS attributes a child's file access to
/// its responsible app), so Full Disk Access granted to Cotabby covers the service's reads of
/// WhatsApp's and Mail's stores. Built once by `CotabbyAppEnvironment`; the Memory pane observes it.
@MainActor
final class MemoryServiceSupervisor: ObservableObject {
    enum State: Equatable {
        /// Memory is switched off in Settings.
        case disabled
        /// Enabled, but the venv is missing or stale; the user must install.
        case needsInstall(String)
        case installing(String)
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var isEnabled: Bool
    /// The `uv` binary found on this Mac, if any.
    @Published private(set) var uvPath: String?

    let paths: MemoryServicePaths
    let client: MemoryServiceClient
    private let bundled: MemoryServicePaths.BundledService?
    private let userDefaults: UserDefaults
    private var process: Process?
    private var stopping = false
    private var consecutiveFailures = 0
    private var restartTask: Task<Void, Never>?

    static let enabledDefaultsKey = "cotabbyMemoryServiceEnabled"
    static let maximumConsecutiveFailures = 5
    /// Generous: the first start after an install imports PyTorch, which takes several seconds.
    static let readyTimeout: TimeInterval = 90

    init(
        paths: MemoryServicePaths = .standard(),
        bundled: MemoryServicePaths.BundledService? = MemoryServicePaths.bundledService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.paths = paths
        self.bundled = bundled
        self.userDefaults = userDefaults
        client = MemoryServiceClient(socketPath: paths.socket.path)
        isEnabled = userDefaults.bool(forKey: Self.enabledDefaultsKey)
        uvPath = Self.findUV()
    }

    // MARK: - Public controls

    /// Called once at launch: brings the service up if the user left Memory on.
    func startIfEnabled() {
        guard isEnabled else {
            state = .disabled
            return
        }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled {
            start()
        } else {
            stop()
            state = .disabled
        }
    }

    /// Whether the venv exists and was installed from the requirements this build pins.
    var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: paths.python.path),
              let bundled,
              let wanted = try? String(contentsOf: bundled.requirements, encoding: .utf8),
              let installed = try? String(contentsOf: paths.installedRequirements, encoding: .utf8)
        else { return false }
        return wanted == installed
    }

    /// Creates the venv and installs the pinned requirements, then starts the service. Output goes
    /// to `install.log`; the last line of it is shown while installing.
    func install() {
        guard let bundled else {
            state = .failed("This build of Cotabby does not include the memory service.")
            return
        }
        uvPath = Self.findUV()
        guard let uv = uvPath else {
            state = .needsInstall("Install uv first (see below), then click Install.")
            return
        }
        stop()
        state = .installing("Creating the Python environment…")
        let paths = paths
        Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: paths.installLog.path, contents: nil)
                try await Self.run(uv, ["venv", "--python", "3.12", "--allow-existing", paths.venv.path], log: paths.installLog)
                await MainActor.run { self?.state = .installing("Installing LEANN and its models' runtime (several GB)…") }
                try await Self.run(
                    uv,
                    ["pip", "install", "--python", paths.python.path, "-r", bundled.requirements.path],
                    log: paths.installLog
                )
                try FileManager.default.removeItemIfPresent(at: paths.installedRequirements)
                try FileManager.default.copyItem(at: bundled.requirements, to: paths.installedRequirements)
                await MainActor.run {
                    CotabbyLogger.app.info("Memory service installed", metadata: ["venv": .string(paths.venv.path)])
                    self?.start()
                }
            } catch {
                await MainActor.run {
                    CotabbyLogger.app.error("Memory service install failed: \(error.localizedDescription)")
                    self?.state = .failed("Install failed: \(error.localizedDescription) See install.log.")
                }
            }
        }
    }

    func start() {
        guard isEnabled else { return }
        restartTask?.cancel()
        guard process?.isRunning != true else { return }
        guard bundled != nil else {
            state = .failed("This build of Cotabby does not include the memory service.")
            return
        }
        guard isInstalled else {
            state = .needsInstall(FileManager.default.fileExists(atPath: paths.python.path)
                ? "Cotabby was updated; reinstall to match the new memory service."
                : "The memory service is not installed yet.")
            return
        }
        guard paths.isSocketPathUsable else {
            state = .failed("The memory folder path is too long for a local socket: \(paths.socket.path)")
            return
        }
        launch()
    }

    func stop() {
        restartTask?.cancel()
        stopping = true
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        if state == .running || state == .starting {
            state = isEnabled ? .failed("Stopped.") : .disabled
        }
    }

    func restart() {
        stop()
        consecutiveFailures = 0
        start()
    }

    // MARK: - Process

    private func launch() {
        guard let bundled else { return }
        stopping = false
        state = .starting
        try? FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = paths.python
        process.arguments = [
            "-m", "cotabby_memory",
            "--data-dir", paths.dataDirectory.path,
            "--socket", paths.socket.path,
            "--parent-pid", String(getpid())
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = bundled.pythonPath.path
        // Bytecode must not be written into the signed app bundle (it would break the signature).
        environment["PYTHONPYCACHEPREFIX"] = paths.pycache.path
        environment["PYTHONUNBUFFERED"] = "1"
        // Hugging Face tokenizers warn when forked after use; the service never forks workers.
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.processExited(finished, status: status) }
        }
        do {
            try process.run()
        } catch {
            state = .failed("Could not start the memory service: \(error.localizedDescription)")
            return
        }
        self.process = process
        CotabbyLogger.app.info("Memory service starting", metadata: ["pid": .stringConvertible(process.processIdentifier)])

        // The service prints one JSON line when its socket is listening. Read it off the main actor.
        let handle = stdout.fileHandleForReading
        Task.detached { [weak self] in
            let ready = Self.waitForReadyLine(handle, timeout: Self.readyTimeout)
            await MainActor.run {
                guard let self, self.process === process else { return }
                if ready {
                    self.consecutiveFailures = 0
                    self.state = .running
                    CotabbyLogger.app.info("Memory service ready")
                } else if process.isRunning {
                    process.terminate()
                    self.state = .failed("The memory service did not start in time.")
                }
            }
        }
    }

    private func processExited(_ finished: Process, status: Int32) {
        guard process === finished || process == nil else { return }
        process = nil
        if stopping || !isEnabled { return }
        consecutiveFailures += 1
        CotabbyLogger.app.warning("Memory service exited", metadata: [
            "status": .stringConvertible(status),
            "consecutive_failures": .stringConvertible(consecutiveFailures)
        ])
        guard consecutiveFailures < Self.maximumConsecutiveFailures else {
            state = .failed("The memory service keeps exiting (status \(status)). See its log, then Restart.")
            return
        }
        let delay = min(60, 1 << consecutiveFailures)
        state = .starting
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    // MARK: - Helpers

    static func findUV() -> String? {
        MemoryServicePaths.uvCandidates().first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Reads stdout until the `{"event": "ready"}` line or the timeout. Blocking; background only.
    nonisolated private static func waitForReadyLine(_ handle: FileHandle, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { return false }  // EOF: the process exited before becoming ready.
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   object["event"] as? String == "ready" {
                    return true
                }
            }
        }
        return false
    }

    /// Runs a command to completion, appending its output to `log`; throws on a non-zero exit.
    nonisolated private static func run(_ executable: String, _ arguments: [String], log: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile()
                handle.write(Data("$ \(executable) \(arguments.joined(separator: " "))\n".utf8))
                process.standardOutput = handle
                process.standardError = handle
            }
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: InstallError.commandFailed(
                        "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.first ?? "") exited with \(finished.terminationStatus)."
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum InstallError: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let message): return message
            }
        }
    }
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        if fileExists(atPath: url.path) { try removeItem(at: url) }
    }
}
