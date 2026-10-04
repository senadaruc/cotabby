import Foundation
import XCTest
@testable import Cotabby

/// Locks the engine routing contract: which backend serves a request for each selected engine,
/// when the Apple Intelligence locale failure falls back to the local model, and when a finished
/// result lands in the performance ring buffer. A routing regression silently sends every request
/// to the wrong backend, so each path asserts which engine was actually asked.
@MainActor
final class SuggestionEngineRouterRoutingTests: XCTestCase {
    /// Production classes built with the app target's default MainActor isolation crash the
    /// app-hosted runner when deallocated (back-deploy executor shim); quarantine them for the
    /// process lifetime instead.
    private static var retained: [AnyObject] = []

    private struct Rig {
        let router: SuggestionEngineRouter
        let settings: SuggestionSettingsModel
        let foundation: ScriptedEngine
        let llama: ScriptedEngine
        let endpoint: ScriptedEngine
        let metrics: PerformanceMetricsStore
        let quality: SuggestionQualityMetricsStore
        let profiles: ModelPerformanceProfileStore
    }

    @MainActor
    private final class ScriptedEngine: SuggestionGenerating {
        var script: (SuggestionRequest) async throws -> SuggestionResult
        private(set) var requests: [SuggestionRequest] = []
        private(set) var prewarmCount = 0
        private(set) var resetCount = 0

        init(latency: TimeInterval = 0.02) {
            script = { request in
                SuggestionResult(generation: request.generation, rawText: " ok", text: " ok", latency: latency)
            }
        }

        func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
            requests.append(request)
            return try await script(request)
        }

        func resetCachedGenerationContext() async {
            resetCount += 1
        }

