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
            FlowRow(items: RewriteAction.presets) { action in
                Button(action.label) { model.onAction(action) }.buttonStyle(.bordered)
            }
            HStack {
                TextField("Custom instruction (e.g. make it warmer)", text: $model.customInstruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitCustom() }
                Button("Go") { submitCustom() }.disabled(model.customInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle("Use memory", isOn: $model.usesMemory).disabled(!model.memoryToggleEnabled)
            if let note = model.memoryNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func submitCustom() {
        let instruction = model.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        model.onAction(.custom(instruction))
    }

    /// `final` false means the text is still streaming in, so it is drawn dimmed.
    private func preview(_ text: String, final: Bool) -> some View {
        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 180)
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

/// Wraps buttons onto as many lines as the popup width needs.
private struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        // `ViewThatFits` (macOS 13+; the deployment target is 14.0) picks the first layout that fits
        // the offered width: one row when all buttons fit, otherwise two rows.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(items, id: \.self, content: content) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { ForEach(items.prefix(3), id: \.self, content: content) }
                HStack(spacing: 6) { ForEach(items.dropFirst(3), id: \.self, content: content) }
            }
        }
    }
}
