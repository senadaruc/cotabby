import XCTest
@testable import Cotabby

/// The engine picks the provider the user chose, never lets memory reach an API unless the user
/// allowed it, and returns cleaned text or a clear error.
@MainActor
final class RewriteEngineTests: XCTestCase {
    private static var retained: [AnyObject] = []

    @MainActor
    private final class StubProvider: RewriteProviding {
        var isAvailable = true
        var unavailableReason: String?
        var sendsOffDevice: Bool
        var output = "Please let me know if the dates work for you."
        private(set) var received: [RewriteRequest] = []
        init(offDevice: Bool) { sendsOffDevice = offDevice }
        func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            received.append(request)
            onPartial(output)
            return output
        }
    }

    private let draft = "Please let me know if te dates are ok and wors for you."
    private let memory = RewriteMemoryContext(facts: [.init(text: "Dinner on the 28th", source: "whatsapp", sender: "Richard")],
                                              styleExamples: ["Best regards, Senad"])

    /// Every provider slot, as stubs: Apple Intelligence and Open Source and MLX stay on this Mac,
    /// the Local Endpoint stub is on loopback unless a test flips it, the API stub is off device.
    private struct Rig {
        let engine: RewriteEngine
        let apple: StubProvider
        let openSource: StubProvider
        let endpoint: StubProvider
        let mlx: StubProvider
        let api: StubProvider
    }

    private func makeRig(_ prefs: RewritePreferences, autocomplete: SuggestionEngineKind = .llamaOpenSource) -> Rig {
        let apple = StubProvider(offDevice: false)
        let openSource = StubProvider(offDevice: false)
        let endpoint = StubProvider(offDevice: false)
        let mlx = StubProvider(offDevice: false)
        let api = StubProvider(offDevice: true)
        let engine = RewriteEngine(
            appleIntelligence: apple, openSource: openSource, localEndpoint: endpoint, mlx: mlx, api: api,
            autocompleteEngine: { autocomplete }, preferences: { prefs })
        Self.retained.append(contentsOf: [engine, apple, openSource, endpoint, mlx, api] as [AnyObject])
        return Rig(engine: engine, apple: apple, openSource: openSource, endpoint: endpoint, mlx: mlx, api: api)
    }

    /// The old three-slot shape: `local` is the Open Source stub (the default resolves to it).
    private func make(_ prefs: RewritePreferences) -> (RewriteEngine, StubProvider, StubProvider) {
        let rig = makeRig(prefs)
        return (rig.engine, rig.openSource, rig.api)
    }

    func test_unavailableMLXThrowsItsOwnReason() async {
        var prefs = RewritePreferences.defaults
        prefs.provider = .mlx
        let rig = makeRig(prefs)
        rig.mlx.isAvailable = false
        rig.mlx.unavailableReason = "Install MLX in Settings → Engine & Model."
        do {
            _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: .empty), onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable("Install MLX in Settings → Engine & Model."))
        }
    }

    func test_mlxProviderIsChosenAndKeepsMemory() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .mlx
        let rig = makeRig(prefs)
        XCTAssertTrue(rig.engine.memoryAllowed)
        _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: memory), onPartial: { _ in })
        XCTAssertEqual(rig.mlx.received.first?.memory, memory)
        XCTAssertTrue(rig.openSource.received.isEmpty)
        XCTAssertTrue(rig.api.received.isEmpty)
    }

    func test_sameAsAutocompleteRunsOnTheProviderOfTheAutocompleteEngine() async throws {
        let request = RewriteRequest(selection: draft, action: .fixOnly, memory: .empty)
        for (engineKind, pick) in [
            (SuggestionEngineKind.appleIntelligence, \Rig.apple), (.llamaOpenSource, \Rig.openSource),
            (.openAICompatible, \Rig.endpoint), (.mlx, \Rig.mlx)
        ] {
            let rig = makeRig(RewritePreferences.defaults, autocomplete: engineKind)
            _ = try await rig.engine.rewrite(request, onPartial: { _ in })
            XCTAssertEqual(rig[keyPath: pick].received.count, 1, "\(engineKind)")
            XCTAssertTrue(rig.api.received.isEmpty)
        }
    }

    func test_anExplicitChoiceBeatsTheAutocompleteEngine() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .appleIntelligence
        let rig = makeRig(prefs, autocomplete: .mlx)
        _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .fixOnly, memory: .empty), onPartial: { _ in })
        XCTAssertEqual(rig.apple.received.count, 1)
        XCTAssertTrue(rig.mlx.received.isEmpty)
    }

    // MARK: - Memory policy on the resolved provider

    func test_memoryIsAllowedOnTheThreeLocalProviders() {
        for kind in [RewriteProviderKind.appleIntelligence, .openSource, .mlx] {
            var prefs = RewritePreferences.defaults
            prefs.provider = kind
            prefs.sendsMemoryToAPI = false
            XCTAssertTrue(makeRig(prefs).engine.memoryAllowed, "\(kind)")
        }
    }

    func test_localEndpointOnLoopbackAllowsMemory() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .localEndpoint
        prefs.sendsMemoryToAPI = false
        let rig = makeRig(prefs)
        rig.endpoint.sendsOffDevice = false
        XCTAssertTrue(rig.engine.memoryAllowed)
        _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: memory), onPartial: { _ in })
        XCTAssertEqual(rig.endpoint.received.first?.memory, memory)
    }

    func test_localEndpointOnTheLANFollowsTheMemoryToggle() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .localEndpoint
        prefs.sendsMemoryToAPI = false
        let rig = makeRig(prefs)
        rig.endpoint.sendsOffDevice = true
        XCTAssertFalse(rig.engine.memoryAllowed)
        _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: memory), onPartial: { _ in })
        XCTAssertEqual(rig.endpoint.received.first?.memory, RewriteMemoryContext.empty, "the engine strips it")

        prefs.sendsMemoryToAPI = true
        let allowed = makeRig(prefs)
        allowed.endpoint.sendsOffDevice = true
        XCTAssertTrue(allowed.engine.memoryAllowed)
    }

    func test_sameAsAutocompleteOnALANEndpointStripsMemory() async throws {
        let rig = makeRig(RewritePreferences.defaults, autocomplete: .openAICompatible)
        rig.endpoint.sendsOffDevice = true
        XCTAssertFalse(rig.engine.memoryAllowed)
        _ = try await rig.engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: memory), onPartial: { _ in })
        XCTAssertEqual(rig.endpoint.received.first?.memory, RewriteMemoryContext.empty)
    }

    func test_activeProviderFollowsTheResolvedKind() {
        let rig = makeRig(RewritePreferences.defaults, autocomplete: .mlx)
        XCTAssertTrue(rig.engine.activeProvider === rig.mlx)
        XCTAssertEqual(rig.engine.resolvedKind, .mlx)
    }

    func test_usesTheChosenProvider() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .api
        let (engine, local, api) = make(prefs)
        _ = try await engine.rewrite(RewriteRequest(selection: draft, action: .fixOnly, memory: .empty), onPartial: { _ in })
        XCTAssertEqual(api.received.count, 1)
        XCTAssertTrue(local.received.isEmpty)
    }

    func test_engineStripsMemoryForAPIWhenSendingIsOff() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .api
        prefs.sendsMemoryToAPI = false
        let (engine, _, api) = make(prefs)
        XCTAssertFalse(engine.memoryAllowed)
        _ = try await engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: memory), onPartial: { _ in })
        XCTAssertEqual(api.received.first?.memory, RewriteMemoryContext.empty)
    }

    func test_memoryReachesTheAPIOnlyWhenAllowed() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .api
        prefs.sendsMemoryToAPI = true
        let (engine, _, api) = make(prefs)
        _ = try await engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: memory), onPartial: { _ in })
        XCTAssertEqual(api.received.first?.memory, memory)
    }

    func test_localAlwaysKeepsMemory() async throws {
        let (engine, local, _) = make(RewritePreferences.defaults)
        XCTAssertTrue(engine.memoryAllowed)
        _ = try await engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: memory), onPartial: { _ in })
        XCTAssertEqual(local.received.first?.memory, memory)
    }

    func test_unavailableProviderThrowsNoProvider() async {
        let (engine, local, _) = make(RewritePreferences.defaults)
        local.isAvailable = false
        do {
            _ = try await engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: .empty), onPartial: { _ in })
            XCTFail("Expected noProvider")
        } catch {
            XCTAssertEqual(error as? RewriteError, .noProvider)
        }
    }

    func test_unusableOutputThrows() async {
        let (engine, local, _) = make(RewritePreferences.defaults)
        local.output = "   "
        do {
            _ = try await engine.rewrite(RewriteRequest(selection: draft, action: .rewrite, memory: .empty), onPartial: { _ in })
            XCTFail("Expected unusableOutput")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unusableOutput)
        }
    }

    func test_tooLongSelectionThrows() async {
        let (engine, _, _) = make(RewritePreferences.defaults)
        let long = String(repeating: "word ", count: 401)
        do {
            _ = try await engine.rewrite(RewriteRequest(selection: long, action: .rewrite, memory: .empty), onPartial: { _ in })
            XCTFail("Expected selectionTooLong")
        } catch {
            XCTAssertEqual(error as? RewriteError, .selectionTooLong)
        }
    }

    func test_languageSurvivesMemoryStrippingForTheAPI() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .api
        let (engine, _, api) = make(prefs)
        var request = RewriteRequest(selection: draft, action: .rewrite, memory: memory)
        request.language = "Turkish"
        _ = try await engine.rewrite(request, onPartial: { _ in })
        XCTAssertEqual(api.received.first?.language, "Turkish")
        XCTAssertEqual(api.received.first?.memory, .empty)
    }
}

