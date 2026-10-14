import SwiftUI

/// Settings → Rewrite: which model rewrites selected text (the engine autocomplete uses, any other
/// engine on this Mac reusing autocomplete's model, or a cloud service such as Claude or GPT with the
/// user's key and a model picked from the service's own list), whether memory may help, and whether
/// a button appears on selection. Presentation only: values live in `RewritePreferencesStore`, each
/// service's key in its own Keychain item (`RewriteCredentialVault`), the model list comes from
/// `RewriteModelListService`, and which rows are usable comes from `RewriteEngine`'s providers.
struct RewritePaneView: View {
    @ObservedObject var preferences: RewritePreferencesStore
    let credentials: RewriteCredentialVault
    let modelList: RewriteModelListService
    let engine: RewriteEngine
    /// Observed so the "Same as autocomplete" row and the MLX note follow the autocomplete engine.
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    // Everything a row's availability is computed from. `engine.provider(for:).isAvailable` reads
    // plain state, so the pane must observe the sources itself: an "(Unavailable)" row then
    // re-enables as soon as an MLX install or a model download finishes.
    @ObservedObject var mlxToolchainProvisioner: MLXToolchainProvisioner
    @ObservedObject var mlxModelDownloader: MLXModelDownloader
    @ObservedObject var mlxServerManager: MLXServerManager
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel

    /// Models the service reported after "Load models"; empty until then.
    @State private var loadedModels: [String] = []
    @State private var modelListStatus: String?
    @State private var isLoadingModels = false

    @State private var apiKey = ""
    /// The key as last read from or written to the Keychain. Typing compares against it, so loading
    /// the key on appear does not count as an edit, and leaving the pane saves only real changes.
    @State private var savedAPIKey = ""
    /// The line under the key field: what the last save did. Nil until the first save attempt.
    @State private var keyStatus: String?
    @State private var keyStatusIsError = false
    /// The save scheduled 600 ms after the last keystroke; each edit cancels the previous one.
    @State private var pendingKeySave: Task<Void, Never>?