        func prewarm(for request: SuggestionRequest) async {
            prewarmCount += 1
        }
    }

    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "cotabby.test.router.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeRig(
        engine: SuggestionEngineKind,
        performanceTracking: Bool = true,
        llamaModelName: String? = "test-model.gguf"
    ) -> Rig {
        let defaults = makeDefaults()
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        settings.selectEngine(engine)
        settings.setPerformanceTrackingEnabled(performanceTracking)
        let metrics = PerformanceMetricsStore(userDefaults: defaults)
        let profiles = ModelPerformanceProfileStore(userDefaults: defaults)
        let foundation = ScriptedEngine()
        let llama = ScriptedEngine()
        let endpoint = ScriptedEngine()
        let quality = SuggestionQualityMetricsStore(userDefaults: defaults)
        let router = SuggestionEngineRouter(
            suggestionSettings: settings,
            foundationModelEngine: foundation,
            llamaEngine: llama,
            performanceMetricsStore: metrics,
            qualityMetricsStore: quality,
            llamaModelNameProvider: { llamaModelName },
            openAICompatibleEngine: endpoint,
            endpointModelNameProvider: { "endpoint-model" },
            profileStore: profiles
        )
        Self.retained.append(contentsOf: [router, settings, metrics, quality, profiles] as [AnyObject])
        return Rig(
            router: router,
            settings: settings,
            foundation: foundation,
            llama: llama,
            endpoint: endpoint,
            metrics: metrics,
            quality: quality,
            profiles: profiles
        )
    }

    // MARK: - Performance learning

    /// A llama result carries the runtime's own token count and decode timing; the router stamps
    /// the engine|model key, teaches the profile, and records the richer Recent Requests entry.
    func test_llamaStatsTeachTheModelProfileAndTheRecentRequestsEntry() async throws {
        let rig = makeRig(engine: .llamaOpenSource)
        rig.llama.script = { request in
            var result = SuggestionResult(generation: request.generation, rawText: " ok", text: " ok", latency: 0.3)
            result.stats = GenerationStats(tokensGenerated: 20, isTokenCountEstimated: false, prefillMilliseconds: 100, stopReason: "eos")
            return result
        }

        let result = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        let key = GenerationStats.modelKey(engine: .llamaOpenSource, modelName: "test-model.gguf")
        XCTAssertEqual(result.stats?.modelKey, key)
        let profile = try XCTUnwrap(rig.profiles.profile(for: key))
        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertEqual(profile.msPerToken ?? 0, 10, accuracy: 0.001)
        XCTAssertFalse(profile.isTimingCoarse)
        let entry = try XCTUnwrap(rig.metrics.entries.first)
        XCTAssertEqual(entry.engine, "llama")
        XCTAssertEqual(entry.tokens, 20)
        XCTAssertEqual(entry.stopReason, "eos")
        XCTAssertEqual(entry.tokensEstimated, false)
    }

    /// Engines that report no tokens get an estimate from the text, and their timing is coarse.
    func test_enginesWithoutStatsGetAnEstimateMarkedCoarse() async throws {
        let rig = makeRig(engine: .appleIntelligence)

        let result = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.stats?.isTokenCountEstimated, true)
        let key = GenerationStats.modelKey(engine: .appleIntelligence, modelName: "Apple Intelligence")
        XCTAssertEqual(rig.profiles.profile(for: key)?.isTimingCoarse, true)
        XCTAssertEqual(rig.metrics.entries.first?.tokensEstimated, true)
    }

    /// An empty decode says nothing about speed, so it is not learned from.
    func test_emptyResultsDoNotTeachTheProfile() async throws {
        let rig = makeRig(engine: .llamaOpenSource)
        rig.llama.script = { request in
            SuggestionResult(generation: request.generation, rawText: "", text: "", latency: 0.2)
        }

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertTrue(rig.profiles.profiles.isEmpty)
    }

    func test_appleIntelligenceSelection_routesToFoundationEngineAndRecordsMetric() async throws {
        let rig = makeRig(engine: .appleIntelligence)

        let result = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.text, " ok")
        XCTAssertEqual(rig.foundation.requests.count, 1)
        XCTAssertTrue(rig.llama.requests.isEmpty)
        XCTAssertEqual(rig.metrics.entries.first?.modelName, "Apple Intelligence")
        XCTAssertEqual(rig.metrics.entries.first?.latencyMs, 20)
    }

    func test_endpointNeverReceivesARequestCarryingConversationMemory() async throws {
        let rig = makeRig(engine: .openAICompatible)

        let result = try await rig.router.generateSuggestion(
            for: CotabbyTestFixtures.suggestionRequest(memorySnippets: ["12 Sep · Ayşe: the invoice is paid"])
        )

        XCTAssertTrue(rig.endpoint.requests.isEmpty)
        XCTAssertEqual(result.suppressionReason, "memoryWithheldFromEndpoint")
    }

    func test_endpointNeverReceivesARequestCarryingTypingHistory() async throws {
        let rig = makeRig(engine: .openAICompatible)

        let result = try await rig.router.generateSuggestion(
            for: CotabbyTestFixtures.suggestionRequest(historyExamples: ["My earlier sentence."])
        )

        XCTAssertTrue(rig.endpoint.requests.isEmpty)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppressionReason, "historyWithheldFromEndpoint")
    }

    func test_llamaSelection_routesToLlamaEngineAndRecordsTheModelName() async throws {
        let rig = makeRig(engine: .llamaOpenSource)

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(rig.llama.requests.count, 1)
        XCTAssertTrue(rig.foundation.requests.isEmpty)
        XCTAssertEqual(rig.metrics.entries.first?.modelName, "test-model.gguf")
    }

    func test_llamaSelection_missingModelNameFallsBackToGenericLabel() async throws {
        let rig = makeRig(engine: .llamaOpenSource, llamaModelName: nil)

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(rig.metrics.entries.first?.modelName, "Llama")
    }

    func test_endpointSelection_routesToEndpointAndRecordsModelName() async throws {
        let rig = makeRig(engine: .openAICompatible)

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(rig.endpoint.requests.count, 1)
        XCTAssertTrue(rig.foundation.requests.isEmpty)
        XCTAssertTrue(rig.llama.requests.isEmpty)
        XCTAssertEqual(rig.metrics.entries.first?.modelName, "endpoint-model")
    }

    func test_performanceTrackingOff_recordsNothing() async throws {
        let rig = makeRig(engine: .llamaOpenSource, performanceTracking: false)

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertTrue(rig.metrics.entries.isEmpty, "The default user must never pay the metrics write cost")
    }

    func test_unsupportedLocale_fallsBackToLlamaAndReturnsItsResult() async throws {
        let rig = makeRig(engine: .appleIntelligence)
        rig.foundation.script = { _ in
            throw SuggestionClientError.unsupportedLanguageOrLocale("Locale not supported.")
        }

        let result = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.text, " ok")
        XCTAssertEqual(rig.llama.requests.count, 1, "The locale failure must reach the local model")
        XCTAssertEqual(rig.metrics.entries.first?.modelName, "test-model.gguf")
    }

    func test_unsupportedLocale_withFallbackOff_returnsNoSuggestionAndSkipsTheLocalModel() async throws {
        let rig = makeRig(engine: .appleIntelligence)
        rig.settings.setAppleLanguageFallbackEnabled(false)
        rig.foundation.script = { _ in
            throw SuggestionClientError.unsupportedLanguageOrLocale("Locale not supported.")
        }

        let result = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.suppressionReason, "appleLanguageUnsupported")
        XCTAssertTrue(rig.llama.requests.isEmpty, "With the fallback off the local model must not run")
    }

    func test_fallbackSettingsDefaultToTodaysBehaviorAndPersist() {
        let defaults = makeDefaults()
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        Self.retained.append(settings)
        XCTAssertTrue(settings.isAppleLanguageFallbackEnabled)
        XCTAssertFalse(settings.keepsFallbackModelLoaded)

        settings.setAppleLanguageFallbackEnabled(false)
        settings.setKeepsFallbackModelLoaded(true)

        let reloaded = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        Self.retained.append(reloaded)
        XCTAssertFalse(reloaded.isAppleLanguageFallbackEnabled)
        XCTAssertTrue(reloaded.keepsFallbackModelLoaded)
    }

    func test_unsupportedLocale_fallbackFailureComposesBothMessages() async {
        let rig = makeRig(engine: .appleIntelligence)
        rig.foundation.script = { _ in
            throw SuggestionClientError.unsupportedLanguageOrLocale("Locale not supported.")
        }
        rig.llama.script = { _ in throw SuggestionClientError.unavailable("No model installed.") }

        do {
            _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("Expected the composed unavailable error")
        } catch let SuggestionClientError.unavailable(message) {
            XCTAssertEqual(message, "Locale not supported. Open Source fallback also failed: No model installed.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(rig.quality.counters.generated, 0, "A failed fallback produced no generation")
    }

    /// Only the locale rejection is a fallback trigger. Any other Apple failure (model still
    /// downloading, guardrails, cancellation) must surface unchanged without waking the llama path.
    func test_nonLocaleAppleFailures_propagateWithoutFallback() async {
        let rig = makeRig(engine: .appleIntelligence)
        let failures: [SuggestionClientError] = [
            .unavailable("Model still downloading."),
            .generationFailed("Guardrail."),
            .cancelled
        ]

        for failure in failures {
            rig.foundation.script = { _ in throw failure }
            do {
                _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
                XCTFail("Expected \(failure) to propagate")
            } catch let error as SuggestionClientError {
                XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(rig.llama.requests.isEmpty)
        XCTAssertTrue(rig.metrics.entries.isEmpty)
    }

    func test_qualityCounters_recordEveryFinishedGenerationEvenWithPerformanceTrackingOff() async throws {
        let rig = makeRig(engine: .llamaOpenSource, performanceTracking: false)
        rig.llama.script = { request in
            SuggestionResult(
                generation: request.generation,
                rawText: " Hello",
                text: "",
                latency: 0.01,
                suppressionReason: "echo"
            )
        }

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
        rig.llama.script = { request in
            SuggestionResult(generation: request.generation, rawText: " ok", text: " ok", latency: 0.01)
        }
        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(rig.quality.counters.generated, 2)
        XCTAssertEqual(rig.quality.counters.suppressedByReason, ["echo": 1])
        XCTAssertTrue(rig.metrics.entries.isEmpty)
    }

    func test_missingEndpointEngineAndModelName_useUnavailableEngineAndGenericLabel() async throws {
        let rig = makeRig(engine: .openAICompatible)
        let defaults = makeDefaults()
        let metrics = PerformanceMetricsStore(userDefaults: defaults)
        let bareRouter = SuggestionEngineRouter(
            suggestionSettings: rig.settings,
            foundationModelEngine: rig.foundation,
            llamaEngine: rig.llama,
            performanceMetricsStore: metrics,
            qualityMetricsStore: SuggestionQualityMetricsStore(userDefaults: defaults),
            llamaModelNameProvider: { nil }
        )
        Self.retained.append(contentsOf: [bareRouter, metrics] as [AnyObject])

        do {
            _ = try await bareRouter.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("Expected the placeholder endpoint engine to be unavailable")
        } catch let SuggestionClientError.unavailable(message) {
            XCTAssertEqual(message, "Configure a local OpenAI-compatible endpoint in Settings.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let labelRouter = SuggestionEngineRouter(
            suggestionSettings: rig.settings,
            foundationModelEngine: rig.foundation,
            llamaEngine: rig.llama,
            performanceMetricsStore: metrics,
            qualityMetricsStore: SuggestionQualityMetricsStore(userDefaults: defaults),
            llamaModelNameProvider: { nil },
            openAICompatibleEngine: rig.endpoint
        )
        Self.retained.append(labelRouter)
        _ = try await labelRouter.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(metrics.entries.first?.modelName, "Local Endpoint")
    }

    func test_unsupportedLocale_fallbackCancellationStaysCancellation() async {
        let rig = makeRig(engine: .appleIntelligence)
        rig.foundation.script = { _ in
            throw SuggestionClientError.unsupportedLanguageOrLocale("Locale not supported.")
        }
        rig.llama.script = { _ in throw SuggestionClientError.cancelled }

        do {
            _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("Expected cancellation to propagate")
        } catch SuggestionClientError.cancelled {
            // Cancellation must never be rewrapped as unavailability: the coordinator treats it
            // as silence, not as an error state.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_prewarm_reachesOnlyTheSelectedEngine() async {
        let appleRig = makeRig(engine: .appleIntelligence)
        await appleRig.router.prewarm(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(appleRig.foundation.prewarmCount, 1)
        XCTAssertEqual(appleRig.llama.prewarmCount, 0)

        let llamaRig = makeRig(engine: .llamaOpenSource)
        await llamaRig.router.prewarm(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(llamaRig.foundation.prewarmCount, 0)
        XCTAssertEqual(llamaRig.llama.prewarmCount, 1)

        let endpointRig = makeRig(engine: .openAICompatible)
        await endpointRig.router.prewarm(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(endpointRig.endpoint.prewarmCount, 1)
    }

    func test_resetCachedGenerationContext_fansOutToAllEngines() async {
        let rig = makeRig(engine: .appleIntelligence)

        await rig.router.resetCachedGenerationContext()

        XCTAssertEqual(rig.foundation.resetCount, 1)
        XCTAssertEqual(rig.llama.resetCount, 1, "Switching engines must not leave stale state behind")
        XCTAssertEqual(rig.endpoint.resetCount, 1)
    }
}
