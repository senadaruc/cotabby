import Combine
import SwiftUI

/// File overview:
/// The selection-rewrite popup: the five preset actions, the custom instruction box, the memory
/// toggle with its disclosure, and the preview with Replace / Copy / Retry. Presentation only:
/// every button calls back into `SelectionRewriteCoordinator` through `SelectionRewritePopupModel`.

/// What the popup shows, owned by the coordinator for one popup's lifetime.
///
/// `@MainActor` because SwiftUI reads these properties on the main thread and the coordinator writes
/// them there. `ObservableObject` plus `@Published` (a property wrapper that announces each change)
/// lets `SelectionRewritePopupView` redraw whenever the coordinator moves the popup to a new phase.
@MainActor
final class SelectionRewritePopupModel: ObservableObject {
    /// The popup's single visible state. The coordinator moves it forward as a rewrite runs.
    enum Phase: Equatable {
        case actions
        case generating(String)
        case preview(text: String, unsupported: [String])
        case failed(String)
        case notice(String)
    }

    @Published var phase: Phase = .actions
    @Published var usesMemory = false
    /// The "Fix spelling & grammar" tick box; the coordinator seeds it from Settings and remembers changes.
    @Published var fixesMistakes = true
    @Published var memoryToggleEnabled = true
    /// Why memory is off, or what it found ("No memory for this person").
    @Published var memoryNote: String?
    /// "The selected text is sent to api.openai.com." when the provider is off-device.
    @Published var disclosure: String?
    @Published var customInstruction = ""

    // Callbacks are plain closures rather than a delegate protocol: the coordinator is the only
    // owner and wires each one once. The view never holds a reference back to the coordinator.
    var onAction: (RewriteAction) -> Void = { _ in }
    var onReplace: () -> Void = {}
    var onCopy: () -> Void = {}
    var onRetry: () -> Void = {}
    var onClose: () -> Void = {}
}

/// Renders `SelectionRewritePopupModel.phase` as one card. `@ObservedObject` subscribes the view to
/// the model it is given; the model is owned by the coordinator, so the view must not create it.
struct SelectionRewritePopupView: View {
    @ObservedObject var model: SelectionRewritePopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.phase {
            case .actions: actions
            case .generating(let partial): preview(partial.isEmpty ? "Rewriting…" : partial, final: false)
            case .preview(let text, let unsupported): previewResult(text, unsupported: unsupported)
            case .failed(let message): failure(message)
            case .notice(let message): Text(message).font(.callout).foregroundStyle(.secondary)
            }
            // The disclosure stays on screen in every phase: while the text is generating and in the
            // preview too, since the selected text is sent off-device whichever phase is showing.
            if let disclosure = model.disclosure { Text(disclosure).font(.caption).foregroundStyle(.orange) }
            // The memory note (why memory is off, or what it found) follows the phase too, so a
            // rewrite that found nothing still says so in the preview.
            if let note = model.memoryNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack {
            Label("Rewrite with AI", systemImage: "wand.and.stars").font(.headline)
            Spacer()
            Button { model.onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            // What to do with the text, then who it is for.
            WrapLayout(spacing: 6) {
                ForEach(RewriteAction.actions, id: \.self) { action in
                    Button(action.label) { model.onAction(action) }.buttonStyle(.bordered)
                }
            }
            WrapLayout(spacing: 6) {
                ForEach(RewriteAction.tones, id: \.self) { action in
                    Button(action.label) { model.onAction(action) }.buttonStyle(.bordered)
                }
            }
            Toggle("Fix spelling & grammar", isOn: $model.fixesMistakes)
            HStack {
                TextField("Custom instruction (e.g. make it warmer)", text: $model.customInstruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitCustom() }
                Button("Go") { submitCustom() }.disabled(model.customInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle("Use memory", isOn: $model.usesMemory).disabled(!model.memoryToggleEnabled)
        }
    }

    private func submitCustom() {
        let instruction = model.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        model.onAction(.custom(instruction))
    }

    /// The rewrite as plain wrapped text at its full height. Not a ScrollView: the panel sizes itself
    /// to the view's fitting size, and a ScrollView has no ideal height, so the preview collapsed to
    /// nothing and only its scroller showed (2026-10-10). A selection is at most 2,000 characters, and
    /// the panel's placement keeps it on screen. `final` false means the text is still streaming in,
    /// so it is drawn dimmed.
    private func preview(_ text: String, final: Bool) -> some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(final ? .primary : .secondary)
    }

    private func previewResult(_ text: String, unsupported: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            preview(text, final: true)
            if !unsupported.isEmpty {
                // Replace is disabled when the rewrite introduced names or facts the user never
                // wrote; Copy stays available so the user can still take the text by hand.
                Text("Not in your text or memory: \(unsupported.joined(separator: ", ")). Replace is off; Copy still works.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Replace") { model.onReplace() }.keyboardShortcut(.defaultAction).disabled(!unsupported.isEmpty)
                Button("Copy") { model.onCopy() }
                Button("Retry") { model.onRetry() }
                Spacer()
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.callout)
            HStack {
                Button("Retry") { model.onRetry() }
                Spacer()
            }
        }
    }
}

/// Lays buttons out left to right and wraps onto a new line when the popup's width runs out, so
/// the nine actions and tones need no fixed row split.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .greatestFiniteMagnitude)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + extra > width {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
