import Foundation

/// File overview:
/// Decides, for one request, how much Cotabby should hold back: how long the suggestion may be,
/// how calmly to react to typing, and whether to spend energy on screen text and predict-ahead.
///
/// Why a pure policy: the inputs (the user's chosen mode and word range, the machine's conditions,
/// and what has been learned about the model) all exist elsewhere as values, and the decision is a
/// handful of rules that must stay explainable, because the Performance pane shows the user why
/// suggestions are shorter right now. Keeping it free of AppKit, timers and storage means every
/// rule below has a unit test, and the coordinator only applies the result.
///
/// The policy only ever holds back: the word range it returns is always inside the user's own
/// range, and with nothing to react to it returns `PerformanceTuning.unchanged`.

/// What the tuner decided for one request. `unchanged` means "use the saved settings exactly".
struct PerformanceTuning: Equatable, Sendable {
    /// A shorter range to use instead of the user's, or nil to keep theirs.
    var wordRange: SuggestionWordRange?
    /// The least time to wait after typing before generating, or nil to keep the adaptive debounce.
    var debounceFloorMilliseconds: Int?
    var allowsVisualContext = true
    var allowsPredictAhead = true
    /// Whether conversation memory may be looked up (an embedding pass per new query).
    var allowsMemoryRetrieval = true
    /// The end-to-end latency the length was fitted to, or nil when length was not fitted.
    var targetLatencyMs: Int?
    /// Plain-language reasons, in order, for the Performance pane and the logs.
    var reasons: [String] = []

    static let unchanged = PerformanceTuning()

    var isHoldingBack: Bool {
        wordRange != nil || debounceFloorMilliseconds != nil || !allowsVisualContext || !allowsPredictAhead
            || !allowsMemoryRetrieval
    }
}

enum PerformanceTuningPolicy {
    struct Input: Equatable {
        var mode: PerformanceTuningMode
        var conditions: PerformanceConditions
        /// What has been learned about the model that will answer this request; nil before its first
        /// generation.
        var profile: ModelPerformanceProfile?
        /// The user's own range from Settings, which tuning never exceeds.
        var userRange: SuggestionWordRange
        /// Tokens per word for the user's languages (`LanguageCatalog.effectiveTokensPerWord`).
        var tokensPerWord: Double
        /// The upper bound applied to this model last time, for hysteresis; nil when none was.
        var previousHighWords: Int?
    }

    /// End-to-end targets the length is fitted to. Plugged in, a suggestion should land within a
    /// typing pause; on battery a shorter decode saves GPU energy on every suggestion.
    static let pluggedInTargetMs = 450
    static let pressuredTargetMs = 300
    static let batterySaverTargetMs = 250
    /// A seriously hot Mac gets a tighter target on top of the mode's own.
    static let hotTargetFactor = 0.7
    /// Generations needed before the measured speed is trusted to shorten suggestions.
    static let minimumTimingSamples = 20
    /// Suggestions a length band needs before its acceptance rate is trusted.
    static let minimumBucketSamples = 30
    /// A longer band is capped when it is accepted less than this share as often as the best band.
    static let acceptanceRatioCap = 0.5
    /// The upper bound moves only by at least this many words, so length does not flicker.
    static let hysteresisWords = 2
    /// Least debounce under pressure: one decode per typing pause instead of one per keystroke.
    static let pressuredDebounceFloorMs = 120

    static func tuning(_ input: Input) -> PerformanceTuning {
        guard input.mode != .off else { return .unchanged }
        let pressures = input.conditions.pressures
        let isPressured: Bool
        switch input.mode {
        case .off: isPressured = false
        case .balanced: isPressured = !pressures.isEmpty
        case .batterySaver: isPressured = true
        case .maxQuality: isPressured = input.conditions.thermal == .critical
        }

        var tuning = PerformanceTuning()
        tuning.reasons = pressureReasons(input, isPressured: isPressured)

        // Length. Max Quality keeps the user's length unless the Mac is critically hot.
        let fitsLength = input.mode != .maxQuality || isPressured
        if fitsLength {
            tuning.targetLatencyMs = targetLatency(input, isPressured: isPressured)
            if let range = tunedRange(input, targetLatencyMs: tuning.targetLatencyMs, reasons: &tuning.reasons) {
                tuning.wordRange = range
            }
        }

        if isPressured {
            tuning.debounceFloorMilliseconds = pressuredDebounceFloorMs
            tuning.allowsVisualContext = false
            tuning.allowsPredictAhead = false
            tuning.allowsMemoryRetrieval = false
            tuning.reasons.append(contentsOf: ["calmer typing reaction", "screen text off", "predict-ahead paused",
                                               "memory paused"])
        }
        return tuning
    }

