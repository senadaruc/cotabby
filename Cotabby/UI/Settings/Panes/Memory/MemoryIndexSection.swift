import SwiftUI

/// File overview:
/// The Memory pane's index and privacy settings: every LEANN build and search knob the service
/// exposes, the index's state with Rebuild and Remove, and what memory keeps (retention and
/// exclusions) with Delete All.
///
/// Edits are made on a local draft and sent with Apply, because most build settings force a full
/// re-embed of every message: changing them one keystroke at a time would queue rebuilds the user
/// never meant to start. The service validates ranges and reports refused keys, shown inline.
struct MemoryIndexSection: View {
    @ObservedObject var control: MemoryControlModel
    @State private var draft: MemoryIndexSettings?
    @State private var privacyDraft: MemoryPrivacySettings?
    @State private var confirmingDeleteAll = false

    var body: some View {
        if let saved = control.configuration?.index {
            let binding = Binding(get: { draft ?? saved }, set: { draft = $0 })
            Section {
                indexStatus
                Picker("Backend", selection: binding.backend) {
                    ForEach(MemoryIndexSettings.backends, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                Picker("Embedding engine", selection: binding.embeddingMode) {
                    ForEach(MemoryIndexSettings.embeddingModes, id: \.self) { Text($0).tag($0) }
                }
                TextField("Embedding model", text: binding.embeddingModel)
                    .textFieldStyle(.roundedBorder)
                if binding.wrappedValue.embeddingMode == "mlx" {
                    Text("LEANN's MLX mode averages a language model's outputs instead of using a real embedding, so search quality is poor. Prefer sentence-transformers.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Stepper("Chunk size: \(binding.wrappedValue.chunkSize) words", value: binding.chunkSize, in: 64...2048, step: 32)
                Stepper("Chunk overlap: \(binding.wrappedValue.chunkOverlap) words", value: binding.chunkOverlap, in: 0...512, step: 8)
                Stepper("Graph degree: \(binding.wrappedValue.graphDegree)", value: binding.graphDegree, in: 8...128, step: 4)
                Stepper("Build complexity: \(binding.wrappedValue.buildComplexity)", value: binding.buildComplexity, in: 16...512, step: 16)
                Toggle("Recompute embeddings at search time (smaller index, ~100× slower search)", isOn: binding.recompute)
                Toggle("Compact storage (needs recompute; disables adding new messages without a rebuild)", isOn: binding.compact)
                Stepper("Search complexity: \(binding.wrappedValue.searchComplexity)", value: binding.searchComplexity, in: 8...512, step: 8)
                Stepper("Results per suggestion: \(binding.wrappedValue.topK)", value: binding.topK, in: 1...20)
                VStack(alignment: .leading) {
                    Text("Meaning vs. exact words: \(Int((binding.wrappedValue.vectorWeight * 100).rounded()))% meaning")
                    Slider(value: binding.vectorWeight, in: 0...1, step: 0.05)
                    Text("0% searches exact words only and never loads the embedding model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !control.rejectedSettings.isEmpty {
                    Text("Not applied (out of range): \(control.rejectedSettings.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Revert") { draft = nil }
                        .disabled(draft == nil || draft == saved)
                    Button("Apply") {
                        if let draft { control.updateIndexSettings(draft) }
                        draft = nil
                    }
                    .disabled(draft == nil || draft == saved)
                    .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Index (LEANN)")
            }
            .settingsItem(.memoryIndex)
        }

        if let savedPrivacy = control.configuration?.privacy {
            let privacy = Binding(get: { privacyDraft ?? savedPrivacy }, set: { privacyDraft = $0 })
            Section("Privacy") {
                Stepper(
                    privacy.wrappedValue.retentionDays == 0
                        ? "Keep messages: forever" : "Keep messages: last \(privacy.wrappedValue.retentionDays) days",
                    value: privacy.retentionDays, in: 0...3650, step: 30
                )
                listField("Never remember conversations (ids, one per line)", privacy.excludedConversations)
                listField("Never remember people (names or addresses, one per line)", privacy.excludedParticipants)
                HStack {
                    Button("Delete All Memory…", role: .destructive) { confirmingDeleteAll = true }
                    Spacer()
                    Button("Apply") {
                        if let privacyDraft { control.updatePrivacy(privacyDraft) }
                        privacyDraft = nil
                    }
                    .disabled(privacyDraft == nil || privacyDraft == savedPrivacy)
                }
                Text("Memory stays on this Mac, in Cotabby's folder. It is never sent to an endpoint model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsItem(.memoryPrivacy)
            .confirmationDialog("Delete all memory?", isPresented: $confirmingDeleteAll) {
                Button("Delete All Memory", role: .destructive) { control.deleteAllMemory() }
            } message: {
                Text("Removes the index and every stored message. Sources stay configured and can sync again.")
            }
        }
    }

    @ViewBuilder
    private var indexStatus: some View {
        if let index = control.status?.index {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(index.built ? "\(index.passages) passages · \(MemoryPaneView.byteLabel(index.sizeBytes))" : "Not built yet")
                    if let reason = index.needsRebuild {
                        Text("Needs a rebuild: \(reason)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Rebuild") { control.rebuildIndex() }
                Button("Remove") { control.removeIndex() }
                    .disabled(!index.built)
            }
            .controlSize(.small)
        }
    }

    private func listField(_ title: String, _ values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { values.wrappedValue.joined(separator: "\n") },
                set: { values.wrappedValue = $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            .font(.callout)
            .frame(minHeight: 44, maxHeight: 90)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
        }
    }
}
