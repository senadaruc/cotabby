import Darwin
import Foundation
import Logging

/// File overview:
/// Removes what earlier versions left from running MLX in Python, once per launch and cheaply when
/// there is nothing to do. Those versions installed `uv`, Python and mlx-lm under
/// `~/Library/Application Support/<CFBundleName>/MLX` (about 250 MB) and ran `mlx_lm.server`,
/// recording its pid in `server.pid` / `rewrite-server.pid` there. MLX now runs inside Cotabby,
/// so a server still running from a crash is stopped and the folder is deleted. Models are not in
/// it: they live in the shared Hugging Face cache, which this never touches.
nonisolated enum MLXLegacyCleanup {
    /// The folder earlier versions installed into, keyed by `CFBundleName` so the Dev and release
    /// apps each clean only their own.
    static func legacyFolder(bundle: Bundle = .main) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        return support.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("MLX", isDirectory: true)
    }

    static let pidFileNames = ["server.pid", "rewrite-server.pid"]
    private static let stopGrace: Duration = .seconds(3)
    private static let stopPoll: Duration = .milliseconds(100)

    /// Stops any server a pid file names, then deletes the folder.
    static func run(
        folder: URL = legacyFolder(),
        fileManager: FileManager = .default,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 },
        arguments: (Int32) -> [String]? = processArguments(of:),
        signal: (Int32, Int32) -> Void = { pid, signal in _ = kill(pid, signal) },
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async {
        guard fileManager.fileExists(atPath: folder.path) else { return }
        for name in pidFileNames {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
                  isAlive(pid),
                  // Pids are reused, so only a process that is really our server is signalled.
                  let processArguments = arguments(pid), isLegacyServer(arguments: processArguments)
            else { continue }
            CotabbyLogger.runtime.warning("Stopping an MLX server left by an earlier Cotabby version", metadata: ["pid": .stringConvertible(pid)])
            signal(pid, SIGTERM)
            var waited: Duration = .zero
            while isAlive(pid), waited < stopGrace {
                await sleep(stopPoll)
                waited += stopPoll
            }
            if isAlive(pid) { signal(pid, SIGKILL) }
        }
        do {
            try fileManager.removeItem(at: folder)
            CotabbyLogger.runtime.info("Removed the Python MLX install of an earlier Cotabby version")
        } catch {
            CotabbyLogger.runtime.error("Could not remove the old Python MLX install: \(error.localizedDescription)")
        }
    }

    /// Cotabby launched its server as the `mlx_lm.server` script bound to loopback.
    static func isLegacyServer(arguments: [String]) -> Bool {
        let runsServer = arguments.contains { ($0 as NSString).lastPathComponent == "mlx_lm.server" }
        let loopback = zip(arguments, arguments.dropFirst()).contains { $0 == "--host" && $1 == "127.0.0.1" }
        return runsServer && loopback
    }

    /// The process's argv via `sysctl(KERN_PROCARGS2)`; nil if it exited or is not ours to read.
    static func processArguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` is argc (Int32), the executable path, NUL padding, then argc NUL-terminated
    /// arguments.
    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }
}
