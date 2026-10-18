import XCTest
@testable import Cotabby

/// The snapshot layout must match huggingface_hub's, so models downloaded by either are shared.
final class MLXSnapshotDownloaderTests: XCTestCase {
    func test_linksPointBackToTheBlobsFolderFromAnyDepth() {
        XCTAssertEqual(MLXSnapshotDownloader.linkDestination(path: "config.json", blobID: "abc"), "../../blobs/abc")
        XCTAssertEqual(
            MLXSnapshotDownloader.linkDestination(path: "tokenizer/vocab.json", blobID: "abc"), "../../../blobs/abc")
    }

    func test_filesDownloadFromTheSnapshotsRevision() {
        let url = MLXSnapshotDownloader.fileURL(
            repo: MLXRepoID("mlx-community/gemma-4-e4b-5bit")!, revision: "0404ce", path: "model-00001-of-00002.safetensors")
        XCTAssertEqual(
            url?.absoluteString,
            "https://huggingface.co/mlx-community/gemma-4-e4b-5bit/resolve/0404ce/model-00001-of-00002.safetensors")
    }

    func test_aPathThatLeavesTheSnapshotIsRefusedBeforeAnyDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../escape.json", "/etc/passwd", "a//b", "./x"] {
            let snapshot = MLXRemoteSnapshot(revision: "r", files: [.init(path: path, size: 1, blobID: "b")])
            do {
                try await MLXSnapshotDownloader.download(
                    snapshot, repo: MLXRepoID("a/b")!, cacheRoot: root,
                    transfer: { _, _, _ in XCTFail("no transfer for \(path)") })
                XCTFail("\(path) was accepted")
            } catch let error as MLXSnapshotDownloadError {
                XCTAssertEqual(error, .unsafePath(path))
            }
        }
    }
}
