import XCTest
@testable import Cotabby

/// The MLX rewrite provider waits for the on-demand server, then streams the instruct prompt to
/// the server's exact port and model. A stubbed URLProtocol stands in for the HTTP server and the
/// manager's launcher/probe are the fakes from `MLXServerManagerTests`, so nothing real runs.
@MainActor
final class MLXRewriteProviderTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private let model = "mlx-community/gemma-4-e4b-it-4bit"

    override func tearDown() {
        MLXRewriteStubURLProtocol.handler = nil
        MLXRewriteStubURLProtocol.requested = []
        super.tearDown()
    }

    private struct Rig {
        let provider: MLXRewriteProvider
        let controller: MLXRewriteServerController
        let launcher: MLXFakeLauncher
        let probe: MLXFakeProbe
    }

    private func makeRig(
        toolchain: MLXToolchainState? = nil, cached: Bool = true,
        health: MLXServerHealth = .generatorDead,
        healthCheck: MLXHealthCheck? = nil
    ) -> Rig {
        let launcher = MLXFakeLauncher()
        let probe = MLXFakeProbe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-rp-\(UUID().uuidString)")
        let manager = MLXServerManager(
            paths: MLXPaths(root: root), launcher: launcher, probe: probe, pickPort: { 50300 },
            sleep: { _ in await Task.yield() }, baseEnvironment: [:], verifyListener: { _, _ in true },
            pidFileURL: MLXPaths(root: root).rewriteServerPIDFile)
        let ready = MLXToolchainState.ready(MLXToolchain(
            serverExecutable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"),
            pythonExecutable: URL(fileURLWithPath: "/mlx/bin/python"), version: "0.32.0", isCotabbyInstall: true))
        let models = cached ? [MLXCachedModel(repoID: MLXRepoID(model)!, snapshotURL: root, sizeBytes: 1, modelType: "gemma4", isInstruct: true)] : []
        let controller = MLXRewriteServerController(
            manager: manager, toolchain: { toolchain ?? ready }, cachedModels: { models }, rejectedModels: { [:] },
            isAppleSilicon: true,
            // The 5-minute idle wait really sleeps (and is cancelled with the test); polls yield.
            sleep: { duration in
                if duration >= .seconds(60) { try await Task.sleep(for: duration) } else { await Task.yield() }
            })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MLXRewriteStubURLProtocol.self]
        let client = OpenAICompatibleAPIClient(session: URLSession(configuration: configuration))
        var prefs = RewritePreferences.defaults
        prefs.provider = .mlx
        let provider = MLXRewriteProvider(controller: controller, client: client, preferences: { prefs }, healthCheck: healthCheck ?? { _ in health })
        Self.retained.append(contentsOf: [launcher, probe, manager, controller, client, provider] as [AnyObject])
        return Rig(provider: provider, controller: controller, launcher: launcher, probe: probe)
    }

    func test_availabilityFollowsToolchainAndCache() {
        XCTAssertTrue(makeRig().provider.isAvailable)
        XCTAssertFalse(makeRig(toolchain: .notInstalled).provider.isAvailable)
        XCTAssertFalse(makeRig(cached: false).provider.isAvailable)
        XCTAssertFalse(makeRig().provider.sendsOffDevice)
    }

    func test_streamsTheRewriteFromTheServersChatRoute() async throws {
        let rig = makeRig()
        MLXRewriteStubURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "mlx-community/gemma-4-e4b-it-4bit")
            let roles = (body?["messages"] as? [[String: String]])?.map { $0["role"] }
            XCTAssertEqual(roles, ["system", "user"])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data("data: {\"choices\":[{\"delta\":{\"content\":\"Fixed text.\"}}]}\n\ndata: [DONE]\n\n".utf8))
        }
        var partials: [String] = []
        let request = RewriteRequest(selection: "fixd text", action: .fixOnly, memory: .empty)
        async let result = rig.provider.rewrite(request, onPartial: { partials.append($0) })
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        let text = try await result
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertEqual(MLXRewriteStubURLProtocol.requested, ["http://127.0.0.1:50300/v1/chat/completions"])
        XCTAssertEqual(partials.first, "Loading MLX model…")
        XCTAssertEqual(partials.last, "Fixed text.")
    }

    private func rewrite404(health: MLXServerHealth) async -> (Rig, Error?) {
        let rig = makeRig(health: health)
        MLXRewriteStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        async let result = rig.provider.rewrite(
            RewriteRequest(selection: "fixd", action: .fixOnly, memory: .empty), onPartial: { _ in })
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        do {
            _ = try await result
            return (rig, nil)
        } catch {
            return (rig, error)
        }
    }

    func test_a404WithHealth503ReportsTheRewriteServerBroken() async {
        let (rig, error) = await rewrite404(health: .generatorDead)
        XCTAssertEqual(error as? RewriteError, .mlxUnavailable("MLX is restarting…"))
        await waitUntil { rig.launcher.launches.count == 2 }
        XCTAssertEqual(rig.launcher.launches[0].process.terminateCount, 1)
    }

    func test_a404WithHealthUnreachableReportsTheRewriteServerBroken() async {
        let (rig, error) = await rewrite404(health: .unreachable)
        XCTAssertEqual(error as? RewriteError, .mlxUnavailable("MLX is restarting…"))
        await waitUntil { rig.launcher.launches.count == 2 }
    }

    func test_a404WithAHealthyServerKeepsItAndFailsOnlyTheRewrite() async {
        let (rig, error) = await rewrite404(health: .healthy)
        XCTAssertEqual(error as? OpenAICompatibleClientError, .server(statusCode: 404))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(rig.launcher.launches.count, 1)
        XCTAssertEqual(rig.launcher.launches[0].process.terminateCount, 0)
    }

    func test_cancelledDuringTheHealthProbeNeverRestartsTheServer() async throws {
        let gate = HealthProbeGate()
        let rig = makeRig(healthCheck: { _ in
            gate.open()
            try? await Task.sleep(for: .seconds(10))
            return .unreachable
        })
        MLXRewriteStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let task = Task {
            try await rig.provider.rewrite(
                RewriteRequest(selection: "fixd", action: .fixOnly, memory: .empty), onPartial: { _ in })
        }
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        await waitUntil { gate.isOpen }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(rig.launcher.launches.count, 1)
        XCTAssertEqual(rig.launcher.launches[0].process.terminateCount, 0)
    }

    func test_unavailableServerThrowsWithoutAnyHTTPTraffic() async {
        let rig = makeRig(toolchain: .notInstalled)
        do {
            _ = try await rig.provider.rewrite(RewriteRequest(selection: "x", action: .fixOnly, memory: .empty), onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .mlxUnavailable(MLXUnavailableReason.notInstalled.message))
        }
        XCTAssertTrue(MLXRewriteStubURLProtocol.requested.isEmpty)
        XCTAssertTrue(rig.launcher.launches.isEmpty)
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MLXRewriteStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requested: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requested.append(request.url?.absoluteString ?? "")
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
