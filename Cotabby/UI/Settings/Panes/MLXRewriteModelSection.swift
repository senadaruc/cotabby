import SwiftUI

/// File overview:
/// The "MLX rewrite model" rows of Settings → Rewrite, shown when Rewrite Model is "Local (MLX)".
/// Presentation only: it reads the toolchain state and model cache that Engine & Model already
/// maintains (`MLXToolchainProvisioner`, `MLXModelDownloader`) and forwards two actions, a download
/// and a model choice, to the downloader and `RewritePreferencesStore`. It is its own view so
/// `RewritePaneView` does not carry MLX's state matrix.
struct MLXRewriteModelSection: View {
    @ObservedObject var preferences: RewritePreferencesStore
    @ObservedObject var provisioner: MLXToolchainProvisioner
    @ObservedObject var downloader: MLXModelDownloader

    private var modelID: String { preferences.preferences.mlxModelID }

    var body: some View {
        LabeledContent("MLX rewrite model") {
            VStack(alignment: .trailing, spacing: 4) {
                Text(modelID).font(.callout).textSelection(.enabled)
                statusLine
            }
        }
        if !choices.isEmpty {
            Picker("Use a downloaded model", selection: Binding(get: { modelID }, set: preferences.setMLXModelID)) {
                ForEach(choices, id: \.id) { choice in
                    Text(choice.label).tag(choice.id)
                }
            }
        }
        Text("Runs a second model (about 3 GB of memory) while you rewrite; it stops after 5 minutes without rewrites.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private struct Choice {
        let id: String
        let label: String
    }

    /// Downloaded, compatible models with instruct models first. The current choice is always
    /// listed (so the picker has a matching tag) even when it is not downloaded yet.
    private var choices: [Choice] {
        let cached = (downloader.cachedModels ?? []).sorted {
            if $0.isInstruct != $1.isInstruct { return $0.isInstruct }
            return $0.repoID.value.localizedCaseInsensitiveCompare($1.repoID.value) == .orderedAscending
        }
        var result = cached.map {
            Choice(id: $0.repoID.value,
                   label: $0.isInstruct ? $0.repoID.value : "\($0.repoID.value) (base model: may ignore instructions)")
        }
        if !result.contains(where: { $0.id == modelID }) {
            result.insert(Choice(id: modelID, label: "\(modelID) (not downloaded)"), at: 0)
        }
        return result
    }

    @ViewBuilder
    private var statusLine: some View {
        switch provisioner.state {
        case .checking:
            Text("Checking for mlx-lm…").font(.caption).foregroundStyle(.secondary)
        case .installing:
            Text("Installing mlx-lm — see Engine & Model.").font(.caption).foregroundStyle(.secondary)
        case .notInstalled, .tooOld, .failed:
            Text("mlx-lm isn't installed. Install it in Settings → Engine & Model.")
                .font(.caption).foregroundStyle(.orange)
        case .ready(let toolchain):
            modelStatus(toolchain)
        }
    }

    @ViewBuilder
    private func modelStatus(_ toolchain: MLXToolchain) -> some View {
        if let repoID = MLXRepoID(modelID) {
            if let cached = downloader.cachedModels?.first(where: { $0.repoID == repoID }) {
                Text(cached.isInstruct ? "Ready" : "Ready — base model: may ignore instructions")
                    .font(.caption).foregroundStyle(cached.isInstruct ? .green : .orange)
            } else if let reason = downloader.rejectedModels[repoID] {
                Text("Can't run on MLX: \(reason.message)").font(.caption).foregroundStyle(.red)
            } else if let download = downloader.download, download.repoID == repoID, download.isActive {
                if let fraction = download.fraction {
                    ProgressView(value: fraction).frame(width: 140)
                } else {
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
            } else if downloader.cachedModels == nil {
                Text("Checking downloaded models…").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    if let failure = downloader.download?.failure, downloader.download?.repoID == repoID {
                        Text(failure).font(.caption).foregroundStyle(.red)
                    }
                    Button("Download") { downloader.startDownload(repoID, toolchain: toolchain) }
                        .disabled(downloader.download?.isActive == true)
                }
            }
        } else {
            Text("Choose a model from Hugging Face's mlx-community.").font(.caption).foregroundStyle(.orange)
        }
    }
}
