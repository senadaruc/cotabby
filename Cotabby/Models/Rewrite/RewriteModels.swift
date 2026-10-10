import CoreGraphics
import Foundation

/// File overview:
/// Values shared by the selection-rewrite subsystem: what the user asked for, what memory added,
/// and the user's Rewrite settings. Pure data; the coordinator, engine and prompt builder pass them
/// between each other so none of them owns another's state.

/// One rewrite the popup offers. `custom` carries the user's own instruction.
nonisolated enum RewriteAction: Equatable, Hashable, Sendable {
    case fixGrammar, rewrite, formal, friendly, shorter
    case custom(String)

    /// The preset buttons, in popup order. `custom` comes from the instruction box instead.
    static let presets: [RewriteAction] = [.fixGrammar, .rewrite, .formal, .friendly, .shorter]

    var label: String {
        switch self {
        case .fixGrammar: return "Fix spelling & grammar"
        case .rewrite: return "Rewrite"
        case .formal: return "Formal"
        case .friendly: return "Friendly"
        case .shorter: return "Shorter"
        case .custom: return "Custom"
        }
    }
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
