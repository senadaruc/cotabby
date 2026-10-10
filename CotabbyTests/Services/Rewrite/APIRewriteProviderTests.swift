import XCTest
@testable import Cotabby

/// The API provider sends the rewrite prompt to the configured model with the Keychain key, and
/// reports itself unavailable until a URL and model are set.
@MainActor
final class APIRewriteProviderTests: XCTestCase {
    private static var retained: [AnyObject] = []

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RewriteStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeProvider(_ prefs: @escaping @MainActor () -> RewritePreferences, keys: [RewriteCloudProvider: String] = [:]) -> APIRewriteProvider {
        let session = makeSession()
        let stores = Dictionary(uniqueKeysWithValues: RewriteCloudProvider.allCases.map {
            ($0, InMemoryOpenAICompatibleCredentialStore(apiKey: keys[$0]))
        })
        let provider = APIRewriteProvider(
            client: OpenAICompatibleAPIClient(session: session),
            anthropic: AnthropicMessagesClient(session: session),
            preferences: prefs,
            credentials: { stores[$0]! }
        )
        Self.retained.append(provider)
        return provider
    }

    private static func reply(_ request: URLRequest, _ body: String) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        ))
        return (response, Data(body.utf8))
    }

    func test_customEndpointIsUnavailableUntilConfigured() {
        var prefs = RewritePreferences.defaults
        prefs.cloudProvider = .custom
        let provider = makeProvider({ prefs })
        XCTAssertFalse(provider.isAvailable)
        prefs.apiBaseURL = "https://api.example.com/v1"
        prefs.apiModelName = "gpt-4.1-mini"
        XCTAssertTrue(provider.isAvailable)
        XCTAssertTrue(provider.sendsOffDevice)
        XCTAssertEqual(provider.hostName, "api.example.com")
    }

    func test_loopbackEndpointIsNotOffDevice() {
        var prefs = RewritePreferences.defaults
        prefs.cloudProvider = .custom
        prefs.apiBaseURL = "http://127.0.0.1:11434/v1"
        prefs.apiModelName = "llama3"
        XCTAssertFalse(makeProvider({ prefs }).sendsOffDevice)
    }

    func test_namedProviderUsesItsOwnURL() {
        var prefs = RewritePreferences.defaults
        prefs.cloudProvider = .anthropic
        XCTAssertEqual(makeProvider({ prefs }).hostName, "api.anthropic.com")
        prefs.cloudProvider = .gemini
        XCTAssertEqual(makeProvider({ prefs }).hostName, "generativelanguage.googleapis.com")
    }

    func test_rewriteSendsTheRewriteKeyAndTwoMessages() async throws {
        RewriteStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rk")
            let body = try Self.jsonBody(request)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
            return try Self.reply(request, "data: {\"choices\":[{\"delta\":{\"content\":\"Fixed.\"}}]}\n\ndata: [DONE]\n\n")
        }
        defer { RewriteStubURLProtocol.handler = nil }
        var prefs = RewritePreferences.defaults
        prefs.cloudProvider = .custom
        prefs.apiBaseURL = "https://api.example.com/v1"
        prefs.apiModelName = "m"
        let provider = makeProvider({ prefs }, keys: [.custom: "rk"])
        let text = try await provider.rewrite(
            RewriteRequest(selection: "Fxed draft.", action: .fixOnly, memory: .empty), onPartial: { _ in }
        )
        XCTAssertEqual(text, "Fixed.")
    }

    /// Claude goes through Anthropic's own Messages API with Claude's key, not the
    /// OpenAI-compatible path, and each provider keeps its own key.
    func test_claudeUsesTheMessagesAPIAndItsOwnKey() async throws {
        RewriteStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "claude-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return try Self.reply(request, """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Selam!"}}

            event: message_stop
            data: {"type":"message_stop"}

            """)
        }
        defer { RewriteStubURLProtocol.handler = nil }
        var prefs = RewritePreferences.defaults
        prefs.cloudProvider = .anthropic
        let provider = makeProvider({ prefs }, keys: [.anthropic: "claude-key", .openAI: "openai-key"])
        let text = try await provider.rewrite(
            RewriteRequest(selection: "selam", action: .friendly, memory: .empty), onPartial: { _ in }
        )
        XCTAssertEqual(text, "Selam!")
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? readBodyStream(request.httpBodyStream))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Anthropic's Messages API over raw HTTP (Swift has no official Anthropic SDK): the headers and body
/// it needs, streamed text taken from text deltas only, and refusals and errors surfaced as errors.
@MainActor
final class AnthropicMessagesClientTests: XCTestCase {
    private static var retained: [AnyObject] = []

    private func makeClient() -> AnthropicMessagesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RewriteStubURLProtocol.self]
        let client = AnthropicMessagesClient(session: URLSession(configuration: configuration))
        Self.retained.append(client)
        return client
    }

    private static func reply(_ request: URLRequest, status: Int = 200, _ body: String) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
        return (response, Data(body.utf8))
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        guard let stream = request.httpBodyStream else {
            return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        stream.open(); defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096); defer { buffer.deallocate() }
        while stream.hasBytesAvailable { let n = stream.read(buffer, maxLength: 4_096); if n <= 0 { break }; data.append(buffer, count: n) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message"}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hidden"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" there"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    func test_streamsTextAndSendsWhatTheAPIRequires() async throws {
        let body = stream
        RewriteStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
            let json = try Self.json(request)
            XCTAssertEqual(json["model"] as? String, "claude-opus-5-5")
            XCTAssertEqual(json["max_tokens"] as? Int, 16_000)
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertEqual(json["system"] as? String, "rules")
            XCTAssertEqual(json["fallbacks"] as? String, "default")
            XCTAssertEqual((json["output_config"] as? [String: String])?["effort"], "low")
            XCTAssertNil(json["temperature"], "current Claude models reject sampling parameters")
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [["role": "user", "content": "draft"]])
            return try Self.reply(request, body)
        }
        defer { RewriteStubURLProtocol.handler = nil }
        var partials: [String] = []
        let text = try await makeClient().streamMessage(
            baseURL: "https://api.anthropic.com/v1", apiKey: "k", model: "claude-opus-5-5",
            system: "rules", user: "draft", timeout: 20, onPartial: { partials.append($0) }
        )
        XCTAssertEqual(text, "Hello there")
        XCTAssertEqual(partials, ["Hello", "Hello there"])
    }

    func test_olderModelsGetNoEffortOrFallback() async throws {
        let body = stream
        RewriteStubURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
            let json = try Self.json(request)
            XCTAssertNil(json["fallbacks"])
            XCTAssertNil(json["output_config"], "effort errors on Haiku 4.5")
            return try Self.reply(request, body)
        }
        defer { RewriteStubURLProtocol.handler = nil }
        _ = try await makeClient().streamMessage(
            baseURL: "https://api.anthropic.com/v1", apiKey: "k", model: "claude-haiku-4-5",
            system: "rules", user: "draft", timeout: 20, onPartial: { _ in }
        )
    }

    func test_refusalIsAnError() async {
        RewriteStubURLProtocol.handler = { request in
            try Self.reply(request, """
            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}

            """)
        }
        defer { RewriteStubURLProtocol.handler = nil }
        do {
            _ = try await makeClient().streamMessage(baseURL: "https://api.anthropic.com/v1", apiKey: "k", model: "claude-opus-5-5",
                                                     system: "s", user: "u", timeout: 20, onPartial: { _ in })
            XCTFail("Expected a refusal error")
        } catch {
            XCTAssertEqual(error as? AnthropicMessagesError, .refused)
        }
    }

    func test_httpErrorCarriesTheAPIMessage() async {
        RewriteStubURLProtocol.handler = { request in
            try Self.reply(request, status: 401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        }
        defer { RewriteStubURLProtocol.handler = nil }
        do {
            _ = try await makeClient().streamMessage(baseURL: "https://api.anthropic.com/v1", apiKey: "bad", model: "claude-opus-5-5",
                                                     system: "s", user: "u", timeout: 20, onPartial: { _ in })
            XCTFail("Expected an API error")
        } catch {
            XCTAssertEqual(error as? AnthropicMessagesError, .api(status: 401, message: "invalid x-api-key"))
        }
    }

    func test_listsModelIDs() async throws {
        RewriteStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=100")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
            return try Self.reply(request, #"{"data":[{"id":"claude-opus-5-5","type":"model"},{"id":"claude-haiku-5-5","type":"model"}],"has_more":false}"#)
        }
        defer { RewriteStubURLProtocol.handler = nil }
        let models = try await makeClient().listModels(baseURL: "https://api.anthropic.com/v1", apiKey: "k")
        XCTAssertEqual(models, ["claude-opus-5-5", "claude-haiku-5-5"])
    }
}

/// Answers the rewrite request in place of the network, so the test checks what the provider sends.
/// Same pattern as `EndpointStubURLProtocol` in the OpenAI-compatible client tests.
private final class RewriteStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
