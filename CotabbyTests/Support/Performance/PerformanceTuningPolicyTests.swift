import XCTest
@testable import Cotabby

/// Pins the performance tuner's rules: it only ever holds back inside the user's own range, fits
/// length to a model's measured speed, caps it at the length that gets accepted, pulls the battery
/// levers under pressure, and keeps length steady against small changes.
final class PerformanceTuningPolicyTests: XCTestCase {
    private let userRange = SuggestionWordRange.clamped(low: 4, high: 20)

    /// A model with enough samples at `msPerToken`, with `prefillMs` of prompt time per request.
    private func profile(msPerToken: Double, prefillMs: Double = 100, samples: Int = 40) -> ModelPerformanceProfile {
        var profile = ModelPerformanceProfile()
        profile.sampleCount = samples
        profile.msPerToken = msPerToken
        profile.prefillMs = prefillMs
        return profile
    }

    private func input(
        mode: PerformanceTuningMode = .balanced,
        conditions: PerformanceConditions = .unconstrained,
        profile: ModelPerformanceProfile? = nil,
        previousHighWords: Int? = nil
    ) -> PerformanceTuningPolicy.Input {
        PerformanceTuningPolicy.Input(
            mode: mode, conditions: conditions, profile: profile, userRange: userRange,
            tokensPerWord: 1.3, previousHighWords: previousHighWords
        )
    }

    private var onBattery: PerformanceConditions {
        var conditions = PerformanceConditions.unconstrained
        conditions.isOnBattery = true
        return conditions
    }

    // MARK: - Nothing to react to

    func test_offAlwaysLeavesTheSettingsAlone() {
        XCTAssertEqual(PerformanceTuningPolicy.tuning(input(mode: .off, conditions: onBattery, profile: profile(msPerToken: 50))), .unchanged)
    }

    func test_aFastModelPluggedInKeepsTheUsersRange() {
        // 20 words × 1.3 = 26 tokens × 10 ms + 100 ms prefill = 360 ms, inside the 450 ms target.
        let tuning = PerformanceTuningPolicy.tuning(input(profile: profile(msPerToken: 10)))
        XCTAssertNil(tuning.wordRange)
        XCTAssertFalse(tuning.isHoldingBack)
    }

    func test_tooFewSamplesDoNotShortenAnything() {
        let tuning = PerformanceTuningPolicy.tuning(input(profile: profile(msPerToken: 50, samples: 5)))
        XCTAssertNil(tuning.wordRange)
    }

    // MARK: - Latency fit

    func test_aSlowModelIsFittedToTheTargetWithinTheUsersRange() {
        // (450 - 100) / 25 ms = 14 tokens / 1.3 = 10 words.
        let tuning = PerformanceTuningPolicy.tuning(input(profile: profile(msPerToken: 25)))
        XCTAssertEqual(tuning.wordRange, SuggestionWordRange.clamped(low: 4, high: 10))
        XCTAssertEqual(tuning.targetLatencyMs, 450)
        XCTAssertTrue(tuning.reasons.contains("fits 450 ms on this model"))
    }

    func test_neverDropsBelowTheUsersMinimum() {
        // Prefill alone exceeds the target.
        let tuning = PerformanceTuningPolicy.tuning(input(profile: profile(msPerToken: 40, prefillMs: 600)))
        XCTAssertEqual(tuning.wordRange, SuggestionWordRange.clamped(low: 4, high: 4))
    }

    func test_batteryTightensTheTargetAndPullsEveryLever() {
        // (300 - 100) / 10 ms = 20 tokens / 1.3 = 15 words.
        let tuning = PerformanceTuningPolicy.tuning(input(conditions: onBattery, profile: profile(msPerToken: 10)))
        XCTAssertEqual(tuning.targetLatencyMs, 300)
        XCTAssertEqual(tuning.wordRange?.highWords, 15)
        XCTAssertEqual(tuning.debounceFloorMilliseconds, PerformanceTuningPolicy.pressuredDebounceFloorMs)
        XCTAssertFalse(tuning.allowsVisualContext)
        XCTAssertFalse(tuning.allowsPredictAhead)
        XCTAssertFalse(tuning.allowsMemoryRetrieval)
        XCTAssertEqual(tuning.reasons.first, "On battery")
    }

