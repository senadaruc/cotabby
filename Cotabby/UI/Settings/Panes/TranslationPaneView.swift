import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Translation: augmented translation of incoming messages and replies.
///
/// Presentation only. Preferences live in `TranslationPreferencesStore`; the per-language status
/// asks `TranslationService`, which knows what Apple Translation has installed and whether the
/// local model can cover the rest.
struct TranslationPaneView: View {
    @ObservedObject var preferences: TranslationPreferencesStore
    let service: TranslationService
    /// Observed so the provider line follows Settings → Rewrite and "Same as autocomplete" live.
    @ObservedObject var rewritePreferences: RewritePreferencesStore
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    /// Not observable: it only answers "which provider is active", re-read on each redraw the two
    /// stores above trigger.
    let rewriteEngine: RewriteEngine

    @State private var statuses: [String: TranslationPairAvailability] = [:]
    @State private var isRecordingShortcut = false
    @State private var isRecordingSelectionShortcut = false

    /// Chat languages whose status is shown; the user's own from their Writing languages are
    /// common ones, and Macedonian shows how the local-model fallback is reported.
    private static let statusLanguages = ["tr", "mk", "de", "fr", "es", "it", "ru", "nl", "ar", "zh"]

    var body: some View {
        SettingsPaneScaffold {
            Section("Translation") {
                Toggle(isOn: binding(\.isEnabled, preferences.setEnabled)) {
                    SettingsRowLabel(
                        title: "Translate Messages",
                        description: "In the apps below, show translations of messages in other languages, " +
                            "and offer your replies in the chat's language. Everything runs on this Mac.",
                        systemImage: "character.bubble"
                    )
                }
                .settingsItem(.translationEnabled)

                Picker(selection: binding(\.readingLanguage, preferences.setReadingLanguage)) {
                    ForEach(Self.readingLanguageChoices, id: \.self) { code in
                        Text(Self.name(code)).tag(code)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "My Language",
                        description: "Messages are translated into this language, and replies you write in it are offered in the chat's " +
                            "language, and selected text is translated into it.",
                        systemImage: "person.wave.2"
                    )
                }
                .disabled(!preferences.preferences.isEnabled && !preferences.preferences.translatesSelection)

                Toggle(isOn: binding(\.translatesIncoming, preferences.setTranslatesIncoming)) {
                    SettingsRowLabel(
                        title: "Translate Incoming Messages",
                        description: "Reads the chat window every few seconds and shows each translation under its message. Needs Screen Recording.",
                        systemImage: "text.bubble"
                    )
                }
                .disabled(!preferences.preferences.isEnabled)

                Toggle(isOn: binding(\.offersReplyTranslation, preferences.setOffersReplyTranslation)) {
                    SettingsRowLabel(
                        title: "Offer Reply Translation",
                        description: "When you write in your language, show your reply in the chat's language. " +
                            "Press \(preferences.preferences.replaceKeyLabel) to replace your draft; you still press Return to send.",
                        systemImage: "arrowshape.turn.up.left"
                    )
                }
                .disabled(!preferences.preferences.isEnabled)

                LabeledContent {
                    KeybindRow(
                        label: preferences.preferences.replaceKeyLabel,
                        keyCode: preferences.preferences.replaceKeyCode,
                        isRecording: $isRecordingShortcut,
                        onRecord: { keyCode, modifiers, label in
                            preferences.setReplaceKey(keyCode: keyCode, modifiers: modifiers.rawValue, label: label)
                        },
                        onReset: {
                            preferences.setReplaceKey(
                                keyCode: TranslationPreferences.defaultReplaceKeyCode,
                                modifiers: TranslationPreferences.defaultReplaceKeyModifiers,
                                label: TranslationPreferences.defaultReplaceKeyLabel
                            )
                        },
                        resetLabel: "Reset",
                        shouldShowReset: preferences.preferences.replaceKeyCode != TranslationPreferences.defaultReplaceKeyCode
                            || preferences.preferences.replaceKeyModifiers != TranslationPreferences.defaultReplaceKeyModifiers,
                        onClear: {
                            preferences.setReplaceKey(
                                keyCode: TranslationPreferences.defaultReplaceKeyCode,
                                modifiers: TranslationPreferences.defaultReplaceKeyModifiers,
                                label: TranslationPreferences.defaultReplaceKeyLabel
                            )
                        },
                        clearLabel: "Use Default",
                        clearHelp: "Go back to \(TranslationPreferences.defaultReplaceKeyLabel).",
                        conflictChecker: { keyCode, modifiers in
                            keyCode == preferences.preferences.selectionKeyCode
                                && modifiers.rawValue == preferences.preferences.selectionKeyModifiers
                                ? "Already used to translate the selection." : nil
                        }
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Replace Draft Shortcut",
                        description: "Replaces your draft with the offered translation. It never sends the message.",
                        systemImage: "keyboard"
                    )
                }
                .disabled(!preferences.preferences.isEnabled || !preferences.preferences.offersReplyTranslation)
            }

            Section("Translate on Select") {
                Toggle(isOn: binding(\.translatesSelection, preferences.setTranslatesSelection)) {
                    SettingsRowLabel(
                        title: "Translate Selected Text",
                        description: "Select text in any app and its translation into your language appears " +
                            "above the selection, with a Copy button.",
                        systemImage: "text.magnifyingglass"
                    )
                }
                .settingsItem(.translationOnSelect)

                Picker(selection: binding(\.selectionTrigger, preferences.setSelectionTrigger)) {
                    ForEach(SelectionTranslationTrigger.allCases, id: \.self) { trigger in
                        Text(Self.label(for: trigger)).tag(trigger)
                    }
                } label: {
                    SettingsRowLabel(
                        title: "Show Translation",
                        description: "Automatic shows it about half a second after you select; the shortcut always works.",
                        systemImage: "cursorarrow.click.2"
                    )
                }
                .disabled(!preferences.preferences.translatesSelection)

                LabeledContent {
                    KeybindRow(
                        label: preferences.preferences.selectionKeyLabel,
                        keyCode: preferences.preferences.selectionKeyCode,
                        isRecording: $isRecordingSelectionShortcut,
                        onRecord: { keyCode, modifiers, label in
                            preferences.setSelectionKey(keyCode: keyCode, modifiers: modifiers.rawValue, label: label)
                        },
                        onReset: { resetSelectionKey() },
                        resetLabel: "Reset",
                        shouldShowReset: preferences.preferences.selectionKeyCode != TranslationPreferences.defaultSelectionKeyCode
                            || preferences.preferences.selectionKeyModifiers != TranslationPreferences.defaultSelectionKeyModifiers,
                        onClear: { resetSelectionKey() },
                        clearLabel: "Use Default",
                        clearHelp: "Go back to \(TranslationPreferences.defaultSelectionKeyLabel).",
                        conflictChecker: { keyCode, modifiers in selectionShortcutConflict(keyCode, modifiers) }
                    )
                } label: {
                    SettingsRowLabel(
                        title: "Translate Selection Shortcut",
                        description: "Shows the translation of the selected text, or shows it again after you closed it.",
                        systemImage: "keyboard"
                    )
                }
                .settingsItem(.translationOnSelectShortcut)
                .disabled(!preferences.preferences.translatesSelection)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Translates with \(Self.providerName(rewriteEngine.resolvedKind, rewritePreferences)) from Settings → Rewrite.")
                    if rewriteEngine.activeProviderSendsOffDevice {
                        Text("The selected text is sent to \(rewriteEngine.activeHostName ?? "that service"). " +
                            "Memory facts are never sent.")
                            .foregroundStyle(Color.orange)
                    } else {
                        Text("Runs on this Mac.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Apps") {
                ForEach(preferences.preferences.appBundleIdentifiers, id: \.self) { identifier in
                    LabeledContent {
                        Button("Remove") { preferences.setApp(identifier, included: false) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: Self.icon(for: identifier))
                                .resizable()
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                            Text(Self.appName(for: identifier))
                        }
                    }
                }
                Button("Add App…") { addApp() }
                    .settingsItem(.translationApps)
            }

            Section("Languages") {
                ForEach(Self.statusLanguages, id: \.self) { code in
                    LabeledContent(Self.name(code)) {
                        Text(statusLabel(statuses[code]))
                            .foregroundStyle(statusColor(statuses[code]))
                    }
                }
                Text("Apple Translation runs on this Mac for about 20 languages; download missing ones in " +
                    "System Settings › General › Language & Region › Translation Languages. Other languages, " +
                    "like Macedonian, use your Open Source model, which is slower and less accurate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsItem(.translationLanguages)
            }

            Section("Privacy") {
                Text("Translation reads text from the chat window with Screen Recording, translates it on this Mac, " +
                    "and keeps translations in memory only. Nothing is saved, logged, or sent to a server. " +
                    "Password fields and apps where Cotabby is off are never read. " +
                    "Translate on Select sends only the selected text to the Rewrite model you chose; " +
                    "with a cloud service that text leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: preferences.preferences.readingLanguage) { await refreshStatuses() }
    }

    private static func icon(for bundleIdentifier: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    private static func appName(for bundleIdentifier: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleIdentifier
    }

    private static func label(for trigger: SelectionTranslationTrigger) -> String {
        switch trigger {
        case .automatic: return "Automatically when I select text"
        case .shortcut: return "Only with the shortcut"
        }
    }

    /// Close to the Rewrite pane's row wording (its helper is private), phrased to read inside a
    /// sentence. `resolvedKind` is never `sameAsAutocomplete`, but the switch stays exhaustive and
    /// names that case anyway.
    private static func providerName(_ kind: RewriteProviderKind, _ rewritePreferences: RewritePreferencesStore) -> String {
        switch kind {
        case .sameAsAutocomplete: return "the autocomplete model"
        case .appleIntelligence: return "Apple Intelligence"
        case .openSource: return "the Open Source model"
        case .localEndpoint: return "Local Endpoint"
        case .mlx: return "MLX"
        case .api: return rewritePreferences.preferences.cloudProvider.displayName
        }
    }

    private func resetSelectionKey() {
        preferences.setSelectionKey(
            keyCode: TranslationPreferences.defaultSelectionKeyCode,
            modifiers: TranslationPreferences.defaultSelectionKeyModifiers,
            label: TranslationPreferences.defaultSelectionKeyLabel
        )
    }

    /// Blocks the two chords this feature would otherwise shadow: the reply key and Rewrite's ⌃⌥R.
    private func selectionShortcutConflict(_ keyCode: CGKeyCode, _ modifiers: ShortcutModifierMask) -> String? {
        if keyCode == preferences.preferences.replaceKeyCode, modifiers.rawValue == preferences.preferences.replaceKeyModifiers {
            return "Already used to replace your draft."
        }
        let rewrite = rewritePreferences.preferences
        if keyCode == rewrite.shortcutKeyCode, modifiers.rawValue == rewrite.shortcutModifiers {
            return "Already used by Rewrite (\(rewrite.shortcutLabel))."
        }
        return nil
    }

    private static let readingLanguageChoices = ["en", "tr", "mk", "de", "fr", "es", "it", "nl", "ru"]

    private static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func refreshStatuses() async {
        var result: [String: TranslationPairAvailability] = [:]
        let reading = preferences.preferences.readingLanguage
        for code in Self.statusLanguages where !TranslationLanguagePolicy.sameLanguage(code, reading) {
            result[code] = await service.availability(from: code, to: reading)
        }
        statuses = result
    }

    private func statusLabel(_ status: TranslationPairAvailability?) -> String {
        switch status {
        case .ready: return "Apple Translation"
        case .needsDownload: return "Download in System Settings"
        case .localModel: return "Open Source model"
        case .unavailable: return "Not available"
        case nil: return "Your language"
        }
    }

    private func statusColor(_ status: TranslationPairAvailability?) -> Color {
        switch status {
        case .ready: return .green
        case .needsDownload, .localModel: return .orange
        case .unavailable: return .red
        case nil: return .secondary
        }
    }

    private func binding<Value>(
        _ keyPath: KeyPath<TranslationPreferences, Value>,
        _ setter: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: { preferences.preferences[keyPath: keyPath] }, set: setter)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let metadata = ApplicationBundleMetadata(appURL: url) else { return }
        preferences.setApp(metadata.bundleIdentifier, included: true)
    }
}
