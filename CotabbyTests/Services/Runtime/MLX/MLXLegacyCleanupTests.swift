import XCTest
@testable import Cotabby

/// What a Python-based Cotabby left is removed, and only a process that is really its server is
/// signalled.
final class MLXLegacyCleanupTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-legacy-\(UUID().uuidString)/MLX")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("python/bin"), withIntermediateDirectories: true)
        try Data(count: 16).write(to: folder.appendingPathComponent("python/bin/python3"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private let serverArguments = ["/S/MLX/python/bin/python3", "/S/MLX/bin/mlx_lm.server", "--host", "127.0.0.1", "--port", "50123"]

    func test_stopsOurServerThenRemovesTheInstall() async throws {
        try "4242".write(to: folder.appendingPathComponent("server.pid"), atomically: true, encoding: .utf8)
        var alive: Set<Int32> = [4242]
        var signals: [(Int32, Int32)] = []
        await MLXLegacyCleanup.run(
            folder: folder,
            isAlive: { alive.contains($0) },
            arguments: { $0 == 4242 ? self.serverArguments : nil },
            signal: { pid, signal in
                signals.append((pid, signal))
                alive.remove(pid)
            },
            sleep: { _ in })
        XCTAssertEqual(signals.map(\.0), [4242])
        XCTAssertEqual(signals.map(\.1), [SIGTERM])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func test_aReusedPidIsNeverSignalled() async throws {
        try "4242".write(to: folder.appendingPathComponent("rewrite-server.pid"), atomically: true, encoding: .utf8)
        var signals = 0
        await MLXLegacyCleanup.run(
            folder: folder,
            isAlive: { _ in true },
            arguments: { _ in ["/Applications/Safari.app/Contents/MacOS/Safari"] },
            signal: { _, _ in signals += 1 },
            sleep: { _ in })
        XCTAssertEqual(signals, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func test_aServerThatIgnoresTermIsKilled() async throws {
        try "4242".write(to: folder.appendingPathComponent("server.pid"), atomically: true, encoding: .utf8)
        var signals: [Int32] = []
        await MLXLegacyCleanup.run(
            folder: folder,
            isAlive: { _ in signals.last != SIGKILL },
            arguments: { _ in self.serverArguments },
            signal: { _, signal in signals.append(signal) },
            sleep: { _ in })
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
    }

    func test_nothingToDoWithoutTheFolder() async {
        try? FileManager.default.removeItem(at: folder)
        await MLXLegacyCleanup.run(
            folder: folder,
            isAlive: { _ in XCTFail("no process check without a folder"); return false },
            sleep: { _ in })
    }

    func test_serverMatchNeedsTheScriptAndLoopback() {
        XCTAssertTrue(MLXLegacyCleanup.isLegacyServer(arguments: serverArguments))
        XCTAssertFalse(MLXLegacyCleanup.isLegacyServer(arguments: ["/bin/mlx_lm.server", "--host", "0.0.0.0"]))
        XCTAssertFalse(MLXLegacyCleanup.isLegacyServer(arguments: ["python3", "--host", "127.0.0.1"]))
    }

    func test_procArgsParse() {
        var bytes = withUnsafeBytes(of: Int32(2)) { Array($0) }
        bytes += Array("/usr/bin/python3".utf8) + [0, 0, 0]
        bytes += Array("python3".utf8) + [0] + Array("mlx_lm.server".utf8) + [0]
        XCTAssertEqual(MLXLegacyCleanup.parseProcArgs(bytes), ["python3", "mlx_lm.server"])
        XCTAssertNil(MLXLegacyCleanup.parseProcArgs([1, 0]))
    }
}