/// Collects what the relay delivered, on the main actor where the relay delivers.
@MainActor
private final class DeliveryLog {
    private(set) var items: [String] = []
    func append(_ text: String) { items.append(text) }

}

/// The relay keeps streamed partials ordered (latest wins) and delivers nothing after `finish()`.
@MainActor
final class PartialRelayTests: XCTestCase {
    func test_relayDropsOlderPartials() async {
        let log = DeliveryLog()
        let relay = PartialRelay(deliver: { log.append($0) })
        // Send from a background thread, like the llama runtime's callback.
        await Task.detached { relay.send("a"); relay.send("ab"); relay.send("abc") }.value
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(log.items.last, "abc")
        let lengths = log.items.map(\.count)
        XCTAssertEqual(lengths, lengths.sorted(), "an older partial was delivered after a newer one")
        XCTAssertEqual(Set(lengths).count, lengths.count, "a partial was delivered twice")
    }

    func test_relayDeliversNothingAfterFinish() async {
        let log = DeliveryLog()
        let relay = PartialRelay(deliver: { log.append($0) })
        relay.send("x")
        relay.finish()
        relay.send("late")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(log.items.contains("late"), "a partial was delivered after finish()")
        XCTAssertTrue(log.items.isEmpty, "a partial sent before finish() was delivered after it")
    }

}
