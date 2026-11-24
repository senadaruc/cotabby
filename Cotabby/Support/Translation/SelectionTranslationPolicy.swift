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

    /// Apps whose chat bubbles expose no text selection at all but describe each message in one
    /// accessibility sentence (`WhatsAppMessageDescriptionParser`). In these apps a selection gesture
    /// that every ordinary read path missed translates the whole message under the pointer instead.
    /// Exact identifiers, not prefixes: the bubble walk runs only for an app whose sentence shape was
    /// measured, so adding another app is one line here once its shape is known to match.
    static let wholeMessageBundleIdentifiers: Set<String> = [
        "net.whatsapp.WhatsApp"
    ]

    static func readsWholeMessage(bundleIdentifier: String) -> Bool {
        wholeMessageBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Whether a message looks like it carries a one-time code (a verification or login code).
    ///
    /// Why it exists: the whole-message path translates a bubble the user never selected exactly, and
    /// double-clicking a code to copy it is a natural gesture. The bubble is static text, so no field
    /// detector runs on it, and the text could go to a cloud provider. This content check is what
    /// stands in for those detectors there.
    ///
    /// The rule, over ASCII digit runs (maximal, so a run is never part of a longer run):
    /// - a run of 5 to 8 digits matches when no letter touches either side, it is not preceded by "+",
    ///   and no digit continues the token across a single space, hyphen, dot, comma, colon or slash
    ///   (before or after it). That excludes phone numbers ("+31 6 12345678", "+31612345678"),
    ///   decimals ("12345.50"), and runs of nine or more digits (a run of 8 or fewer is checked whole).
    /// - a grouped code matches: a run of exactly 3 digits, one space or hyphen, a run of exactly 3
    ///   digits ("123 456", "123-456"), with the same neighbour rules on the outer sides only, so
    ///   "123-456-7890" and "555 123 456 789" do not match.
    ///
    /// Deliberately missed: 4-digit codes (years, amounts and room numbers would match too), 9 or more
    /// digit codes, codes with letters ("G482913" with no separator, alphanumeric codes), and codes
    /// spelled out in words. A miss only means the message is translated; a false hit only means no
    /// strip, which is why the rule leans on digits and shape rather than on keywords like "code".
    static func looksLikeOneTimeCode(_ text: String) -> Bool {
        let chars = Array(text)
        func isDigit(_ index: Int) -> Bool {
            chars.indices.contains(index) && chars[index].isASCII && chars[index].isNumber
        }
        func isSeparator(_ char: Character) -> Bool { " -.,:/".contains(char) }
        // Maximal digit runs as (start, end exclusive).
        var runs: [(start: Int, end: Int)] = []
        var index = 0
        while index < chars.count {
            guard isDigit(index) else { index += 1; continue }
            let start = index
            while isDigit(index) { index += 1 }
            runs.append((start, index))
        }
        func leftBlocked(_ run: (start: Int, end: Int)) -> Bool {
            guard run.start > 0 else { return false }
            let previous = chars[run.start - 1]
            if previous.isLetter || previous == "+" { return true }
            return isSeparator(previous) && isDigit(run.start - 2)
        }
        func rightBlocked(_ run: (start: Int, end: Int)) -> Bool {
            guard run.end < chars.count else { return false }
            let next = chars[run.end]
            if next.isLetter { return true }
            return isSeparator(next) && isDigit(run.end + 1)
        }
        for (position, run) in runs.enumerated() {
            let length = run.end - run.start
            if (5...8).contains(length), !leftBlocked(run), !rightBlocked(run) { return true }
            guard length == 3, position + 1 < runs.count, !leftBlocked(run) else { continue }
            let next = runs[position + 1]
            if next.start == run.end + 1, next.end - next.start == 3,
               chars[run.end] == " " || chars[run.end] == "-",
               !rightBlocked(next) { return true }
        }
        return false
    }

    /// Credential vocabulary for message content, stored already folded (lowercase, no diacritics) so
    /// it compares against `folded(_:)` output: "şifre" is written "sifre" here. Deliberately small and
    /// conservative: it names the credentials people actually send in chats (English, plus the Dutch
    /// and Turkish the user's conversations use), not every word near a secret. A miss only means the
    /// message is translated; a false hit only means no strip, so the list leans toward refusing.
    static let credentialKeywords = [
        "password", "passcode", "passphrase", "pin", "pincode", "pin code", "cvv", "cvc", "otp", "2fa",
        "verification code", "security code", "login code", "one-time code", "one time code",
        "authentication code",
        "wachtwoord", "verificatiecode", "beveiligingscode", "inlogcode",
        "sifre", "parola", "dogrulama kodu", "guvenlik kodu"
    ]

    /// Whether a message talks about a credential (a password, PIN, security or one-time code).
    ///
    /// Why it exists: the field detectors read a bubble's description as a field LABEL, and here the
    /// description is the message itself, so they cannot be used on the whole-message path. This is the
    /// keyword half of the content check there (`looksLikeOneTimeCode` is the digit half), covering
    /// messages that discuss or contain a secret in words that have no code-shaped digits.
    /// Matching is case- and diacritic-insensitive and on whole words or phrases via
    /// `CredentialFieldDetector.containsWord`, so "pin" does not hit "spinning" or "pineapple" and a
    /// bare "code" ("the dress code") never hits.
    static func mentionsCredential(_ text: String) -> Bool {
        let haystack = folded(text)
        return credentialKeywords.contains { CredentialFieldDetector.containsWord($0, in: haystack) }
    }

    /// The single content check for a message the user did not select exactly: a one-time-code shape
    /// or a credential keyword. Either one refuses the automatic translation.
    static func isSensitiveMessage(_ text: String) -> Bool {
        looksLikeOneTimeCode(text) || mentionsCredential(text)
    }

    /// Lowercased with diacritics removed, so "Şifre" and "ŞİFRE" both become "sifre". Turkish dotless
    /// "ı" is a distinct letter that does not fold to "i"; the keyword list has no word that needs it.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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
