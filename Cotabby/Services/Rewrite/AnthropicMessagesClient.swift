import Foundation

/// File overview:
/// Calls Claude through Anthropic's own Messages API (`POST /v1/messages`) over raw HTTP, because
/// Swift has no official Anthropic SDK and Anthropic's guidance for such languages is the native API
/// rather than an OpenAI-compatible shim. Streams the reply as Server-Sent Events and keeps only the
/// text deltas: current Claude models think by default and send `thinking` blocks first (empty unless
/// requested), which are not part of the rewrite.
///
/// Request shape, per Anthropic's reference:
/// - headers `x-api-key` and `anthropic-version: 2023-06-01`;
/// - `max_tokens` is required (16,000 leaves room without ever truncating a rewrite);
/// - no sampling parameters, which current models reject;
/// - `output_config.effort: low` on models that support effort, since a rewrite is a simple task and
///   lower effort answers faster;
/// - server-side refusal fallback (`fallbacks: "default"`) on the models that support it, so a
///   safety decline is retried on another Claude model instead of failing.
/// A `refusal` stop reason that survives is reported as an error. Owned by `APIRewriteProvider`.
@MainActor
final class AnthropicMessagesClient {
    static let apiVersion = "2023-06-01"
    static let maxTokens = 16_000
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated deinit {}

    /// Streams one rewrite and returns the full text. `onPartial` receives the cumulative text.
    func streamMessage(
        baseURL: String,
        apiKey: String?,
        model: String,
        system: String,
        user: String,
        timeout: TimeInterval,
        onPartial: (@MainActor (String) -> Void)?
    ) async throws -> String {
        var request = try Self.request(baseURL: baseURL, path: "messages", apiKey: apiKey, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        if Self.supportsEffort(model) {
            body["output_config"] = ["effort": "low"]
        }
        if Self.supportsDefaultFallback(model) {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw AnthropicMessagesError.api(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            switch type {
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { continue }
                accumulated += text
                onPartial?(accumulated)
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                    throw AnthropicMessagesError.refused
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw AnthropicMessagesError.api(status: 200, message: message)
            case "message_stop":
                return accumulated
            default:
                continue
            }
        }
        return accumulated
    }

    /// The model IDs the key can use (`GET /v1/models`), newest first as the API returns them.
    func listModels(baseURL: String, apiKey: String?) async throws -> [String] {
        let request = try Self.request(baseURL: baseURL, path: "models?limit=100", apiKey: apiKey, timeout: 10)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnthropicMessagesError.api(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// Effort is supported from the 5-series models on; older models (Haiku 4.5) reject it.
    static func supportsEffort(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"].contains { model.hasPrefix($0) }
    }

    /// The `"default"` refusal fallback is offered on Claude Fable 5.1, Opus 5.5, Opus 5 and Sonnet 5.5.
    static func supportsDefaultFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    private static func request(baseURL: String, path: String, apiKey: String?, timeout: TimeInterval) throws -> URLRequest {
        let root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/" + path), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else {
            throw AnthropicMessagesError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// The API's `{"type":"error","error":{"message":…}}` text, else a short fallback.
    private static func errorMessage(in data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String ?? "The Claude API returned an error."
    }
}

nonisolated enum AnthropicMessagesError: LocalizedError, Equatable {
    case invalidURL
    case refused
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The Claude API address is not valid."
        case .refused: return "Claude declined to rewrite this text."
        case .api(let status, let message): return "Claude API error \(status): \(message)"
        }
    }
}
