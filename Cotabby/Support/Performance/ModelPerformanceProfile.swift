import Foundation

/// File overview:
/// What Cotabby has learned about one model: how fast it is, and which suggestion lengths the user
/// actually accepts from it.
///
/// Why per model: speed is a property of the model and the engine running it (a 26B mixture-of-
/// experts GGUF and Apple Intelligence differ by an order of magnitude per token), and acceptance by
/// length differs too, because one model's long suggestions can be good where another's ramble.
/// `ModelPerformanceProfileStore` keeps one of these per `engine|model` key and persists it;
/// `PerformanceTuningPolicy` reads it. The value is pure: every update is a `recording…` method that
/// returns a new profile, so the arithmetic is unit-tested without a store.
struct ModelPerformanceProfile: Codable, Equatable, Sendable {
    /// Shown and accepted counts for suggestions of one length band.
    struct LengthBucket: Codable, Equatable, Sendable {
        var shown = 0
        /// Suggestions from this band the user accepted at least one word of.
        var acceptedAny = 0

        var acceptanceRate: Double? {
            shown > 0 ? Double(acceptedAny) / Double(shown) : nil
        }
    }

    /// Upper word bound of each length band: 1-3, 4-7, 8-12, 13-20, 21+.
    static let bucketUpperBounds = [3, 7, 12, 20, SuggestionWordRange.maximumWord]
    /// Weight of the newest sample in each moving average. Small enough that one slow outlier (a
    /// cold cache after a model switch) barely moves it; large enough to follow a real change, such
    /// as the Mac being unplugged, within a few dozen suggestions.
    static let smoothing = 0.1

    /// Generations with a usable token count that have been averaged in.
    var sampleCount = 0
    /// Moving average of end-to-end latency.
    var latencyMs: Double?
    /// Moving average of the time before the first output token (prompt processing). Nil until an
    /// engine that measures it has run; engines that cannot split it leave it at zero.
    var prefillMs: Double?
    /// Moving average of the time per output token.
    var msPerToken: Double?
    /// True when `msPerToken` came from end-to-end latency over an estimated token count (Apple
    /// Intelligence and HTTP endpoints report neither), so it includes prompt time.
    var isTimingCoarse = false
    var buckets = Array(repeating: LengthBucket(), count: ModelPerformanceProfile.bucketUpperBounds.count)

    static func bucketIndex(forWords words: Int) -> Int {
        bucketUpperBounds.firstIndex { words <= $0 } ?? bucketUpperBounds.count - 1
    }

    /// The word range a bucket covers, for the UI.
    static func bucketRange(at index: Int) -> ClosedRange<Int> {
        let lower = index == 0 ? 1 : bucketUpperBounds[index - 1] + 1
        return lower...bucketUpperBounds[index]
    }

    /// Folds one finished generation in. `prefillMs` is the measured time to the first token when
    /// the engine reports it; without it the whole latency is spread over the tokens and the timing
    /// is marked coarse. A generation with no tokens (cancelled, suppressed) says nothing about the
    /// per-token speed and is skipped.
    func recordingGeneration(latencyMs: Double, tokens: Int, prefillMs: Double?) -> ModelPerformanceProfile {
        guard tokens > 0, latencyMs > 0 else { return self }
        var next = self
        let decodeMs = prefillMs.map { max(latencyMs - $0, 0) } ?? latencyMs
        next.latencyMs = Self.averaged(latencyMs, into: self.latencyMs)
        next.prefillMs = Self.averaged(prefillMs ?? 0, into: self.prefillMs)
        next.msPerToken = Self.averaged(decodeMs / Double(tokens), into: msPerToken)
        next.isTimingCoarse = prefillMs == nil
        next.sampleCount += 1
        return next
    }

    func recordingShown(words: Int) -> ModelPerformanceProfile {
        guard words > 0 else { return self }
        var next = self
        next.buckets[Self.bucketIndex(forWords: words)].shown += 1
        return next
    }

    /// Records that a suggestion of `shownWords` words was accepted (at least its first word).
    func recordingAccepted(shownWords: Int) -> ModelPerformanceProfile {
        guard shownWords > 0 else { return self }
        var next = self
        next.buckets[Self.bucketIndex(forWords: shownWords)].acceptedAny += 1
        return next
    }

    /// A Codable decode of an older or hand-edited profile could carry the wrong bucket count; the
    /// arithmetic above indexes by `bucketUpperBounds`, so the store repairs the shape on load.
    func normalized() -> ModelPerformanceProfile {
        guard buckets.count != Self.bucketUpperBounds.count else { return self }
        var next = self
        next.buckets = Array(buckets.prefix(Self.bucketUpperBounds.count))
        while next.buckets.count < Self.bucketUpperBounds.count { next.buckets.append(LengthBucket()) }
        return next
    }

    private static func averaged(_ sample: Double, into current: Double?) -> Double {
        guard let current else { return sample }
        return current + smoothing * (sample - current)
    }
}
