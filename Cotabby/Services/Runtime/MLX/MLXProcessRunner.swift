import Foundation

/// File overview:
/// Runs one MLX helper process (uv, tar, a Python one-liner) to completion off the main actor,
/// with a timeout, cooperative cancellation and bounded output capture. Owned by nobody: callers
/// await `run` and get a value back. Kept separate from the long-lived server process
/// (`MLXServerManager`), which never "completes".

nonisolated struct MLXProcessResult: Equatable, Sendable {
    let status: Int32
    let stdout: String
    let stderrTail: [String]
}

nonisolated enum MLXProcessRunnerError: LocalizedError, Equatable {
    case timedOut(tail: [String])
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The MLX helper took too long and was stopped."
        case .launchFailed(let message): return "The MLX helper could not start: \(message)"
        }
    }
}

/// Collects a child's output while it runs. Both pipes must be drained continuously: a child
/// that fills a 64 KB pipe buffer blocks forever. Stdout is kept whole up to 1 MiB (callers read
/// short answers from it); stderr keeps only its last lines for error messages.
nonisolated final class MLXOutputCollector: @unchecked Sendable {
    static let stdoutLimit = 1 << 20

    private let lock = NSLock()
    private let tailLines: Int
    private var stdout = Data()
    private var stderrLines: [String] = []
    private var partialStderrLine = ""

    init(tailLines: Int) {
        self.tailLines = tailLines
    }

    func appendStdout(_ data: Data) {
        lock.withLock {
            let room = Self.stdoutLimit - stdout.count
            if room > 0 { stdout.append(data.prefix(room)) }
        }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            partialStderrLine += String(decoding: data, as: UTF8.self)
            var lines = partialStderrLine.components(separatedBy: "\n")
            partialStderrLine = lines.removeLast()
            stderrLines.append(contentsOf: lines.filter { !$0.isEmpty })
            if stderrLines.count > tailLines { stderrLines.removeFirst(stderrLines.count - tailLines) }
        }
    }

    var stdoutText: String {
        lock.withLock { String(decoding: stdout, as: UTF8.self) }
    }

    var stderrTail: [String] {
        lock.withLock {
            let all = partialStderrLine.isEmpty ? stderrLines : stderrLines + [partialStderrLine]
            return Array(all.suffix(tailLines))
        }
    }
}

/// Bridges `Process.terminationHandler` (a background thread) to one awaiting task, in either
/// order: the process may exit before anyone awaits.
nonisolated private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ value: Int32) {
        let waiting: CheckedContinuation<Int32, Never>? = lock.withLock {
            status = value
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready: Int32? = lock.withLock {
                if let status { return status }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

nonisolated enum MLXProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        tailLines: Int = 20
    ) async throws -> MLXProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let output = MLXOutputCollector(tailLines: tailLines)
        // At EOF the handler is called with empty data, and it keeps being called until it is removed.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { output.appendStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { output.appendStderr(data) }
        }
        let exit = ExitSignal()
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw MLXProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Either the exit status or nil for "the timeout fired first". The group always waits
        // for the exit task, so every path below makes sure the child actually ends.
        let status: Int32?
        do {
            status = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Int32?.self) { group in
                    group.addTask { await exit.wait() }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return nil
                    }
                    let first = try await group.next() ?? nil
                    if first == nil { Self.stop(process) }
                    group.cancelAll()
                    return first
                }
            } onCancel: {
                Self.stop(process)
            }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        output.appendStdout((try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data())
        output.appendStderr((try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data())

        try Task.checkCancellation()
        guard let status else {
            throw MLXProcessRunnerError.timedOut(tail: output.stderrTail)
        }
        return MLXProcessResult(status: status, stdout: output.stdoutText, stderrTail: output.stderrTail)
    }

    /// SIGTERM now, SIGKILL three seconds later if the child ignored it.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
