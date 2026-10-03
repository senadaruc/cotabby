import SwiftUI

/// File overview:
/// The "Performance Tuning" section of the Performance pane: the mode picker, a plain-language line
/// saying what the tuner is doing right now, and what it has learned about each model.
///
/// Presentation only. The decisions are made by `PerformanceTuningPolicy` through `PerformanceTuner`,
/// whose `lastTuning` this view observes; the per-model rows read `ModelPerformanceProfileStore`.
/// Its own file because the Performance pane already holds three other sections, and this one has
/// its own formatting rules for model names, speeds and length bands.
struct PerformanceTuningSection: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var performanceTuner: PerformanceTuner
    @ObservedObject var modelProfileStore: ModelPerformanceProfileStore

    var body: some View {
        Section {
            Picker(selection: modeBinding) {
                ForEach(PerformanceTuningMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                SettingsRowLabel(
                    title: "Performance Tuning",
                    description: suggestionSettings.performanceTuningMode.summary +
                        " Never longer than your Length setting.",
                    systemImage: "gauge.with.dots.needle.33percent"
                )
            }
            .settingsItem(.performanceTuning)

            HStack(alignment: .firstTextBaseline) {
                Text("Right now")
                Spacer()
                Text(rightNowLabel)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            ForEach(learnedModels, id: \.key) { model in
                modelRow(key: model.key, profile: model.profile)
            }
        } header: {
            HStack {
                Text("Performance Tuning")
                Spacer()
                if !modelProfileStore.profiles.isEmpty {
                    Button("Reset Learned Data") {
                        performanceTuner.resetLearning()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Rows

    private func modelRow(key: String, profile: ModelPerformanceProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.displayName(forModelKey: key))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(Self.speedLabel(for: profile))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(Self.acceptanceLabel(for: profile))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Labels

    private var rightNowLabel: String {
        guard suggestionSettings.performanceTuningMode != .off else {
            return "Off: your settings apply as they are"
        }
        let tuning = performanceTuner.lastTuning
        guard tuning.isHoldingBack else {
            return "Nothing to hold back"
        }
        return tuning.reasons.joined(separator: " · ")
    }

    /// Models with at least one measured generation, the busiest first.
    private var learnedModels: [(key: String, profile: ModelPerformanceProfile)] {
        modelProfileStore.profiles
            .filter { $0.value.sampleCount > 0 || $0.value.buckets.contains { $0.shown > 0 } }
            .sorted { $0.value.sampleCount > $1.value.sampleCount }
            .map { (key: $0.key, profile: $0.value) }
    }

    /// The model part of an `engine|model` key, with a `.gguf` extension dropped.
    static func displayName(forModelKey key: String) -> String {
        let model = key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? key
        return model.hasSuffix(".gguf") ? String(model.dropLast(5)) : model
    }

    static func speedLabel(for profile: ModelPerformanceProfile) -> String {
        guard let latency = profile.latencyMs, let perToken = profile.msPerToken else {
            return "measuring…"
        }
        let estimate = profile.isTimingCoarse ? " (est.)" : ""
        return "~\(Int(latency.rounded())) ms · \(Int(perToken.rounded())) ms/token\(estimate)"
    }

    /// Accept rate per length band with enough suggestions to mean something, e.g.
    /// "Accepted: 4-7 w 21% · 13-20 w 2%".
    static func acceptanceLabel(for profile: ModelPerformanceProfile) -> String {
        let bands = profile.buckets.enumerated().compactMap { index, bucket -> String? in
            guard bucket.shown >= 5, let rate = bucket.acceptanceRate else { return nil }
            let range = ModelPerformanceProfile.bucketRange(at: index)
            let label = index == ModelPerformanceProfile.bucketUpperBounds.count - 1
                ? "\(range.lowerBound)+ w" : "\(range.lowerBound)-\(range.upperBound) w"
            return "\(label) \(Int((rate * 100).rounded()))%"
        }
        guard !bands.isEmpty else {
            let samples = profile.sampleCount
            return "\(samples) generation\(samples == 1 ? "" : "s") measured; learning which lengths you accept"
        }
        return "Accepted: " + bands.joined(separator: " · ")
    }

    private var modeBinding: Binding<PerformanceTuningMode> {
        Binding(
            get: { suggestionSettings.performanceTuningMode },
            set: { suggestionSettings.setPerformanceTuningMode($0) }
        )
    }
}
