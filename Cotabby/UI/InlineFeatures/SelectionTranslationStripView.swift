import Combine
import SwiftUI

/// File overview:
/// The Translate on Select strip: one small dark card floating above the selected text with the
/// translation, a Copy button and a close button. Presentation only: every control calls back into
/// `SelectionTranslationCoordinator` through `SelectionTranslationStripModel`, and the view never
/// holds the coordinator. The strip never takes the keyboard (its panel cannot become key), so no
/// control has a `keyboardShortcut`; a shortcut here would never fire and would suggest otherwise.

/// What the strip shows, owned by the coordinator for one showing.
///
/// `@MainActor` because SwiftUI reads it on the main thread and the coordinator writes it there.
/// `ObservableObject` plus `@Published` lets the view redraw as the translation streams in.
@MainActor
final class SelectionTranslationStripModel: ObservableObject {
    enum Phase: Equatable {
        /// Streaming in; the partial text so far (empty at first).
        case translating(String)
        case shown(String)
        /// Just copied: the same text with a "Copied" tick, for about a second.
        case copied(String)
        case notice(String)
        case failed(String)
    }

    @Published var phase: Phase = .translating("")
    /// The target language as the user reads it ("English").
    @Published var targetLanguageName = ""
    /// "The selected text is sent to api.openai.com." when the provider is off-device; nil otherwise.
    @Published var disclosure: String?

    // Plain closures rather than a delegate: the coordinator is the only owner and wires them once.
    var onCopy: () -> Void = {}
    var onClose: () -> Void = {}
}

/// Renders `SelectionTranslationStripModel`. `@ObservedObject` subscribes to a model the coordinator
/// owns; the view must not create it.
struct SelectionTranslationStripView: View {
    @ObservedObject var model: SelectionTranslationStripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            bodyText
            if let disclosure = model.disclosure {
                Text(disclosure)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .padding(10)
        .popupHUDChrome()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.bubble")
                .foregroundStyle(PopupTheme.secondaryText)
            Text(model.targetLanguageName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PopupTheme.primaryText)
            if case .translating = model.phase {
                Text("Translating…")
                    .font(.caption)
                    .foregroundStyle(PopupTheme.secondaryText)
            }
            Spacer(minLength: 12)
            copyControl
            Button(action: model.onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PopupTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    /// Copy only makes sense once there is a finished translation; while it streams, or for a
    /// notice or failure, there is nothing worth copying.
    @ViewBuilder private var copyControl: some View {
        switch model.phase {
        case .shown:
            Button(action: model.onCopy) {
                Label("Copy", systemImage: "doc.on.doc").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PopupTheme.primaryText)
        case .copied:
            Button(action: model.onCopy) {
                Label("Copied", systemImage: "checkmark").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PopupTheme.secondaryText)
            .disabled(true)
        default:
            EmptyView()
        }
    }

    /// Deliberately not a `ScrollView`: the panel sizes itself to this view's fitting size, and a
    /// scroll view reports no intrinsic height, so the strip would collapse (see
    /// `SelectionRewritePopupView.preview`).
    @ViewBuilder private var bodyText: some View {
        switch model.phase {
        case .translating(let partial):
            if !partial.isEmpty { text(partial, primary: false) }
        case .shown(let text), .copied(let text):
            // No `.textSelection`: the panel can never become key, so ⌘C would go to the host; Copy covers it.
            self.text(text, primary: true)
        case .notice(let message), .failed(let message):
            text(message, primary: false).font(.callout)
        }
    }

    private func text(_ string: String, primary: Bool) -> some View {
        Text(string)
            .font(.system(size: 13))
            .foregroundStyle(primary ? PopupTheme.primaryText : PopupTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
    }
}
