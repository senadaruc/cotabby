import Darwin
import Foundation

/// File overview:
/// Speaks the memory service's JSON-lines protocol over its Unix domain socket.
///
/// Why a raw POSIX socket: Foundation has no Unix-socket client, and Network.framework's
/// `NWConnection` adds an event-driven state machine for what is one request and one reply line.
/// Each call opens a connection, writes `{"id","method","params"}`, reads one reply line and closes;
/// on a Unix socket that costs microseconds, and it means a stuck call can never wedge a shared
/// connection that later calls depend on.
///
/// Calls block a background thread (never the main actor) and are bounded by a send/receive
/// timeout, so a suggestion's memory lookup has a hard ceiling no matter what the service does.
/// The client holds no state besides the socket path, so it is `Sendable` and shared freely.
enum MemoryServiceError: Error, Equatable, LocalizedError {
    /// The socket does not exist or nothing is listening: the service is not running.
    case notRunning
    case timedOut
    /// The reply was not the protocol's shape.
    case malformedReply(String)
    /// The service answered with an error (see `RequestError` in service.py).
    case remote(code: String, message: String)
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The memory service is not running."
        case .timedOut: return "The memory service did not answer in time."
        case .malformedReply(let detail): return "The memory service sent an unexpected reply (\(detail))."
        case .remote(_, let message): return message
        case .socket(let detail): return "Could not reach the memory service (\(detail))."
        }
    }
}

nonisolated final class MemoryServiceClient: Sendable {
    let socketPath: String
    /// Reply lines longer than this are refused rather than buffered without bound.
    static let maximumReplyBytes = 16 * 1024 * 1024

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Calls `method` and decodes its `result` as `T`.
    func call<T: Decodable>(
        _ method: String,
        params: [String: Any] = [:],
        as type: T.Type,
        timeout: TimeInterval = 10
    ) async throws -> T {
        let resultData = try await callRaw(method, params: params, timeout: timeout)
        do {
            return try Self.decoder.decode(T.self, from: resultData)
        } catch {
            throw MemoryServiceError.malformedReply("\(method): \(error)")
        }
    }

    /// Calls `method` for its effect, ignoring the result's shape.
    func send(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 10) async throws {
        _ = try await callRaw(method, params: params, timeout: timeout)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Snake-case encoder for settings sent back to the service (`config.set`).
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    /// Returns the JSON of the reply's `result` member.
    func callRaw(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> Data {
        // Serialize on the caller's side: `[String: Any]` is not Sendable, `Data` is.
        let request: Data
        do {
            request = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        } catch {
            throw MemoryServiceError.malformedReply("could not encode params for \(method)")
        }
        let path = socketPath
        return try await Task.detached(priority: .userInitiated) {
            let reply = try Self.exchange(request: request, socketPath: path, timeout: timeout)
            return try Self.result(from: reply)
        }.value
    }

    // MARK: - Wire

    static func result(from reply: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: reply, options: [.fragmentsAllowed]),
              let envelope = object as? [String: Any] else {
            throw MemoryServiceError.malformedReply("not a JSON object")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw MemoryServiceError.remote(
                code: error["code"] as? String ?? "error",
                message: error["message"] as? String ?? "Unknown error"
            )
        }
        guard let result = envelope["result"] else {
            throw MemoryServiceError.malformedReply("no result")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    /// One blocking request/reply exchange. Runs on a background thread only.
    private static func exchange(request: Data, socketPath: String, timeout: TimeInterval) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MemoryServiceError.socket(String(cString: strerror(errno))) }
        defer { Darwin.close(descriptor) }

        // A peer that closes mid-write must not raise SIGPIPE in Cotabby's process.
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        // `sockaddr_un.sun_path` is a fixed-size C char tuple; copy the path's bytes into it through
        // a raw buffer view. The path length was validated by `MemoryServicePaths.isSocketPathUsable`,
        // and is re-checked here so an overlong path can never overrun the tuple.
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw MemoryServiceError.socket("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED { throw MemoryServiceError.notRunning }
            throw MemoryServiceError.socket(String(cString: strerror(code)))
        }

        var payload = request
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? MemoryServiceError.timedOut
                        : MemoryServiceError.socket(String(cString: strerror(errno)))
                }
                offset += written
            }
        }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? MemoryServiceError.timedOut
                    : MemoryServiceError.socket(String(cString: strerror(errno)))
            }
            if count == 0 { break }
            reply.append(contentsOf: chunk[0..<count])
            if let newline = reply.firstIndex(of: 0x0A) {
                return reply.prefix(upTo: newline)
            }
            if reply.count > maximumReplyBytes {
                throw MemoryServiceError.malformedReply("reply too large")
            }
        }
        guard !reply.isEmpty else { throw MemoryServiceError.malformedReply("connection closed without a reply") }
        return reply
    }
}