    // MARK: - Steps

    private static func targetLatency(_ input: Input, isPressured: Bool) -> Int {
        var target: Double
        switch input.mode {
        case .batterySaver: target = Double(batterySaverTargetMs)
        case .off, .balanced, .maxQuality: target = Double(isPressured ? pressuredTargetMs : pluggedInTargetMs)
        }
        if input.conditions.thermal == .serious || input.conditions.thermal == .critical {
            target *= hotTargetFactor
        }
        return Int(target.rounded())
    }

    /// The shorter range to use, or nil to keep the user's. The latency fit and the acceptance cap
    /// each propose an upper bound; the lower wins, it never drops below the user's minimum, and it
    /// only moves when the change is worth a visible difference.
    private static func tunedRange(
        _ input: Input,
        targetLatencyMs: Int?,
        reasons: inout [String]
    ) -> SuggestionWordRange? {
        let user = input.userRange
        var high = user.highWords

        if let target = targetLatencyMs, let fitted = latencyFittedWords(input, targetLatencyMs: target), fitted < high {
            high = fitted
            reasons.append("fits \(target) ms on this model")
        }
        if input.mode != .maxQuality, let capped = acceptanceCappedWords(input.profile), capped < high {
            high = capped
            reasons.append("shorter suggestions get accepted more")
        }
        high = max(high, user.lowWords)

        if let previous = input.previousHighWords, abs(previous - high) < hysteresisWords {
            high = min(max(previous, user.lowWords), user.highWords)
        }
        guard high < user.highWords else { return nil }
        let range = SuggestionWordRange.clamped(low: user.lowWords, high: high)
        reasons.append("\(range.lowWords)-\(range.highWords) words")
        return range
    }

    /// Words that fit the latency target on this model: what is left of the target after prompt
    /// processing, divided by the time per token, converted to words for the user's languages.
    static func latencyFittedWords(_ input: Input, targetLatencyMs: Int) -> Int? {
        guard let profile = input.profile,
              profile.sampleCount >= minimumTimingSamples,
              let msPerToken = profile.msPerToken, msPerToken > 0,
              input.tokensPerWord > 0
        else { return nil }
        let remaining = Double(targetLatencyMs) - (profile.prefillMs ?? 0)
        guard remaining > 0 else { return input.userRange.lowWords }
        let words = Int((remaining / msPerToken / input.tokensPerWord).rounded(.down))
        return max(words, input.userRange.lowWords)
    }

    /// The upper bound of the best-accepted length band, when a longer band with enough samples is
    /// accepted less than half as often. Suggestions the user keeps ignoring at their full length
    /// cost a whole decode each; stopping at the length that gets taken saves that work and shows
    /// what is likely to be used.
    static func acceptanceCappedWords(_ profile: ModelPerformanceProfile?) -> Int? {
        guard let profile else { return nil }
        let rated = profile.buckets.enumerated().compactMap { index, bucket -> (index: Int, rate: Double)? in
            guard bucket.shown >= minimumBucketSamples, let rate = bucket.acceptanceRate else { return nil }
            return (index, rate)
        }
        guard let best = rated.max(by: { $0.rate < $1.rate }), best.rate > 0 else { return nil }
        let longerIsWorse = rated.contains { $0.index > best.index && $0.rate < best.rate * acceptanceRatioCap }
        return longerIsWorse ? ModelPerformanceProfile.bucketUpperBounds[best.index] : nil
    }

    private static func pressureReasons(_ input: Input, isPressured: Bool) -> [String] {
        guard isPressured else { return [] }
        if input.mode == .batterySaver, input.conditions.pressures.isEmpty {
            return ["Battery Saver"]
        }
        return input.conditions.pressures.map { pressure in
            switch pressure {
            case .battery: return "On battery"
            case .lowPowerMode: return "Low Power Mode"
            case .hot: return input.conditions.thermal == .critical ? "Mac is very hot" : "Mac is hot"
            case .gpuContended:
                let busy = Int((input.conditions.deviceGPUBusyPercent ?? 0).rounded())
                return "GPU busy (\(busy)%)"
            }
        }
    }
}
