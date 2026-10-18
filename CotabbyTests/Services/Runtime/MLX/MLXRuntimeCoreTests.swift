import XCTest
@testable import Cotabby

/// The wired-memory ticket must cover the real weights. A Hugging Face snapshot holds links into
/// `blobs/`, and sizing the links instead of their targets wired 152 bytes for a 6 GB model: after
/// a 1.5 s pause the first token then took 177 ms instead of 31 ms.
final class MLXRuntimeCoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("snapshots/abc"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func blob(_ name: String, bytes: Int, linkedAs link: String) throws {
        let target = root.appendingPathComponent("blobs/\(name)")
        try Data(count: bytes).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("snapshots/abc/\(link)").path,
            withDestinationPath: "../../blobs/\(name)"
        )
    }

    func testWeightsBytesFollowsSnapshotLinksToTheBlobs() throws {
        try blob("w1", bytes: 3_000, linkedAs: "model-00001-of-00002.safetensors")
        try blob("w2", bytes: 2_000, linkedAs: "model-00002-of-00002.safetensors")
        try blob("c", bytes: 500, linkedAs: "config.json")
        XCTAssertEqual(MLXRuntimeCore.weightsBytes(in: root.appendingPathComponent("snapshots/abc")), 5_000)
    }

    func testWeightsBytesCountsPlainFiles() throws {
        let directory = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 1_234).write(to: directory.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(MLXRuntimeCore.weightsBytes(in: directory), 1_234)
    }
}
