import XCTest
@testable import Cotabby

/// Models wrap answers in prefaces, quotes and code fences; the cleaner strips those and refuses
/// output that cannot be a rewrite of the selection.
final class RewriteOutputCleanerTests: XCTestCase {
    private let draft = "Please let me know if te dates are ok and wors for you."

    func test_plainOutputPassesThrough() {
        XCTAssertEqual(
            RewriteOutputCleaner.clean("Please let me know if the dates work for you.", selection: draft, action: .fixOnly),
            "Please let me know if the dates work for you."
        )
    }

    func test_prefaceAndQuotesAreStripped() {
        XCTAssertEqual(
            RewriteOutputCleaner.clean("Here is the rewritten text:\n\n\"Please let me know if the dates work.\"", selection: draft, action: .rewrite),
            "Please let me know if the dates work."
        )
        XCTAssertEqual(
            RewriteOutputCleaner.clean("Sure! Here's a friendlier version: Let me know if those dates work!", selection: draft, action: .friendly),
            "Let me know if those dates work!"
        )
    }

    func test_codeFenceIsStripped() {
        XCTAssertEqual(
            RewriteOutputCleaner.clean("```\nPlease let me know.\n```", selection: draft, action: .rewrite),
            "Please let me know."
        )
    }

    func test_selectionTrailingWhitespaceIsKept() {
        XCTAssertEqual(
            RewriteOutputCleaner.clean("Best regards,", selection: "Best regard, \n", action: .fixOnly),
            "Best regards, \n"
        )
    }

    func test_emptyAndRunawayOutputIsRejected() {
        XCTAssertNil(RewriteOutputCleaner.clean("   \n", selection: draft, action: .rewrite))
        XCTAssertNil(RewriteOutputCleaner.clean(String(repeating: "a ", count: draft.count * 2), selection: draft, action: .rewrite))
    }

    func test_shorterMayNotGrow() {
        XCTAssertNil(RewriteOutputCleaner.clean(draft + " And some more words.", selection: draft, action: .shorter))
    }

    func test_userOpeningLikeAPrefaceIsKept() {
        XCTAssertEqual(
            RewriteOutputCleaner.clean("Here is my address: Main Street 1", selection: "Here is my adress: Main Street 1", action: .fixOnly),
            "Here is my address: Main Street 1"
        )
    }

    func test_quotesThatBelongToTheSelectionStay() {
        let quoted = "\"Sounds good\" he said, let us meet."
        XCTAssertEqual(
            RewriteOutputCleaner.clean("\"Sounds good,\" he said. Let us meet.", selection: quoted, action: .fixOnly),
            "\"Sounds good,\" he said. Let us meet."
        )
    }

    func test_longerMayGrowWellBeyondTheDraft() {
        let draft = "can we meet tomorrow"
        let longer = "Hi Richard, I hope you are well. Could we meet tomorrow to go over the POC results and the next steps? Let me know what time suits you best."
        XCTAssertEqual(RewriteOutputCleaner.clean(longer, selection: draft, action: .longer), longer)
    }
    func test_translationMayGrowWellBeyondTheRewriteLimit() {
        let output = "Thank you very much for your help with everything today, friend."
        XCTAssertEqual(
            RewriteOutputCleaner.clean(output, selection: "谢谢", action: .translate(into: "English")),
            output
        )
        XCTAssertNil(RewriteOutputCleaner.clean(output, selection: "谢谢", action: .rewrite))
    }

    func test_translationPrefacesAreStripped() {
        let action = RewriteAction.translate(into: "English")
        let cases = [
            "Translation: Hello there.",
            "Here is the translation:\nHello there.",
            "Translated text: Hello there."
        ]
        for output in cases {
            XCTAssertEqual(RewriteOutputCleaner.clean(output, selection: "Hallo daar.", action: action), "Hello there.", output)
        }
    }

    func test_translationKeepsSentenceLikeOpeningsThatAreRealText() {
        let action = RewriteAction.translate(into: "English")
        for output in ["Here is the link: https://example.com", "Here's what happened: the server crashed."] {
            XCTAssertEqual(RewriteOutputCleaner.clean(output, selection: "Hier ist der Link.", action: action), output, output)
        }
        // Tradeoff: a one-line preface is indistinguishable from a translated sentence that happens to
        // start that way, so it stays.
        let oneLine = "Here is the translation: Hello there."
        XCTAssertEqual(RewriteOutputCleaner.clean(oneLine, selection: "Hallo daar.", action: action), oneLine)
    }
}
