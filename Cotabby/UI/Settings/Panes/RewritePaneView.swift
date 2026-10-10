import SwiftUI

/// Settings → Rewrite: which model rewrites selected text, whether memory may help, and whether a
/// button appears on selection. Presentation only: values live in `RewritePreferencesStore`, the API
/// key in its own Keychain item.
struct RewritePaneView: View {
    @ObservedObject var preferences: RewritePreferencesStore
    let credentials: OpenAICompatibleCredentialStoring
    let usesAppleIntelligence: Bool

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
                    TextField("Base URL (e.g. https://api.openai.com/v1)",
                              text: Binding(get: { preferences.preferences.apiBaseURL }, set: preferences.setAPIBaseURL))
                    TextField("Model (e.g. gpt-4.1-mini)",
                              text: Binding(get: { preferences.preferences.apiModelName }, set: preferences.setAPIModelName))
                    SecureField("API key", text: $apiKey)
                        .onSubmit { saveAPIKey() }
                    Button("Save API Key") { saveAPIKey() }
                    if let keyStatus {
                        Text(keyStatus).font(.caption).foregroundStyle(keyStatusIsError ? .red : .secondary)
                    }
                    if let host = URL(string: preferences.preferences.apiBaseURL)?.host {
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
        .onAppear {
            let stored = (try? credentials.readAPIKey()) ?? ""
            savedAPIKey = stored
            apiKey = stored
        }
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

    /// Writes the key to the Keychain (never to UserDefaults or logs) and reports the result under
    /// the field. The error text comes from the Keychain call itself.
    private func saveAPIKey() {
        pendingKeySave?.cancel()
        pendingKeySave = nil
        do {
            try credentials.saveAPIKey(apiKey)
            savedAPIKey = apiKey
            keyStatus = "Key saved in the Keychain."
            keyStatusIsError = false
        } catch {
            keyStatus = "Couldn't save the key: \(error.localizedDescription)"
            keyStatusIsError = true
        }
    }
}
