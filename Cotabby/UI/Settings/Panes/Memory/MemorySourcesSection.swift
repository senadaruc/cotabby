import AppKit
import SwiftUI

/// File overview:
/// The Memory pane's sources and background jobs: which message sources feed memory, whether
/// each is ready (permission, sign-in, folder), how much it holds, and the sync/build work running.
///
/// Presentation only: every change goes through `MemoryControlModel`. Requirements are rendered
/// from what the service declares per source (`MemorySource.requirements`), so a new connector on
/// the Python side appears here without Swift changes beyond its requirement kinds.
struct MemorySourcesSection: View {
    @ObservedObject var control: MemoryControlModel

    var body: some View {
        Section {
            ForEach(control.sources) { source in
                sourceRow(source)
            }
            if control.sources.isEmpty {
                Text("Loading sources…").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Sources")
                Spacer()
                Button("Sync All") { Task { await control.sync() } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .settingsItem(.memorySources)

        if !control.jobs.isEmpty {
            Section("Background Work") {
                ForEach(control.jobs.prefix(6)) { job in
                    jobRow(job)
                }
            }
        }
    }

    // MARK: - Source

    private func sourceRow(_ source: MemorySource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { source.enabled },
                set: { control.setSourceEnabled(source.id, enabled: $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                    Text(source.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: source.check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(source.check.ok ? .green : .orange)
                Text(source.check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            ForEach(source.requirements, id: \.kind) { requirement in
                requirementControl(requirement, source: source)
            }

            if source.stats.messages > 0 || source.enabled {
                HStack {
                    Text(Self.statsLabel(source.stats))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync Now") { Task { await control.sync(source.id) } }
                        .disabled(!source.enabled || !source.check.ok)
                    Button("Forget") { control.forget(source.id) }
                        .disabled(source.stats.messages == 0)
                        .help("Delete everything remembered from this source and rebuild the index without it.")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func requirementControl(_ requirement: MemorySource.Requirement, source: MemorySource) -> some View {
        switch requirement.kind {
        case "folder":
            HStack {
                Text(source.options["folder"]?.nonEmptyPath ?? "No folder chosen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder(for: source.id) }
                    .controlSize(.small)
            }
        case "full_disk_access":
            if !source.check.ok {
                Button("Open Full Disk Access Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .help("Add Cotabby to Full Disk Access so its memory service can read \(source.title)'s local history.")
            }
        default:
            if !requirement.detail.isEmpty {
                Text("\(requirement.title): \(requirement.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder(for sourceID: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        control.setSourceOption(sourceID, key: "folder", value: url.path)
    }

    static func statsLabel(_ stats: MemorySource.Stats) -> String {
        var parts = ["\(stats.messages) messages in \(stats.conversations) conversations"]
        if stats.pending > 0 { parts.append("\(stats.pending) waiting to be indexed") }
        if let last = stats.lastSync {
            parts.append("synced " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: last), relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Jobs

    private func jobRow(_ job: MemoryJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.title)
                Spacer()
                Text(job.status)
                    .font(.caption)
                    .foregroundStyle(job.status == "failed" ? .orange : .secondary)
                if job.isActive {
                    Button("Cancel") { control.cancelJob(job.id) }
                        .controlSize(.small)
                }
            }
            if job.isActive {
                ProgressView(value: job.progress)
            }
            let detail = job.error ?? job.message
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(job.error == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }
        }
    }
}

private extension String {
    /// The path with the home folder shortened to `~`, or nil when empty.
    var nonEmptyPath: String? {
        guard !isEmpty else { return nil }
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