    func test_aHotMacTightensTheTargetFurther() {
        var hot = onBattery
        hot.thermal = .serious
        let tuning = PerformanceTuningPolicy.tuning(input(conditions: hot, profile: profile(msPerToken: 10)))
        XCTAssertEqual(tuning.targetLatencyMs, 210)
        XCTAssertTrue(tuning.reasons.contains("Mac is hot"))
    }

    func test_aContendedGPUCountsAsPressure() {
        var busy = PerformanceConditions.unconstrained
        busy.deviceGPUBusyPercent = 92
        let tuning = PerformanceTuningPolicy.tuning(input(conditions: busy))
        XCTAssertFalse(tuning.allowsVisualContext)
        XCTAssertEqual(tuning.reasons.first, "GPU busy (92%)")

        busy.deviceGPUBusyPercent = 40
        XCTAssertFalse(PerformanceTuningPolicy.tuning(input(conditions: busy)).isHoldingBack)
    }

    func test_batterySaverHoldsBackEvenWhenPluggedIn() {
        let tuning = PerformanceTuningPolicy.tuning(input(mode: .batterySaver, profile: profile(msPerToken: 10)))
        XCTAssertEqual(tuning.targetLatencyMs, 250)
        XCTAssertFalse(tuning.allowsPredictAhead)
        XCTAssertEqual(tuning.reasons.first, "Battery Saver")
    }

    func test_maxQualityKeepsLengthUntilTheMacIsCriticallyHot() {
        let slow = profile(msPerToken: 40)
        let calm = PerformanceTuningPolicy.tuning(input(mode: .maxQuality, conditions: onBattery, profile: slow))
        XCTAssertEqual(calm, PerformanceTuning(reasons: []))
        XCTAssertFalse(calm.isHoldingBack)

        var critical = onBattery
        critical.thermal = .critical
        let hot = PerformanceTuningPolicy.tuning(input(mode: .maxQuality, conditions: critical, profile: slow))
        XCTAssertNotNil(hot.wordRange)
        XCTAssertFalse(hot.allowsVisualContext)
        XCTAssertTrue(hot.reasons.contains("Mac is very hot"))
    }

    // MARK: - Acceptance cap

    private func profile(shownAndAccepted: [(shown: Int, accepted: Int)]) -> ModelPerformanceProfile {
        var profile = ModelPerformanceProfile()
        for (index, counts) in shownAndAccepted.enumerated() {
            profile.buckets[index].shown = counts.shown
            profile.buckets[index].acceptedAny = counts.accepted
        }
        return profile
    }

    func test_longBandsAcceptedFarLessAreCappedAtTheBestBand() {
        // 4-7 words: 20% accepted; 13-20 words: 2% accepted.
        let learned = profile(shownAndAccepted: [(0, 0), (50, 10), (40, 4), (300, 6)])
        XCTAssertEqual(PerformanceTuningPolicy.acceptanceCappedWords(learned), 7)
        let tuning = PerformanceTuningPolicy.tuning(input(profile: learned))
        XCTAssertEqual(tuning.wordRange, SuggestionWordRange.clamped(low: 4, high: 7))
        XCTAssertTrue(tuning.reasons.contains("shorter suggestions get accepted more"))
    }

    func test_bandsWithTooFewSamplesAreIgnored() {
        let learned = profile(shownAndAccepted: [(0, 0), (10, 5), (0, 0), (300, 6)])
        XCTAssertNil(PerformanceTuningPolicy.acceptanceCappedWords(learned))
    }

