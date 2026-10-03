import Combine
import Foundation
import Logging

/// File overview:
/// Owns what the performance tuner has learned about each model and persists it.
///
/// Why its own store: the learning is fed from two places that each see half of a suggestion's
/// life. `SuggestionEngineRouter` sees every finished generation (tokens, timing, model), and the
/// suggestion coordinator sees whether that suggestion was shown and accepted. Both write here
/// under the same `engine|model` key, and the tuning hook and the Performance pane read it. Built
/// once by `CotabbyAppEnvironment`.
///
/// Learning is always on, independent of the opt-in Performance Tracking list: the profile holds
/// only averages and counts, no text, and the tuner needs it to work.
@MainActor
final class ModelPerformanceProfileStore: ObservableObject {
    @Published private(set) var profiles: [String: ModelPerformanceProfile]

    /// Profiles beyond this many models are dropped, least recently updated first, so trying many
    /// GGUFs over months keeps a small defaults payload.
    static let maximumModels = 24

    private let userDefaults: UserDefaults
    private static let defaultsKey = "cotabbyModelPerformanceProfiles"
    private static let orderDefaultsKey = "cotabbyModelPerformanceProfileOrder"
    /// Update order, newest last, for trimming.
    private var order: [String]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let decoded = userDefaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: ModelPerformanceProfile].self, from: $0) } ?? [:]
        profiles = decoded.mapValues { $0.normalized() }
        let storedOrder = userDefaults.stringArray(forKey: Self.orderDefaultsKey) ?? []
        order = storedOrder.filter { decoded[$0] != nil } + decoded.keys.filter { !storedOrder.contains($0) }.sorted()
    }

    func profile(for modelKey: String?) -> ModelPerformanceProfile? {
        modelKey.flatMap { profiles[$0] }
    }

    /// Folds in a finished generation that produced output.
    func recordGeneration(modelKey: String, latencyMs: Double, stats: GenerationStats) {
        update(modelKey) {
            $0.recordingGeneration(latencyMs: latencyMs, tokens: stats.tokensGenerated, prefillMs: stats.prefillMilliseconds)
        }
    }

    func recordShown(modelKey: String, words: Int) {
        update(modelKey) { $0.recordingShown(words: words) }
    }

    func recordAccepted(modelKey: String, shownWords: Int) {
        update(modelKey) { $0.recordingAccepted(shownWords: shownWords) }
    }

    func reset() {
        profiles = [:]
        order = []
        userDefaults.removeObject(forKey: Self.defaultsKey)
        userDefaults.removeObject(forKey: Self.orderDefaultsKey)
    }

    private func update(_ modelKey: String, _ transform: (ModelPerformanceProfile) -> ModelPerformanceProfile) {
        let current = profiles[modelKey] ?? ModelPerformanceProfile()
        let next = transform(current)
        guard next != current else { return }
        var updated = profiles
        updated[modelKey] = next
        order.removeAll { $0 == modelKey }
        order.append(modelKey)
        while order.count > Self.maximumModels {
            updated.removeValue(forKey: order.removeFirst())
        }
        profiles = updated
        persist()
    }

    /// Written on every update: one small JSON blob per finished suggestion, the same cadence as
    /// the quality counters.
    private func persist() {
        do {
            userDefaults.set(try JSONEncoder().encode(profiles), forKey: Self.defaultsKey)
            userDefaults.set(order, forKey: Self.orderDefaultsKey)
        } catch {
            CotabbyLogger.app.error("Failed to persist model performance profiles: \(error.localizedDescription)")
        }
    }
}
