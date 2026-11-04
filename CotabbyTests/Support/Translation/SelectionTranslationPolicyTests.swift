import CoreGraphics
import XCTest
@testable import Cotabby

/// File overview:
/// Tests for `SelectionTranslationPolicy`, the gate that decides whether a selection on screen is
/// translated. The language cases use real sentences because `NLLanguageRecognizer` is the thing being
/// exercised; the URL case pins only the deterministic eligibility rules, since the recognizer's guess
/// for a bare link is not something to assert on.
final class SelectionTranslationPolicyTests: XCTestCase {
    private let ownBundle = "com.cotabby.app"

    private func capture(_ text: String, bundle: String = "com.apple.mail", secure: Bool = false) -> SelectedTextCapture {
        SelectedTextCapture(
            text: text,
            rect: nil,
            lineRect: nil,
            bundleIdentifier: bundle,
            processIdentifier: 1,
            isSecure: secure,
            source: .selectedText
        )
    }

    private func verdict(
        _ text: String,
        target: String = "en",
        trigger: SelectionTranslationTrigger = .automatic,
        bundle: String = "com.apple.mail",
        secure: Bool = false
    ) -> SelectionTranslationPolicy.Verdict {
        SelectionTranslationPolicy.verdict(
            for: capture(text, bundle: bundle, secure: secure),
            targetLanguage: target,
            trigger: trigger,
            ownBundleIdentifier: ownBundle
        )
    }

    // MARK: - Language

    func test_dutchSentenceTranslatesIntoEnglish() {
        XCTAssertEqual(
            verdict("Tracy staat 24/7 voor je klaar om je te helpen met eventuele vragen."),
            .translate(sourceCode: "nl")
        )
    }

    func test_englishSentenceIsLeftAloneForEnglishTarget() {
        XCTAssertEqual(
            verdict("Thanks for your message, I will reply tomorrow."),
            .sameLanguage
        )
    }

    func test_englishSentenceTranslatesIntoDutch() {
        XCTAssertEqual(
            verdict("Thanks for your message, I will reply tomorrow.", target: "nl"),
            .translate(sourceCode: "en")
        )
    }

    /// Too short for the strict detector, so this exercises the loose single-phrase guess.
    func test_shortEnglishPhraseUsesLooseGuessAndIsLeftAlone() {
        XCTAssertEqual(verdict("Thanks a lot"), .sameLanguage)
    }

    // MARK: - Size limits

    func test_tooFewLettersIsTooShort() {
        XCTAssertEqual(verdict("ok"), .tooShort)
    }

    func test_digitsOnlyIsTooShort() {
        XCTAssertEqual(verdict("12345 67890"), .tooShort)
    }

    func test_textOverTheCharacterLimitIsTooLong() {
        let text = String(repeating: "a ", count: 1_000) + "a"
        XCTAssertEqual(text.count, 2_001)
        XCTAssertEqual(verdict(text), .tooLong)
    }

    // MARK: - Eligibility

    func test_passwordManagersAreIneligible() {
        for bundle in ["com.apple.Passwords", "com.bitwarden.desktop"] {
            XCTAssertEqual(
                verdict("Thanks for your message, I will reply tomorrow.", target: "nl", bundle: bundle),
                .ineligible, bundle
            )
        }
    }

    func test_secureFieldIsIneligible() {
        XCTAssertEqual(
            verdict("Thanks for your message, I will reply tomorrow.", target: "nl", secure: true),
            .ineligible
        )
    }

    func test_terminalIsIneligible() {
        XCTAssertEqual(
            verdict("Thanks for your message, I will reply tomorrow.", target: "nl", bundle: "com.apple.Terminal"),
            .ineligible
        )
    }

    func test_cotabbyItselfIsIneligible() {
        XCTAssertEqual(
            verdict("Thanks for your message, I will reply tomorrow.", target: "nl", bundle: ownBundle),
            .ineligible
        )
    }

    /// "abc" has enough letters to pass the size floor, but neither detector can answer for three
    /// letters, so the verdict depends only on the trigger: the automatic path stays quiet while the
    /// shortcut, an explicit request, translates with no source language named.
    func test_undetectedTextIsSkippedAutomaticallyButTranslatedByTheShortcut() {
        XCTAssertEqual(verdict("abc", target: "nl", trigger: .automatic), .undetected)
        XCTAssertEqual(verdict("abc", target: "nl", trigger: .shortcut), .translate(sourceCode: nil))
    }

    // MARK: - Names and echoes

    func test_englishNameForLanguageCodes() {
        XCTAssertEqual(SelectionTranslationPolicy.englishName(forLanguageCode: "nl"), "Dutch")
        XCTAssertEqual(SelectionTranslationPolicy.englishName(forLanguageCode: "tr"), "Turkish")
        XCTAssertEqual(SelectionTranslationPolicy.englishName(forLanguageCode: "mk"), "Macedonian")
        XCTAssertEqual(SelectionTranslationPolicy.englishName(forLanguageCode: "en-US"), "English")
    }

    func test_unknownLanguageCodeIsReturnedAsIs() {
        XCTAssertEqual(SelectionTranslationPolicy.englishName(forLanguageCode: "zz"), "zz")
    }

    func test_echoIgnoresSurroundingWhitespaceAndCase() {
        XCTAssertTrue(SelectionTranslationPolicy.isEcho(output: " Hello ", input: "hello"))
    }

    func test_differentTextIsNotAnEcho() {
        XCTAssertFalse(SelectionTranslationPolicy.isEcho(output: "Hallo", input: "Hello"))
    }
}