    func test_similarRatesDoNotCap() {
        let learned = profile(shownAndAccepted: [(0, 0), (50, 5), (0, 0), (100, 7)])
        XCTAssertNil(PerformanceTuningPolicy.acceptanceCappedWords(learned))
    }

    // MARK: - Hysteresis

    func test_smallChangesKeepThePreviousLength() {
        // Fits 10 words, but 11 was applied last time: one word is not worth a visible change.
        let kept = PerformanceTuningPolicy.tuning(input(profile: profile(msPerToken: 25), previousHighWords: 11))
        XCTAssertEqual(kept.wordRange?.highWords, 11)

        let moved = PerformanceTuningPolicy.tuning(input(profile: profile(msPerToken: 25), previousHighWords: 14))
        XCTAssertEqual(moved.wordRange?.highWords, 10)
    }

    func test_aFitNearTheUsersMaximumKeepsTheUsersRange() {
        // Fits 19 of 20 words: within hysteresis of "no cap" (previous = the user's 20).
        let tuning = PerformanceTuningPolicy.tuning(input(profile: profile(msPerToken: 13.6), previousHighWords: 20))
        XCTAssertNil(tuning.wordRange)
    }
}

/// The per-model learning arithmetic.
final class ModelPerformanceProfileTests: XCTestCase {
    func test_firstGenerationSetsTheAveragesAndLaterOnesSmooth() {
        let first = ModelPerformanceProfile().recordingGeneration(latencyMs: 300, tokens: 20, prefillMs: 100)
        XCTAssertEqual(first.sampleCount, 1)
        XCTAssertEqual(first.msPerToken, 10)
        XCTAssertEqual(first.prefillMs, 100)
        XCTAssertFalse(first.isTimingCoarse)

        let second = first.recordingGeneration(latencyMs: 500, tokens: 20, prefillMs: 100)
        XCTAssertEqual(second.msPerToken ?? 0, 10 + 0.1 * (20 - 10), accuracy: 1e-9)
        XCTAssertEqual(second.sampleCount, 2)
    }

    func test_enginesWithoutPrefillTimingSpreadLatencyOverTokensAndMarkItCoarse() {
        let profile = ModelPerformanceProfile().recordingGeneration(latencyMs: 400, tokens: 20, prefillMs: nil)
        XCTAssertEqual(profile.msPerToken, 20)
        XCTAssertEqual(profile.prefillMs, 0)
        XCTAssertTrue(profile.isTimingCoarse)
    }

    func test_generationsWithoutTokensAreSkipped() {
        XCTAssertEqual(ModelPerformanceProfile().recordingGeneration(latencyMs: 300, tokens: 0, prefillMs: 50), ModelPerformanceProfile())
    }

    func test_shownAndAcceptedLandInTheirLengthBand() {
        let profile = ModelPerformanceProfile()
            .recordingShown(words: 5)
            .recordingShown(words: 18)
            .recordingAccepted(shownWords: 5)
        XCTAssertEqual(profile.buckets[1].shown, 1)
        XCTAssertEqual(profile.buckets[1].acceptedAny, 1)
        XCTAssertEqual(profile.buckets[3].shown, 1)
        XCTAssertEqual(ModelPerformanceProfile.bucketIndex(forWords: 50), 4)
        XCTAssertEqual(ModelPerformanceProfile.bucketRange(at: 2), 8...12)
    }

    func test_codableRoundTripAndShapeRepair() throws {
        let profile = ModelPerformanceProfile().recordingGeneration(latencyMs: 300, tokens: 20, prefillMs: 100).recordingShown(words: 3)
        let decoded = try JSONDecoder().decode(ModelPerformanceProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)

        var short = profile
        short.buckets = [short.buckets[0]]
        XCTAssertEqual(short.normalized().buckets.count, ModelPerformanceProfile.bucketUpperBounds.count)
        XCTAssertEqual(short.normalized().buckets[0].shown, 1)
    }
}
