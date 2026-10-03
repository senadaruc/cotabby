import AppKit
import SwiftUI

/// File overview:
/// The Memory pane's playground and log: type what you might write, name the conversation, and see
/// exactly what memory would hand a suggestion (and how widely it had to look), plus the service's
/// recent log lines.
///
/// The search is the same call suggestions make, scoped by conversation title within one source,
/// so the playground shows the real privacy scope in action; "All of memory" is for exploring and
/// is never used by suggestions.
struct MemoryPlaygroundSection: View {
    @ObservedObject var control: MemoryControlModel
    @ObservedObject var supervisor: MemoryServiceSupervisor
    @State private var query = ""
    @State private var title = ""
    @State private var sourceID = ""
    @State private var global = false
    @State private var showingLogs = false

    var body: some View {
        Section {
            TextField("What you might write…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(runSearch)
            Toggle("Search all of memory (exploring only; suggestions never do this)", isOn: $global)
            if !global {
                HStack {
                    TextField("Conversation title, as the app shows it", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(runSearch)
                    Picker("Source", selection: $sourceID) {
                        ForEach(control.sources) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
            HStack {
                Spacer()
                if control.isSearching { ProgressView().controlSize(.small) }
                Button("Search", action: runSearch)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let result = control.playgroundResult {
                Text(Self.summary(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(result.hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.byline(hit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(hit.text)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Playground")
        }
        .settingsItem(.memoryPlayground)
        .onAppear {
            if sourceID.isEmpty { sourceID = control.sources.first(where: \.enabled)?.id ?? control.sources.first?.id ?? "" }
        }

        Section {
            DisclosureGroup("Service Log", isExpanded: $showingLogs) {
                ScrollView {
                    Text(control.logLines.suffix(200).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                HStack {
                    Button("Refresh") { Task { await control.loadLogs() } }
                    Button("Open Log Folder") {
                        NSWorkspace.shared.open(supervisor.paths.dataDirectory.appendingPathComponent("logs"))
                    }
                }
                .controlSize(.small)
            }
            .onChange(of: showingLogs) { _, expanded in
                if expanded { Task { await control.loadLogs() } }
            }
        }
    }

    private func runSearch() {
        control.search(query: query, title: title, sources: sourceID.isEmpty ? [] : [sourceID], global: global)
    }

    static func summary(_ result: MemorySearchResult) -> String {
        let scope: String
        switch result.scope {
        case "conversation": scope = "from this conversation"
        case "person": scope = "from this conversation and others its people were in"
        case "global": scope = "from all of memory"
        default: scope = "conversation not found, so nothing (suggestions never fall back to other chats)"
        }
        return "\(result.hits.count) result\(result.hits.count == 1 ? "" : "s") \(scope) in \(Int(result.elapsedMs.rounded())) ms"
    }

    static func byline(_ hit: MemorySearchResult.Hit) -> String {
        let date = Date(timeIntervalSince1970: hit.timestamp).formatted(date: .abbreviated, time: .shortened)
        let speaker = hit.isFromMe ? "You" : hit.sender
        return "\(speaker) · \(hit.conversationTitle) · \(date) · \(hit.via)"
    }
}
