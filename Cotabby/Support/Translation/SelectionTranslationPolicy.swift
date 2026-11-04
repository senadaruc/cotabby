import Foundation
import NaturalLanguage

/// File overview:
/// Pure gate for Translate on Select. A selection is translated when the app allows Cotabby, the text
/// is nobody's password or terminal screen, it is long enough to mean something and short enough for
/// the model, and it is not already in the target language. Language is decided in two steps:
/// `TranslationLanguagePolicy.detect` (strict, 12+ letters, 0.8 confidence) for sentences, then a loose
/// single-word guess, because "what does this word mean" is the most common use and a strict detector
/// never answers for one word. With neither answer the automatic trigger stays quiet (every
/// double-clicked word would otherwise cost a model call) while the shortcut, an explicit request,
/// translates anyway. Pure apart from `NLLanguageRecognizer`, which is on-device and deterministic.
nonisolated enum SelectionTranslationPolicy {
    static let minimumLetters = 3
    /// Matches `SelectionRewriteEligibility.maximumCharacters` and the engine's hard cap.
    static let maximumCharacters = 2_000
    /// The loose guess needs a few letters and only a weak majority: a wrong "translate" costs one
    /// model call whose echo is hidden, a wrong "same language" costs a missed translation.
    static let looseMinimumLetters = 4
    static let looseMinimumConfidence = 0.3

    enum Verdict: Equatable {
        /// Translate; `sourceCode` is the detected BCP-47 code, nil when the shortcut asked and no
        /// detection was possible (the prompt then names only the target).
        case translate(sourceCode: String?)
        case sameLanguage
        case undetected
        case tooShort
        case tooLong
        case ineligible
    }

    /// Password managers show revealed passwords and secure notes as plain static text, which the read-only
    /// reader would happily capture. In automatic mode with a cloud provider a double-click there would
    /// send them off the Mac, so these apps are never eligible.
    static let passwordManagerBundlePrefixes = [
        "com.apple.Passwords", "com.agilebits.onepassword", "com.1password", "com.bitwarden", "com.lastpass",
        "com.dashlane", "com.keepassxc", "org.keepassxc", "com.nordpass", "com.enpass", "in.sinew.Enpass"
    ]

    static func isPasswordManager(bundleIdentifier: String) -> Bool {
        passwordManagerBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    static func verdict(
        for capture: SelectedTextCapture,
        targetLanguage: String,
        trigger: SelectionTranslationTrigger,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Verdict {
        guard !capture.isSecure, capture.bundleIdentifier != ownBundleIdentifier,
              !TerminalAppDetector.isTerminal(bundleIdentifier: capture.bundleIdentifier),
              !TerminalAppDetector.isTerminalScreenField(bundleIdentifier: capture.bundleIdentifier),
              !isPasswordManager(bundleIdentifier: capture.bundleIdentifier)
        else { return .ineligible }
        let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.filter(\.isLetter).count >= minimumLetters else { return .tooShort }
        guard capture.text.count <= maximumCharacters else { return .tooLong }
        return languageVerdict(for: text, targetLanguage: targetLanguage, trigger: trigger)
    }

    /// The language step alone, on already-trimmed text.
    static func languageVerdict(for text: String, targetLanguage: String, trigger: SelectionTranslationTrigger) -> Verdict {
        if let detection = TranslationLanguagePolicy.detect(text) {
            return TranslationLanguagePolicy.sameLanguage(detection.language, targetLanguage)
                ? .sameLanguage : .translate(sourceCode: detection.language)
        }
        if let guess = looseGuess(text) {
            return TranslationLanguagePolicy.sameLanguage(guess, targetLanguage)
                ? .sameLanguage : .translate(sourceCode: guess)
        }
        switch trigger {
        case .automatic: return .undetected
        case .shortcut: return .translate(sourceCode: nil)
        }
    }

    /// The recogniser's best hypothesis for short text, or nil when it has too little to go on.
    static func looseGuess(_ text: String) -> String? {
        guard text.filter(\.isLetter).count >= looseMinimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.value >= looseMinimumConfidence
        else { return nil }
        return best.key.rawValue
    }

    /// The English name the prompt uses for a BCP-47 code ("nl" → "Dutch"); the code itself when
    /// macOS has no name for it.
    static func englishName(forLanguageCode code: String) -> String {
        let base = TranslationLanguagePolicy.baseCode(code)
        if let name = Locale(identifier: "en").localizedString(forLanguageCode: base) { return name }
        if let option = LanguageCatalog.commonLanguages.first(where: { TranslationLanguagePolicy.sameLanguage($0.code, code) }) {
            return option.name
        }
        return code
    }

    /// A model that answered with the selection itself (already in the target language, or it
    /// declined): the strip has nothing to show.
    static func isEcho(output: String, input: String) -> Bool {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(input.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}
