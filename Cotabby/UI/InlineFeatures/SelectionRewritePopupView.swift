import AppKit
import Combine
import SwiftUI

/// File overview:
/// The selection-rewrite popup. Its first phase is a one-row strip in the style of a selection
/// toolbar: the five tones as icon buttons, the Fix and Memory toggles, a pencil that unfolds the
/// custom-instruction box, and Close. Every later phase (generating, preview with Replace / Copy /
/// Retry, failure, notice) is the card it always was. Presentation only: every button calls back
/// into `SelectionRewriteCoordinator` through `SelectionRewritePopupModel`.

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
    /// Replaces even though the rewrite changed a name or number the user wrote (see `changeWarning`).
    var onReplaceAnyway: () -> Void = {}
    /// What the rewrite changed that the user should check before replacing; nil when nothing did.
    @Published var changeWarning: String?
    var onCopy: () -> Void = {}
    var onRetry: () -> Void = {}
    /// Shorter / Longer on the preview: reshape the result on screen, keeping its tone.
    var onRefine: (RewriteAction) -> Void = { _ in }
    var onClose: () -> Void = {}
}

/// Renders `SelectionRewritePopupModel.phase`: the strip for `.actions`, a card for the rest.
/// `@ObservedObject` subscribes the view to the model it is given; the model is owned by the
/// coordinator, so the view must not create it.
struct SelectionRewritePopupView: View {
    @ObservedObject var model: SelectionRewritePopupModel
    /// The custom-instruction box is folded into a pencil button until it is wanted: the strip
    /// stays one row wide for the common case of picking a tone.
    @State private var showsCustom = false

    var body: some View {
        switch model.phase {
        case .actions: strip
        default: card
        }
    }

    // MARK: - The strip

    /// Dark whatever the system appearance, like a selection toolbar, so it reads as one floating
    /// control over any host's text rather than as a window.
    private static let stripColor = Color(red: 0.13, green: 0.13, blue: 0.14)

    private var strip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                ForEach(RewriteAction.tones, id: \.self) { tone in
                    StripItem(icon: Self.symbol(for: tone), label: tone.label, help: "Rewrite for \(tone.label.lowercased())") {
                        model.onAction(tone)
                    }
                }
                stripDivider
                StripItem(icon: "text.badge.checkmark", isOn: model.fixesMistakes, help: "Fix spelling & grammar") {
                    model.fixesMistakes.toggle()
                }
                StripItem(icon: "brain", isOn: model.usesMemory, disabled: !model.memoryToggleEnabled,
                          help: model.memoryToggleEnabled ? "Use memory" : (model.memoryNote ?? "Memory is off")) {
                    model.usesMemory.toggle()
                }
                StripItem(icon: "pencil.line", isOn: showsCustom, help: "Custom instruction") {
                    showsCustom.toggle()
                }
                if showsCustom { customBox }
                stripDivider
                StripItem(icon: "xmark", help: "Close") { model.onClose() }
            }
            .padding(4)
            .background(Self.stripColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // The off-device disclosure and the memory note have no room in the row, so they hang
            // under it in the same dark style; both matter before the user picks a tone.
            ForEach([model.disclosure, model.memoryNote].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(line == model.disclosure ? Color.orange : Color.white.opacity(0.8))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Self.stripColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var stripDivider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 18).padding(.horizontal, 3)
    }

    private var customBox: some View {
        HStack(spacing: 4) {
            TextField("Custom instruction (e.g. make it warmer)", text: $model.customInstruction)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 230)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onSubmit { submitCustom() }
            StripItem(icon: "arrow.right.circle.fill", disabled: model.customInstruction.trimmingCharacters(in: .whitespaces).isEmpty,
                      help: "Go") { submitCustom() }
        }
    }

    /// One icon per tone, chosen to read at 13pt: who the message is for.
    private static func symbol(for tone: RewriteAction) -> String {
        switch tone {
        case .family: return "house.fill"
        case .friendly: return "face.smiling"
        case .closeFriend: return "heart.fill"
        case .formal: return "briefcase.fill"
        case .customer: return "person.crop.circle"
        default: return "wand.and.stars"
        }
    }

    // MARK: - The card

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch model.phase {
            case .actions: EmptyView()
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

    private func submitCustom() {
        let instruction = model.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        model.onAction(.custom(instruction))
    }

    /// The rewrite as wrapped text. Short text is shown at its full height; text taller than
    /// `maximumPreviewHeight` scrolls inside a frame of exactly that height, so the buttons below
    /// always stay on screen. The height is given explicitly because the panel sizes itself to the
    /// view's fitting size, and a bare ScrollView has no ideal height (it would collapse to nothing).
    /// `final` false means the text is still streaming in, so it is drawn dimmed.
    @ViewBuilder
    private func preview(_ text: String, final: Bool) -> some View {
        let label = Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(final ? .primary : .secondary)
        if Self.previewNeedsScrolling(text) {
            ScrollView { label }.frame(height: Self.maximumPreviewHeight)
        } else {
            label
        }
    }

    /// The tallest the preview grows before it scrolls: about 18 lines, which with the rest of the
    /// popup fits on the smallest screens Cotabby supports.
    static let maximumPreviewHeight: CGFloat = 300
    /// The text's width inside the popup: the 360 pt card minus its 12 pt padding on each side.
    static let previewWidth: CGFloat = 336

    /// Whether `text` laid out at the preview's width and the system body font is taller than
    /// `maximumPreviewHeight`. Measured with TextKit rather than SwiftUI so the answer is known
    /// before layout and pinned by tests.
    static func previewNeedsScrolling(_ text: String) -> Bool {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let bounds = attributed.boundingRect(
            with: CGSize(width: previewWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return bounds.height > maximumPreviewHeight
    }

    private func previewResult(_ text: String, unsupported: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            preview(text, final: true)
            if !unsupported.isEmpty {
                // The rewrite changed a name or number the user wrote: say what, and let them decide.
                // "Replace anyway" is a deliberate click; Return does not trigger it.
                Text(model.changeWarning ?? "The rewrite changed: \(unsupported.joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if unsupported.isEmpty {
                    Button("Replace") { model.onReplace() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Replace anyway") { model.onReplaceAnyway() }
                }
                Button("Copy") { model.onCopy() }
                Button("Retry") { model.onRetry() }
                Spacer()
                // Reshape this result, keeping the tone that produced it.
                ForEach(RewriteAction.refinements, id: \.self) { length in
                    Button(length.label) { model.onRefine(length) }
                }
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

/// One control in the strip: an icon, an optional label, a hover highlight, and a tint while a
/// toggle is on. A plain `Button` so the first click lands on it (the hosting view accepts the
/// first mouse) and so VoiceOver reads `help`.
private struct StripItem: View {
    let icon: String
    var label: String?
    var isOn = false
    var disabled = false
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                if let label { Text(label).font(.system(size: 13, weight: .medium)) }
            }
            .foregroundStyle(.white.opacity(disabled ? 0.35 : 1))
            .padding(.horizontal, label == nil ? 7 : 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.55) : Color.white.opacity(isHovered && !disabled ? 0.16 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