    var body: some View {
        SettingsPaneScaffold {
            Section("Model") {
                Picker(selection: Binding(get: { preferences.preferences.provider }, set: preferences.setProvider)) {
                    ForEach(RewriteProviderKind.allCases, id: \.self) { kind in
                        Text(rowTitle(kind))
                            .tag(kind)
                            // Disables just this menu item (macOS 14+), like the engine picker.
                            .selectionDisabled(!isSelectable(kind))
                    }
                } label: {
                    SettingsRowLabel(title: "Rewrite Model",
                                     description: "Apple Intelligence, Open Source, Local Endpoint and MLX run on the model you already set up for autocomplete; there is no separate rewrite model. Instruction-following models (Apple Intelligence, chat models) rewrite best; a base model gives basic-quality rewrites. An API model usually rewrites better, but the selected text is sent to it.",
                                     systemImage: "cpu")
                }
                .settingsItem(.rewriteProvider)

                if let note = selectedNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = selectedUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }

                if preferences.preferences.provider == .api {
                    Picker("Service", selection: Binding(get: { preferences.preferences.cloudProvider }, set: switchService)) {
                        ForEach(RewriteCloudProvider.allCases, id: \.self) { service in
                            Text(service.displayName).tag(service)
                        }
                    }
                    if preferences.preferences.cloudProvider == .custom {
                        TextField("Base URL (e.g. https://gateway.example.com/v1)",
                                  text: Binding(get: { preferences.preferences.apiBaseURL }, set: preferences.setAPIBaseURL))
                    }
                    HStack {
                        TextField("Model", text: Binding(get: { preferences.preferences.apiModelName }, set: preferences.setAPIModelName))
                        Menu("Choose") {
                            ForEach(modelChoices, id: \.self) { model in
                                Button(model) { preferences.setAPIModelName(model) }
                            }
                        }
                        .disabled(modelChoices.isEmpty)
                        .fixedSize()
                        Button(isLoadingModels ? "Loading…" : "Load models") { loadModels() }
                            .disabled(isLoadingModels)
                    }
                    if let modelListStatus {
                        Text(modelListStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("API key", text: $apiKey)
                        .onSubmit { saveAPIKey() }
                    Button("Save API Key") { saveAPIKey() }
                    if let keyStatus {
                        Text(keyStatus).font(.caption).foregroundStyle(keyStatusIsError ? .red : .secondary)
                    }
                    if let host = URL(string: preferences.preferences.effectiveBaseURL)?.host {
                        Text("The selected text is sent to \(host) when you rewrite.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Section("Memory") {
                Toggle(isOn: Binding(get: { preferences.preferences.usesMemoryByDefault }, set: preferences.setUsesMemoryByDefault)) {
                    SettingsRowLabel(title: "Use Memory by Default",
                                     description: "Rewrites use facts from earlier conversations with the person, and your own messages as style. You can switch it per rewrite.",
                                     systemImage: "brain")
                }
                .settingsItem(.rewriteMemory)
                Toggle(isOn: Binding(get: { preferences.preferences.sendsMemoryToAPI }, set: preferences.setSendsMemoryToAPI)) {
                    SettingsRowLabel(title: "Send Memory Facts Off This Mac",
                                     description: "Applies to an API model and to a Local Endpoint on your network or the internet. Off: memory is not used with them, and the text is sent without it. On: facts and style examples go to that model with the text. Apple Intelligence, Open Source, MLX and a Local Endpoint on this Mac always keep memory on this Mac.",
                                     systemImage: "icloud.and.arrow.up")
                }
                .disabled(![.api, .localEndpoint].contains(engine.resolvedKind))
            }
            Section("Selection") {
                Toggle(isOn: Binding(get: { preferences.preferences.showsButtonOnSelection }, set: preferences.setShowsButtonOnSelection)) {
                    SettingsRowLabel(title: "Show Button on Selection",
                                     description: "A small button appears when you select text in a field. \(preferences.preferences.shortcutLabel) opens the rewrite either way.",
                                     systemImage: "wand.and.stars")
                }
                .settingsItem(.rewriteButton)
            }
        }
        .onAppear { loadKey() }
        // Each edit restarts a 600 ms timer, so the key is saved once typing pauses, without a Save click.
        .onChange(of: apiKey) { _, newKey in
            pendingKeySave?.cancel()
            guard newKey != savedAPIKey else { return }
            pendingKeySave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                saveAPIKey()
            }
        }
        // Leaving the pane saves at once, so a key typed in the last moment is not lost.
        .onDisappear {
            pendingKeySave?.cancel()
            pendingKeySave = nil
            if apiKey != savedAPIKey { saveAPIKey() }
        }
    }

    // MARK: - Rewrite Model rows

    /// The row text. "Same as autocomplete" names the engine it would follow; a row whose provider
    /// cannot run right now says so (and is also disabled, see `isSelectable`).
    private func rowTitle(_ kind: RewriteProviderKind) -> String {
        switch kind {
        case .sameAsAutocomplete: return "Same as autocomplete (\(suggestionSettings.selectedEngine.displayLabel))"
        case .appleIntelligence: return decorated("Apple Intelligence", kind)
        case .openSource: return decorated("Open Source", kind)
        case .localEndpoint: return decorated("Local Endpoint", kind)
        case .mlx: return decorated("MLX", kind)
        case .api: return "API model"
        }
    }

    private func decorated(_ label: String, _ kind: RewriteProviderKind) -> String {
        engine.provider(for: kind).isAvailable ? label : "\(label) (Unavailable)"
    }

    /// An unavailable row stays visible but cannot be picked. "Same as autocomplete" and "API model"
    /// stay pickable: the first is the default and shows the reason below instead of trapping the
    /// user on another row; the API model is configured right here.
    private func isSelectable(_ kind: RewriteProviderKind) -> Bool {
        switch kind {
        case .sameAsAutocomplete, .api: return true
        default: return engine.provider(for: kind).isAvailable
        }
    }

    /// The reason the selected choice cannot run, shown under the picker.
    private var selectedUnavailableReason: String? {
        let provider = engine.provider(for: preferences.preferences.provider)
        guard !provider.isAvailable else { return nil }
        return provider.unavailableReason ?? "This rewrite model isn't set up."
    }

    /// What the selected local choice runs on, when that is worth saying.
    private var selectedNote: String? {
        guard engine.resolvedKind == .mlx else { return nil }
        let model = suggestionSettings.mlxModelID
        return model.isEmpty ? nil : "Uses your MLX model: \(model)"
    }

    /// The models offered in "Choose": the service's own list once loaded, else its suggestions.
    private var modelChoices: [String] {
        loadedModels.isEmpty ? preferences.preferences.cloudProvider.suggestedModels : loadedModels
    }

    /// Changes service: saves a key still being typed for the old one, then shows the new one's key
    /// and forgets the old model list.
    private func switchService(_ service: RewriteCloudProvider) {
        if apiKey != savedAPIKey { saveAPIKey() }
        preferences.setCloudProvider(service)
        loadedModels = []
        modelListStatus = nil
        keyStatus = nil
        loadKey()
    }

    private func loadKey() {
        let stored = (try? credentials.store(for: preferences.preferences.cloudProvider).readAPIKey()) ?? ""
        savedAPIKey = stored
        apiKey = stored
    }

    /// Asks the service for the models this key can use.
    private func loadModels() {
        if apiKey != savedAPIKey { saveAPIKey() }
        let service = preferences.preferences.cloudProvider
        let baseURL = preferences.preferences.effectiveBaseURL
        let key = apiKey
        isLoadingModels = true
        modelListStatus = nil
        Task { @MainActor in
            defer { isLoadingModels = false }
            do {
                let models = try await modelList.models(for: service, baseURL: baseURL, apiKey: key)
                guard preferences.preferences.cloudProvider == service else { return }
                loadedModels = models
                modelListStatus = models.isEmpty ? "The service listed no models." : "\(models.count) models — pick one with Choose."
            } catch {
                modelListStatus = "Couldn't load models: \(error.localizedDescription)"
            }
        }
    }

    /// Writes the key to the current service's Keychain item (never to UserDefaults or logs) and
    /// reports the result under the field. The error text comes from the Keychain call itself.
    private func saveAPIKey() {
        pendingKeySave?.cancel()
        pendingKeySave = nil
        do {
            try credentials.store(for: preferences.preferences.cloudProvider).saveAPIKey(apiKey)
            savedAPIKey = apiKey
            keyStatus = "Key saved in the Keychain."
            keyStatusIsError = false
        } catch {
            keyStatus = "Couldn't save the key: \(error.localizedDescription)"
            keyStatusIsError = true
        }
    }
}
