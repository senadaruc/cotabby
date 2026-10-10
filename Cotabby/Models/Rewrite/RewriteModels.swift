import CoreGraphics
import Foundation

/// File overview:
/// Values shared by the selection-rewrite subsystem: what the user asked for, what memory added,
/// and the user's Rewrite settings. Pure data; the coordinator, engine and prompt builder pass them
/// between each other so none of them owns another's state.

/// One rewrite the popup offers. `custom` carries the user's own instruction.
nonisolated enum RewriteAction: Equatable, Hashable, Sendable {
    case fixOnly, rewrite, shorter, longer
    case family, friendly, closeFriend, formal, customer
    case custom(String)

    /// The popup's buttons: who the text is for. `custom` comes from the instruction box instead.
    /// Typo fixing is the tick box, not a button.
    static let tones: [RewriteAction] = [.family, .friendly, .closeFriend, .formal, .customer]
    /// Offered on the preview once a tone was chosen: they reshape that result, keeping its tone.
    static let refinements: [RewriteAction] = [.shorter, .longer]

    var label: String {
        switch self {
        case .fixOnly: return "Fix only"
        case .rewrite: return "Rewrite"
        case .shorter: return "Shorter"
        case .longer: return "Longer"
        case .family: return "Family"
        case .friendly: return "Friendly"
        case .closeFriend: return "Close friend"
        case .formal: return "Formal"
        case .customer: return "Customer"
        case .custom: return "Custom"
        }
    }

    /// Longer expands the message from what memory knows, so it gathers memory whenever memory may
    /// be used, whatever the popup's "Use memory" box says.
    var alwaysUsesMemory: Bool { self == .longer }
}

/// Which model rewrites: Cotabby's own local models, or the user's OpenAI-compatible API.
nonisolated enum RewriteProviderKind: String, CaseIterable, Sendable {
    case local, api
}

/// The Rewrite settings, as one snapshot the coordinator and engine read per rewrite.
nonisolated struct RewritePreferences: Equatable, Sendable {
    var provider: RewriteProviderKind
    var apiBaseURL: String
    var apiModelName: String
    var usesMemoryByDefault: Bool
    /// The popup's "Fix spelling & grammar" tick box: every action except Fix only also corrects
    /// mistakes when it is on. Remembered between rewrites.
    var fixesMistakes: Bool
    /// Whether memory facts and style examples may go to the API provider. Off by default: memory
    /// otherwise never leaves the Mac.
    var sendsMemoryToAPI: Bool
    var showsButtonOnSelection: Bool
    var shortcutKeyCode: CGKeyCode
    var shortcutModifiers: UInt32
    var shortcutLabel: String

    static let defaults = RewritePreferences(
        provider: .local,
        apiBaseURL: "",
        apiModelName: "",
        usesMemoryByDefault: false,
        fixesMistakes: true,
        sendsMemoryToAPI: false,
        showsButtonOnSelection: true,
        shortcutKeyCode: 15, // kVK_ANSI_R
        shortcutModifiers: ShortcutModifierMask.control.rawValue | ShortcutModifierMask.option.rawValue,
        shortcutLabel: "⌃⌥R"
    )
}

/// What memory contributes to one rewrite: facts about the person or thread, and a few of the
/// user's own messages there as style. Empty when memory is off or found nothing.
nonisolated struct RewriteMemoryContext: Equatable, Sendable {
    nonisolated struct Fact: Equatable, Sendable {
        let text: String
        let source: String
        let sender: String
    }

    let facts: [Fact]
    let styleExamples: [String]

    static let empty = RewriteMemoryContext(facts: [], styleExamples: [])
    var isEmpty: Bool { facts.isEmpty && styleExamples.isEmpty }
}

/// One rewrite to run: the selected text, the action, and any memory.
nonisolated struct RewriteRequest: Equatable, Sendable {
    let selection: String
    let action: RewriteAction
    let memory: RewriteMemoryContext
    /// The selection's language by its English name ("Turkish"), when `RewriteLanguageDetector`
    /// could tell; the prompt then requires it instead of hoping the model keeps the language.
    var language: String? = nil
    /// The "Fix spelling & grammar" tick box at the time of the rewrite.
    var fixesMistakes: Bool = true
    /// Set when Shorter or Longer refines an earlier result: the tone (or custom instruction) that
    /// produced it, which the refinement keeps. `selection` is then that result, not the user's text.
    var tone: RewriteAction? = nil
}

nonisolated enum RewriteError: LocalizedError, Equatable {
    case noProvider
    case unusableOutput
    case selectionTooLong

    var errorDescription: String? {
        switch self {
        case .noProvider: return "Set up a rewrite model in Settings → Rewrite."
        case .unusableOutput: return "Couldn't rewrite this — try again."
        case .selectionTooLong: return "Selection too long to rewrite."
        }
    }
}
