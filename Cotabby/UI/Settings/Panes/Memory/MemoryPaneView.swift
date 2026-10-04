import AppKit
import SwiftUI

/// File overview:
/// Settings → Memory: everything about conversation memory, the local LEANN index of the user's
/// chat and mail history that suggestions can draw on.
///
/// Presentation only. The process lifecycle (install, start, restart) belongs to
/// `MemoryServiceSupervisor`; what the running service reports and every action sent to it go
/// through `MemoryControlModel`. The pane is split into sections by responsibility so each file
/// stays readable: this one holds the service switch and install flow, the others hold sources,
/// index settings, privacy and the playground.
struct MemoryPaneView: View {
    @ObservedObject var supervisor: MemoryServiceSupervisor
    @ObservedObject var control: MemoryControlModel
    @State private var confirmingReset = false

    var body: some View {
        SettingsPaneScaffold {
            serviceSection
            if supervisor.state == .running {
                MemorySourcesSection(control: control, historySync: control.historySync)
                MemoryIndexSection(control: control)
                MemoryPlaygroundSection(control: control, supervisor: supervisor)
            }
        }
        .onAppear {
            control.beginObserving()
            control.historySync.refreshReadiness()
        }
        .onDisappear { control.endObserving() }
    }

    // MARK: - Service

    private var serviceSection: some View {
        Section {
            Toggle(isOn: Binding(get: { supervisor.isEnabled }, set: { supervisor.setEnabled($0) })) {
                SettingsRowLabel(
                    title: "Conversation Memory",
                    description: "Remember your chat and mail history on this Mac so suggestions can use what " +
                        "was said earlier in the same conversation. Nothing leaves the Mac, and memory is never " +
                        "sent to an endpoint model.",
                    systemImage: "brain"
                )
            }
            .settingsItem(.memoryService)

            if supervisor.isEnabled {
                HStack(alignment: .firstTextBaseline) {
                    Text("Service")
                    Spacer()
                    Text(stateLabel)
                        .foregroundStyle(stateIsProblem ? .orange : .secondary)
                        .multilineTextAlignment(.trailing)
                }
                serviceActions
                if let status = control.status, supervisor.state == .running {
                    detailRow("Versions", "cotabby-memory \(status.serviceVersion) · LEANN \(status.leannVersion ?? "?") · Python \(status.python)")
                    detailRow("Index", indexSummary(status.index))
                }
                if let error = control.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Memory")
        }
    }

    @ViewBuilder
    private var serviceActions: some View {
        switch supervisor.state {
        case .needsInstall:
            VStack(alignment: .leading, spacing: 6) {
                Text("Installing downloads Python packages (LEANN, PyTorch, sentence-transformers; about 2 GB) " +
                     "into Cotabby's folder, and later an embedding model (about 1.2 GB) on the first index build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if supervisor.uvPath == nil {
                    Text("Cotabby uses uv to install them. Install uv first, in Terminal:")
                        .font(.caption)
                    Text("curl -LsSf https://astral.sh/uv/install.sh | sh")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Install") { supervisor.install() }
                        .disabled(supervisor.uvPath == nil && MemoryServiceSupervisor.findUV() == nil)
                    if supervisor.uvPath == nil {
                        Button("Check Again") { supervisor.install() }
                    }
                }
            }
        case .failed:
            HStack {
                Button("Restart") { supervisor.restart() }
                Button("Reinstall") { supervisor.install() }
                Button("Show Install Log") { NSWorkspace.shared.open(supervisor.paths.installLog) }
            }
        case .running:
            HStack {
                Button("Restart") { supervisor.restart() }
                Button("Open Memory Folder") { NSWorkspace.shared.open(supervisor.paths.root) }
            }
        case .keyMismatch:
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory is encrypted with a key this Mac's Keychain no longer has, so it cannot be read. " +
                     "Delete it and sync your sources again to rebuild it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Memory and Start Over…", role: .destructive) { confirmingReset = true }
            }
            .confirmationDialog("Delete the unreadable memory?", isPresented: $confirmingReset) {
                Button("Delete Memory", role: .destructive) { supervisor.deleteMemoryData() }
            } message: {
                Text("Your sources and settings stay; only the stored messages and the index are deleted.")
            }
        case .installing, .starting, .disabled:
            EmptyView()
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private var stateLabel: String {
        switch supervisor.state {
        case .disabled: return "Off"
        case .needsInstall(let reason): return reason
        case .installing(let step): return step
        case .starting: return "Starting…"
        case .running: return control.status?.busy == true ? "Running · working in the background" : "Running"
        case .failed(let message): return message
        case .keyMismatch: return "Memory cannot be read with this Mac's key"
        }
    }

    private var stateIsProblem: Bool {
        switch supervisor.state {
        case .failed, .keyMismatch: return true
        default: return false
        }
    }

    static func byteLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func indexSummary(_ index: MemoryIndexStatus) -> String {
        guard index.built else { return index.needsRebuild.map { "not built (\($0))" } ?? "not built yet" }
        var parts = ["\(index.passages) passages", Self.byteLabel(index.sizeBytes)]
        if let reason = index.needsRebuild { parts.append("needs rebuild: \(reason)") }
        return parts.joined(separator: " · ")
    }
}
