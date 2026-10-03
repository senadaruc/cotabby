import Foundation
import XCTest
@testable import Cotabby

/// Pins the live half of performance tuning: the learned-profile store persists and trims, the
/// conditions monitor reads the GPU only when asked and at most every few seconds, and the tuner
/// turns mode, conditions and the current model's profile into the policy's decision.
@MainActor
final class PerformanceTunerTests: XCTestCase {
    /// App-target classes deallocated in the app-hosted runner can trip the back-deployed isolated
    /// deinit shim; keep them for the process lifetime, as the router tests do.
    private static var retained: [AnyObject] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "cotabby.test.tuner.\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func keep<T: AnyObject>(_ object: T) -> T {
        Self.retained.append(object)
        return object
    }

    // MARK: - Profile store

    func test_profileStore_persistsAcrossInstancesAndResets() {
        let defaults = makeDefaults()
        let store = keep(ModelPerformanceProfileStore(userDefaults: defaults))
        store.recordGeneration(
            modelKey: "llamaOpenSource|a.gguf", latencyMs: 300,
            stats: GenerationStats(tokensGenerated: 20, isTokenCountEstimated: false, prefillMilliseconds: 100)
        )
        store.recordShown(modelKey: "llamaOpenSource|a.gguf", words: 5)
        store.recordAccepted(modelKey: "llamaOpenSource|a.gguf", shownWords: 5)

        let reloaded = keep(ModelPerformanceProfileStore(userDefaults: defaults))
        let profile = reloaded.profile(for: "llamaOpenSource|a.gguf")
        XCTAssertEqual(profile?.sampleCount, 1)
        XCTAssertEqual(profile?.buckets[1].acceptedAny, 1)

        reloaded.reset()
        XCTAssertTrue(keep(ModelPerformanceProfileStore(userDefaults: defaults)).profiles.isEmpty)
    }

    func test_profileStore_dropsTheLeastRecentlyUpdatedModelBeyondTheCap() {
        let store = keep(ModelPerformanceProfileStore(userDefaults: makeDefaults()))
        for index in 0...ModelPerformanceProfileStore.maximumModels {
            store.recordShown(modelKey: "m\(index)", words: 3)
        }
        XCTAssertEqual(store.profiles.count, ModelPerformanceProfileStore.maximumModels)
        XCTAssertNil(store.profile(for: "m0"))
        XCTAssertNotNil(store.profile(for: "m\(ModelPerformanceProfileStore.maximumModels)"))
    }

    // MARK: - Conditions monitor

    func test_conditionsMonitor_readsTheGPUOnlyWhenAskedAndAtMostEveryInterval() {
        var reads = 0
        var clock = Date(timeIntervalSince1970: 1_000)
        let monitor = keep(PerformanceConditionsMonitor(
            powerSourceMonitor: keep(PowerSourceMonitor()),
            lowPowerModeMonitor: keep(LowPowerModeMonitor()),
            readDeviceGPUPercent: { reads += 1; return 91 },
            now: { clock }
        ))

        XCTAssertNil(monitor.currentConditions(sampleGPU: false).deviceGPUBusyPercent)
        XCTAssertEqual(reads, 0)

        XCTAssertEqual(monitor.currentConditions(sampleGPU: true).deviceGPUBusyPercent, 91)
        _ = monitor.currentConditions(sampleGPU: true)
        XCTAssertEqual(reads, 1, "a second request within the interval reuses the reading")

        clock = clock.addingTimeInterval(PerformanceConditionsMonitor.gpuSampleInterval)
        _ = monitor.currentConditions(sampleGPU: true)
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(monitor.conditions.pressures.contains(.gpuContended))
    }

    // MARK: - Tuner

    private func makeTuner(
        mode: PerformanceTuningMode,
        gpuBusy: Double? = nil,
        profile: ModelPerformanceProfile? = nil
    ) -> (PerformanceTuner, SuggestionSettingsModel) {
        let defaults = makeDefaults()
        let settings = keep(SuggestionSettingsModel(configuration: .standard, userDefaults: defaults))
        settings.setPerformanceTuningMode(mode)
        let store = keep(ModelPerformanceProfileStore(userDefaults: defaults))
        let key = GenerationStats.modelKey(engine: .llamaOpenSource, modelName: "m.gguf")
        if let profile {
            // Build the stored profile through the public recorders so the store holds exactly it.
            for _ in 0..<profile.sampleCount {
                store.recordGeneration(
                    modelKey: key, latencyMs: (profile.prefillMs ?? 0) + (profile.msPerToken ?? 0) * 20,
                    stats: GenerationStats(tokensGenerated: 20, isTokenCountEstimated: false, prefillMilliseconds: profile.prefillMs)
                )
            }
        }
        let monitor = keep(PerformanceConditionsMonitor(
            powerSourceMonitor: keep(PowerSourceMonitor()),
            lowPowerModeMonitor: keep(LowPowerModeMonitor()),
            readDeviceGPUPercent: { gpuBusy }
        ))
        let tuner = keep(PerformanceTuner(
            suggestionSettings: settings,
            conditionsMonitor: monitor,
            profileStore: store,
            modelKeyProvider: { engine in GenerationStats.modelKey(engine: engine, modelName: "m.gguf") }
        ))
        return (tuner, settings)
    }

    func test_tuner_offLeavesEveryRequestUnchanged() {
        let (tuner, settings) = makeTuner(mode: .off, gpuBusy: 99)
        XCTAssertEqual(tuner.tuning(for: settings.snapshot), .unchanged)
        XCTAssertEqual(tuner.lastTuning, .unchanged)
    }

    func test_tuner_contendedGPUPullsTheLeversAndPublishesThem() {
        let (tuner, settings) = makeTuner(mode: .balanced, gpuBusy: 95)
        let tuning = tuner.tuning(for: settings.snapshot)
        XCTAssertFalse(tuning.allowsVisualContext)
        XCTAssertEqual(tuner.lastTuning, tuning)
        XCTAssertEqual(tuner.lastModelKey, GenerationStats.modelKey(engine: .llamaOpenSource, modelName: "m.gguf"))
    }

    func test_tuner_fitsTheCurrentModelsSpeedInsideTheUsersRange() {
        var slow = ModelPerformanceProfile()
        slow.sampleCount = 25
        slow.prefillMs = 100
        slow.msPerToken = 25
        let (tuner, settings) = makeTuner(mode: .balanced, gpuBusy: 10, profile: slow)
        settings.selectEngine(.llamaOpenSource)

        let tuning = tuner.tuning(for: settings.snapshot)

        // 25 ms/token fits about 10 words in 450 ms (6 on battery), both under the default
        // 12-20 range, so the tuned range is the user's own minimum whatever the test Mac's power.
        let user = settings.snapshot.userWordRange
        XCTAssertEqual(tuning.wordRange, SuggestionWordRange.clamped(low: user.lowWords, high: user.lowWords))
        XCTAssertNotNil(tuning.targetLatencyMs)
    }
}
