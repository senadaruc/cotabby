import Combine
import Foundation

/// File overview:
/// The live half of performance tuning: it gathers the inputs `PerformanceTuningPolicy` needs (the
/// user's mode, the machine's conditions, what has been learned about the model in use) and answers
/// "how should this request be tuned?".
///
/// Why a service and not part of the coordinator: the inputs belong to app-level objects (the
/// settings model, `PerformanceConditionsMonitor`, `ModelPerformanceProfileStore`, the runtime's
/// selected model), and the coordinator should only apply a decision, the same way it consults
/// the window override store through a closure. Built once by `CotabbyAppEnvironment`; the
/// coordinator reaches it through `SuggestionCoordinator.performanceTuning`, and the Performance
/// pane observes `lastTuning` to show what is happening right now.
@MainActor
final class PerformanceTuner: ObservableObject {
    /// The decision for the most recent request, for the Performance pane's "Right now" line.
    @Published private(set) var lastTuning: PerformanceTuning = .unchanged
    /// The model key `lastTuning` was made for.
    @Published private(set) var lastModelKey: String?

    private let suggestionSettings: SuggestionSettingsModel
    private let conditionsMonitor: PerformanceConditionsMonitor
    private let profileStore: ModelPerformanceProfileStore
    private let modelKeyProvider: @MainActor (SuggestionEngineKind) -> String?
    /// The upper bound last applied per model, so the policy can keep length steady (hysteresis).
    private var previousHighWords: [String: Int] = [:]

    init(
        suggestionSettings: SuggestionSettingsModel,
        conditionsMonitor: PerformanceConditionsMonitor,
        profileStore: ModelPerformanceProfileStore,
        modelKeyProvider: @escaping @MainActor (SuggestionEngineKind) -> String?
    ) {
        self.suggestionSettings = suggestionSettings
        self.conditionsMonitor = conditionsMonitor
        self.profileStore = profileStore
        self.modelKeyProvider = modelKeyProvider
    }

    /// The tuning for a request built from `settings`. Cheap enough to call for every gate that
    /// asks (OCR, predict-ahead, debounce, request build): the GPU reading behind it is refreshed at
    /// most every few seconds, and the policy is plain arithmetic. Repeated calls with unchanged
    /// inputs return the same answer, so asking more than once per request is harmless.
    func tuning(for settings: SuggestionSettingsSnapshot) -> PerformanceTuning {
        let mode = suggestionSettings.performanceTuningMode
        guard mode != .off else {
            publish(.unchanged, modelKey: nil)
            return .unchanged
        }
        let modelKey = modelKeyProvider(settings.selectedEngine)
        let userRange = settings.userWordRange
        let input = PerformanceTuningPolicy.Input(
            mode: mode,
            conditions: conditionsMonitor.currentConditions(sampleGPU: true),
            profile: profileStore.profile(for: modelKey),
            userRange: userRange,
            tokensPerWord: LanguageCatalog.effectiveTokensPerWord(for: settings.responseLanguages),
            previousHighWords: modelKey.flatMap { previousHighWords[$0] }
        )
        let tuning = PerformanceTuningPolicy.tuning(input)
        if let modelKey {
            previousHighWords[modelKey] = tuning.wordRange?.highWords ?? userRange.highWords
        }
        publish(tuning, modelKey: modelKey)
        return tuning
    }

    /// The learned profile for the Performance pane's table, keyed like the store.
    func profile(for modelKey: String?) -> ModelPerformanceProfile? {
        profileStore.profile(for: modelKey)
    }

    /// Forgets learned speed and acceptance, and the hysteresis memory built on them.
    func resetLearning() {
        previousHighWords = [:]
        profileStore.reset()
    }

    private func publish(_ tuning: PerformanceTuning, modelKey: String?) {
        if lastTuning != tuning { lastTuning = tuning }
        if lastModelKey != modelKey { lastModelKey = modelKey }
    }
}
