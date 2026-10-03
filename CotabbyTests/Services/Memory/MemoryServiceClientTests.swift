import Darwin
import Foundation
import XCTest
@testable import Cotabby

/// Pins the Swift side of the memory service protocol: paths, decoding of the service's real
/// reply shapes, and the socket client's behaviour against a scripted Unix-socket server (result,
/// remote error, nothing listening, no reply in time).
final class MemoryServiceClientTests: XCTestCase {
    // MARK: - Paths

    func test_paths_keepEverythingUnderMemoryAndCheckTheSocketLength() {
        let paths = MemoryServicePaths(root: URL(fileURLWithPath: "/Users/me/Library/Application Support/Cotabby Dev/Memory"))
        XCTAssertEqual(paths.python.path, "/Users/me/Library/Application Support/Cotabby Dev/Memory/venv/bin/python")
        XCTAssertEqual(paths.socket.path, "/Users/me/Library/Application Support/Cotabby Dev/Memory/data/memory.sock")
        XCTAssertTrue(paths.isSocketPathUsable)
        let deep = MemoryServicePaths(root: URL(fileURLWithPath: "/" + String(repeating: "x", count: 120)))
        XCTAssertFalse(deep.isSocketPathUsable)
        XCTAssertEqual(MemoryServicePaths.uvCandidates(home: "/h").first, "/h/.local/bin/uv")
    }

    // MARK: - Decoding the service's shapes

    func test_searchResultDecodesTheServiceShape() throws {
        let json = """
        {"scope": "person", "conversation": {"source": "whatsapp", "conversation_id": "123@s.whatsapp.net",
         "title": "Ayşe", "participants": ["ayşe"], "last_timestamp": 1760000000.0}, "elapsed_ms": 18.4,
         "hits": [{"record_id": "whatsapp:abc", "source": "whatsapp", "conversation_id": "123@s.whatsapp.net",
         "conversation_title": "Ayşe", "sender": "Ayşe", "is_from_me": false, "timestamp": 1760000000.0,
         "subject": null, "text": "the invoice is paid", "score": 0.0123, "via": "both"}]}
        """
        let result = try MemoryServiceClient.decoder.decode(MemorySearchResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.scope, "person")
        XCTAssertEqual(result.conversation?.conversationId, "123@s.whatsapp.net")
        XCTAssertEqual(result.hits.first?.text, "the invoice is paid")
        XCTAssertEqual(result.hits.first?.isFromMe, false)
    }

    func test_configurationRoundTripsAndToleratesNonStringOptions() throws {
        let json = """
        {"index": {"backend": "hnsw", "embedding_mode": "sentence-transformers",
         "embedding_model": "Qwen/Qwen3-Embedding-0.6B", "chunk_size": 256, "chunk_overlap": 32,
         "graph_degree": 32, "build_complexity": 64, "recompute": false, "compact": false,
         "search_complexity": 32, "top_k": 4, "vector_weight": 0.7},
         "sources": {"documents": {"enabled": true, "options": {"folder": "~/Notes", "depth": 3}}},
         "privacy": {"excluded_conversations": [], "excluded_participants": ["boss"], "retention_days": 365}}
        """
        let config = try MemoryServiceClient.decoder.decode(MemoryConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.index.embeddingModel, "Qwen/Qwen3-Embedding-0.6B")
        XCTAssertEqual(config.sources["documents"]?.options, ["folder": "~/Notes", "depth": "3"])

        // What the pane sends back must use the service's snake_case keys.
        let encoded = try MemoryServiceClient.encoder.encode(config.index)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["vector_weight"] as? Double, 0.7)
        XCTAssertEqual(object["embedding_mode"] as? String, "sentence-transformers")
    }

    func test_resultEnvelopeMapsErrorsAndMissingResults() {
        XCTAssertThrowsError(try MemoryServiceClient.result(from: Data(#"{"id":1,"error":{"code":"unknown_source","message":"Unknown source: x"}}"#.utf8))) {
            XCTAssertEqual($0 as? MemoryServiceError, .remote(code: "unknown_source", message: "Unknown source: x"))
        }
        XCTAssertThrowsError(try MemoryServiceClient.result(from: Data(#"{"id":1}"#.utf8)))
        XCTAssertEqual(try MemoryServiceClient.result(from: Data(#"{"id":1,"result":{"ok":true}}"#.utf8)), Data(#"{"ok":true}"#.utf8))
    }

    // MARK: - Socket client

    func test_clientReceivesAResultOverARealSocket() async throws {
        let server = try ScriptedSocketServer(reply: #"{"id": 1, "result": {"cancelled": true}}"#)
        defer { server.stop() }
        struct Reply: Decodable { let cancelled: Bool }
        let reply = try await MemoryServiceClient(socketPath: server.path).call("jobs.cancel", params: ["id": 3], as: Reply.self)
        XCTAssertTrue(reply.cancelled)
        XCTAssertEqual(server.receivedMethod, "jobs.cancel")
    }

    func test_clientReportsNotRunningWhenNothingListens() async {
        let client = MemoryServiceClient(socketPath: NSTemporaryDirectory() + "cm-missing-\(UUID().uuidString.prefix(6)).sock")
        do {
            try await client.send("status")
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? MemoryServiceError, .notRunning)
        }
    }

    func test_clientTimesOutWhenTheServiceNeverAnswers() async throws {
        let server = try ScriptedSocketServer(reply: nil)
        defer { server.stop() }
        let started = Date()
        do {
            try await MemoryServiceClient(socketPath: server.path).send("search", timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? MemoryServiceError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

/// A one-connection Unix-socket server that reads one request line and answers with `reply`
/// (or never answers when nil), for exercising the client's real socket path in tests.
private final class ScriptedSocketServer: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var method: String?
    private var clients: [Int32] = []

    var receivedMethod: String? {
        lock.lock(); defer { lock.unlock() }
        return method
    }

    init(reply: String?) throws {
        // Short path: Unix socket paths are limited to 104 bytes.
        path = "/tmp/cm-test-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            throw NSError(domain: "ScriptedSocketServer", code: Int(errno))
        }
        let descriptor = descriptor
        Thread.detachNewThread { [weak self] in
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            self?.lock.lock(); self?.clients.append(client); self?.lock.unlock()
            var buffer = [UInt8](repeating: 0, count: 65536)
            var received = Data()
            while !received.contains(0x0A) {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { return }
                received.append(contentsOf: buffer[0..<count])
            }
            if let object = try? JSONSerialization.jsonObject(with: received.prefix(upTo: received.firstIndex(of: 0x0A)!)) as? [String: Any] {
                self?.lock.lock(); self?.method = object["method"] as? String; self?.lock.unlock()
            }
            if let reply {
                let data = Array((reply + "\n").utf8)
                _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            }
        }
    }

    func stop() {
        lock.lock()
        clients.forEach { close($0) }
        lock.unlock()
        close(descriptor)
        unlink(path)
    }
}
