import XCTest
@testable import Cotabby

/// The rewrite names the draft's language because Apple's model otherwise drifts into English:
/// "selam beraber cigar iceriz wihiskey" came back as "hey let's smoke cigars with whiskey"
/// (2026-10-10). Detection is limited to the languages the user writes in, because unconstrained
/// recognition called that draft Indonesian.
final class RewriteLanguageDetectorTests: XCTestCase {
    private let languages = ["English", "Turkish"]

    func test_turkishDraftWithEnglishLoanwordsIsTurkish() {
        XCTAssertEqual(RewriteLanguageDetector.language(of: "selam beraber cigar iceriz wihiskey", among: languages), "Turkish")
    }

    func test_englishDraftIsEnglish() {
        XCTAssertEqual(RewriteLanguageDetector.language(of: "Please let me know if te dates are ok and wors for you.", among: languages), "English")
    }

    func test_freeTextLanguageNamesAreUnderstood() {
        // "Turkish" is not in the built-in palette; the system's English language names resolve it.
        XCTAssertEqual(RewriteLanguageDetector.code(forLanguageName: "Turkish"), "tr")
        XCTAssertEqual(RewriteLanguageDetector.code(forLanguageName: "german"), "de")
        XCTAssertNil(RewriteLanguageDetector.code(forLanguageName: "Klingonish"))
    }

    func test_languageOutsideTheUsersSetIsNotNamed() {
        // Only English declared: a German draft is not forced to "English", and not guessed either.
        XCTAssertNil(RewriteLanguageDetector.language(of: "Können wir uns morgen um zehn Uhr treffen?", among: ["English"]))
    }

    func test_withoutDeclaredLanguagesAConfidentGuessIsNamed() {
        XCTAssertEqual(RewriteLanguageDetector.language(of: "Können wir uns morgen um zehn Uhr im Büro treffen?", among: []), "German")
    }
}
