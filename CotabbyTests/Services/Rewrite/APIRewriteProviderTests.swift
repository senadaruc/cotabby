import XCTest
@testable import Cotabby

/// The API provider sends the rewrite prompt to the configured model with the Keychain key, and
/// reports itself unavailable until a URL and model are set.
@MainActor
final class APIRewriteProviderTests: XCTestCase {
    private static var retained: [AnyObject] = []

    func test_unavailableUntilConfigured() {
        var prefs = RewritePreferences.defaults
        let provider = APIRewriteProvider(client: OpenAICompatibleAPIClient(), preferences: { prefs },
                                          credentials: InMemoryOpenAICompatibleCredentialStore())
        Self.retained.append(provider)
        XCTAssertFalse(provider.isAvailable)
        prefs.apiBaseURL = "https://api.example.com/v1"
        prefs.apiModelName = "gpt-4.1-mini"
        XCTAssertTrue(provider.isAvailable)
        XCTAssertTrue(provider.sendsOffDevice)
        XCTAssertEqual(provider.hostName, "api.example.com")
    }

    func test_loopbackEndpointIsNotOffDevice() {
        var prefs = RewritePreferences.defaults
        prefs.apiBaseURL = "http://127.0.0.1:11434/v1"
        prefs.apiModelName = "llama3"
        let provider = APIRewriteProvider(client: OpenAICompatibleAPIClient(), preferences: { prefs },
                                          credentials: InMemoryOpenAICompatibleCredentialStore())
        Self.retained.append(provider)
        XCTAssertFalse(provider.sendsOffDevice)
    }

    func test_rewriteSendsTheRewriteKeyAndTwoMessages() async throws {
        RewriteStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rk")
            let body = try Self.jsonBody(request)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
            let reply = Data("data: {\"choices\":[{\"delta\":{\"content\":\"Fixed.\"}}]}\n\ndata: [DONE]\n\n".utf8)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            return (response, reply)
        }
        defer { RewriteStubURLProtocol.handler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RewriteStubURLProtocol.self]
        let client = OpenAICompatibleAPIClient(session: URLSession(configuration: sessionConfiguration))
        var prefs = RewritePreferences.defaults
        prefs.apiBaseURL = "https://api.example.com/v1"
        prefs.apiModelName = "m"
        let provider = APIRewriteProvider(client: client, preferences: { prefs },
                                          credentials: InMemoryOpenAICompatibleCredentialStore(apiKey: "rk"))
        Self.retained.append(contentsOf: [client as AnyObject, provider as AnyObject])
        let text = try await provider.rewrite(
            RewriteRequest(selection: "Fxed draft.", action: .fixOnly, memory: .empty), onPartial: { _ in }
        )
        XCTAssertEqual(text, "Fixed.")
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
