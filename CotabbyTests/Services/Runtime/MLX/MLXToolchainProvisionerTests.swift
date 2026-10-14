import CryptoKit
import XCTest
@testable import Cotabby

@MainActor
final class MLXToolchainProvisionerTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private var root: URL!
    private var home: URL!
    private var paths: MLXPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-prov-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        paths = MLXPaths(root: root.appendingPathComponent("Support/Cotabby/MLX"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes an executable launcher script whose shebang names `python`.
    private func script(at url: URL, python: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!\(python)\nimport mlx_lm\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeProvisioner(
        versions: [String: String],
        installer: MLXToolchainInstalling = NeverInstaller()
    ) -> MLXToolchainProvisioner {
        let provisioner = MLXToolchainProvisioner(
            paths: paths, home: home, fileManager: .default,
            probeVersion: { python in versions[python.path] },
            installer: installer
        )
        Self.retained.append(provisioner)
        return provisioner
    }

    func test_ownInstallWinsOverExternal() async throws {
        try script(at: paths.ownServerExecutable, python: "/own/python")
        try script(at: home.appendingPathComponent(".local/bin/mlx_lm.server"), python: "/uv/python")
        let state = await makeProvisioner(versions: ["/own/python": "0.32.0", "/uv/python": "0.33.0"]).locate()
        XCTAssertEqual(state.toolchain?.pythonExecutable.path, "/own/python")
        XCTAssertEqual(state.toolchain?.isCotabbyInstall, true)
    }

    func test_externalUvInstallIsUsedWhenNoOwnInstall() async throws {
        try script(at: home.appendingPathComponent(".local/bin/mlx_lm.server"), python: "/uv/python")
        let state = await makeProvisioner(versions: ["/uv/python": "0.32.0"]).locate()
        XCTAssertEqual(state.toolchain?.version, "0.32.0")
        XCTAssertEqual(state.toolchain?.isCotabbyInstall, false)
    }

    func test_tooOldExternalIsReported() async throws {
        try script(at: home.appendingPathComponent(".local/bin/mlx_lm.server"), python: "/uv/python")
        let state = await makeProvisioner(versions: ["/uv/python": "0.29.1"]).locate()
        XCTAssertEqual(state, .tooOld(version: "0.29.1", path: home.appendingPathComponent(".local/bin/mlx_lm.server").path))
    }

    /// Review focus 5: a half-written install (Cotabby quit mid-install) must not count as installed.
    func test_ownInstallWithoutWorkingPythonIsNotInstalled() async throws {
        try script(at: paths.ownServerExecutable, python: "/own/python")
        let state = await makeProvisioner(versions: [:]).locate()
        XCTAssertEqual(state, .notInstalled)
    }

    func test_concurrentInstallRequestsShareOneInstall() async throws {
        let installer = GatedInstaller()
        let provisioner = makeProvisioner(versions: ["/own/python": "0.32.0"], installer: installer)
        provisioner.install()
        provisioner.install()
        await waitUntil { installer.calls == 1 && provisioner.state == .installing(.installingMLX) }
        try script(at: paths.ownServerExecutable, python: "/own/python")
        installer.release()
        await waitUntil { provisioner.state.toolchain != nil }
        XCTAssertEqual(installer.calls, 1)
    }

    func test_installFailureKeepsTheLogTail() async {
        let provisioner = makeProvisioner(versions: [:], installer: FailingInstaller())
        provisioner.install()
        await waitUntil { if case .failed = provisioner.state { return true } else { return false } }
        XCTAssertEqual(provisioner.state, .failed(reason: MLXInstallError.installFailed(tail: ["boom"]).localizedDescription, logTail: ["boom"]))
    }

    func test_removeDeletesOnlyCotabbysFolder() async throws {
        try script(at: paths.ownServerExecutable, python: "/own/python")
        let external = home.appendingPathComponent(".local/bin/mlx_lm.server")
        try script(at: external, python: "/uv/python")
        let provisioner = makeProvisioner(versions: ["/own/python": "0.32.0", "/uv/python": "0.32.0"])
        await provisioner.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(provisioner.state.toolchain?.isCotabbyInstall, false)
    }

    // MARK: - Installer

    func test_installerRejectsAChecksumMismatchBeforeRunningAnything() async {
        var ran = false
        let installer = MLXToolchainInstaller(
            paths: paths,
            download: { _ in Data("not uv".utf8) },
            runProcess: { _, _, _, _ in ran = true; return MLXProcessResult(status: 0, stdout: "", stderrTail: []) },
            verifySignature: { _ in true }
        )
        do {
            try await installer.install(phase: { _ in })
            XCTFail("expected a checksum failure")
        } catch {
            XCTAssertEqual(error as? MLXInstallError, .checksumMismatch)
        }
        XCTAssertFalse(ran)
    }

    func test_installerRejectsAnUnsignedUV() async {
        let archive = Data("pretend archive".utf8)
        var commands: [String] = []
        let installer = MLXToolchainInstaller(
            paths: paths,
            expectedSHA256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
            download: { _ in archive },
            runProcess: { executable, _, _, _ in
                commands.append(executable.lastPathComponent)
                return MLXProcessResult(status: 0, stdout: "", stderrTail: [])
            },
            verifySignature: { _ in false }
        )
        do {
            try await installer.install(phase: { _ in })
            XCTFail("expected a signature failure")
        } catch {
            XCTAssertEqual(error as? MLXInstallError, .signatureInvalid)
        }
        XCTAssertEqual(commands, ["tar"], "uv must never run when its signature is not Astral's")
    }

    func test_installerRunsUvWithThePinnedCommand() async throws {
        let archive = Data("pretend archive".utf8)
        var calls: [(String, [String], [String: String])] = []
        var phases: [MLXInstallPhase] = []
        let installer = MLXToolchainInstaller(
            paths: paths,
            expectedSHA256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
            download: { _ in archive },
            runProcess: { executable, arguments, environment, _ in
                calls.append((executable.path, arguments, environment))
                return MLXProcessResult(status: 0, stdout: "", stderrTail: [])
            },
            verifySignature: { _ in true }
        )
        try await installer.install(phase: { phases.append($0) })
        XCTAssertEqual(phases, [.downloadingUV, .verifyingUV, .installingMLX])
        XCTAssertEqual(calls.map(\.0), ["/usr/bin/tar", paths.uvExecutable.path])
        XCTAssertEqual(calls[1].1, ["tool", "install", "mlx-lm==0.32.0", "--python", "3.12"])
        XCTAssertEqual(calls[1].2["UV_TOOL_BIN_DIR"], paths.binDirectory.path)
    }
}

nonisolated private struct NeverInstaller: MLXToolchainInstalling {
    func install(phase: @escaping @MainActor (MLXInstallPhase) -> Void) async throws {
        XCTFail("install should not run")
    }
}

private struct FailingInstaller: MLXToolchainInstalling {
    func install(phase: @escaping @MainActor (MLXInstallPhase) -> Void) async throws {
        throw MLXInstallError.installFailed(tail: ["boom"])
    }
}

/// Suspends inside `install` until the test calls `release()`, counting calls.
@MainActor
private final class GatedInstaller: MLXToolchainInstalling {
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?

    func install(phase: @escaping @MainActor (MLXInstallPhase) -> Void) async throws {
        calls += 1
        phase(.installingMLX)
        await withCheckedContinuation { gate = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}
