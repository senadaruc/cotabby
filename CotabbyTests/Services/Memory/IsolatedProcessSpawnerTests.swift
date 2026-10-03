import Darwin
import Foundation
import XCTest
@testable import Cotabby

/// Pins that the memory service is started without Cotabby's privacy permissions: the child must
/// be responsible for itself, not for the process that spawned it. Also pins output capture and
/// exit-status decoding used by the installer.
final class IsolatedProcessSpawnerTests: XCTestCase {
    func test_childIsResponsibleForItselfAndItsStdoutIsReadable() throws {
        try XCTSkipUnless(IsolatedProcessSpawner.isIsolationAvailable)
        let child = try IsolatedProcessSpawner.spawn(
            executable: "/bin/sh", arguments: ["-c", "echo ready; sleep 1"], environment: [:]
        )
        defer {
            kill(child.pid, SIGTERM)
            var status: Int32 = 0
            waitpid(child.pid, &status, 0)
        }
        // Responsibility is what TCC checks: a disclaimed child answers for itself, so none of the
        // spawning process's grants (Accessibility, Input Monitoring, Full Disk Access) apply to it.
        if let responsible = IsolatedProcessSpawner.responsiblePid(for: child.pid) {
            XCTAssertEqual(responsible, child.pid)
            XCTAssertNotEqual(responsible, getpid())
        }
        let line = String(decoding: child.stdout.availableData, as: UTF8.self)
        XCTAssertEqual(line.trimmingCharacters(in: .whitespacesAndNewlines), "ready")
    }

    func test_runToCompletionReportsExitStatusAndAppendsOutput() throws {
        try XCTSkipUnless(IsolatedProcessSpawner.isIsolationAvailable)
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("spawn-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let status = try IsolatedProcessSpawner.runToCompletion(
            executable: "/bin/sh", arguments: ["-c", "echo one; echo two >&2; exit 3"],
            environment: [:], outputPath: log.path
        )
        XCTAssertEqual(status, 3)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "one\ntwo\n")
    }
}
