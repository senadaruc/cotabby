import SwiftUI

/// Settings → Rewrite: which model rewrites selected text (this Mac, or a cloud service such as
/// Claude or GPT with the user's key and a model picked from the service's own list), whether memory
/// may help, and whether a button appears on selection. Presentation only: values live in
/// `RewritePreferencesStore`, each service's key in its own Keychain item (`RewriteCredentialVault`),
/// and the model list comes from `RewriteModelListService`.
struct RewritePaneView: View {
    @ObservedObject var preferences: RewritePreferencesStore
    let credentials: RewriteCredentialVault
    let modelList: RewriteModelListService
    let usesAppleIntelligence: Bool

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
                    Text(usesAppleIntelligence ? "Local (Apple Intelligence)" : "Local (Cotabby's model — basic quality)").tag(RewriteProviderKind.local)
                    Text("API model").tag(RewriteProviderKind.api)
                } label: {
                    SettingsRowLabel(title: "Rewrite Model",
                                     description: "Local runs on this Mac. An API model usually rewrites better, but the selected text is sent to it.",
                                     systemImage: "cpu")
                }
                .settingsItem(.rewriteProvider)

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
                    SettingsRowLabel(title: "Send Memory Facts to My API Model",
                                     description: "Off: memory never leaves this Mac, and memory works only with the local model. On: facts and style examples go to your API model with the text.",
                                     systemImage: "icloud.and.arrow.up")
                }
                .disabled(preferences.preferences.provider != .api)
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
