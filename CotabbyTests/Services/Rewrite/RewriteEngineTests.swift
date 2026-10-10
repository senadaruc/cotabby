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

    private func make(_ prefs: RewritePreferences) -> (RewriteEngine, StubProvider, StubProvider) {
        let local = StubProvider(offDevice: false)
        let api = StubProvider(offDevice: true)
        let engine = RewriteEngine(local: local, api: api, preferences: { prefs })
        Self.retained.append(contentsOf: [engine, local, api] as [AnyObject])
        return (engine, local, api)
    }

    func test_usesTheChosenProvider() async throws {
        var prefs = RewritePreferences.defaults
        prefs.provider = .api
        let (engine, local, api) = make(prefs)
        _ = try await engine.rewrite(RewriteRequest(selection: draft, action: .fixGrammar, memory: .empty), onPartial: { _ in })
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
