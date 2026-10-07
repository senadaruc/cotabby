import XCTest
@testable import Cotabby

final class ScreenTextChangePolicyTests: XCTestCase {
    private let inbox = """
    Inbox Focused Other
    Arnaud Reichenauer Re: Deployment status 18:30 Thanks, I will finish the rollout today
    Akram Customer POC 18:28 The connector is polling again since this morning
    Ayşe Invoice 17:57 The invoice is paid, please confirm the receipt
    Hello Arnaud, Can
    From: Senad Aruc Date: Wednesday, 7 October 2026 at 16:15
    """

    func test_firstExcerptIsAChange() {
        XCTAssertTrue(ScreenTextChangePolicy.isMeaningfulChange(from: nil, to: inbox))
    }

    func test_identicalTextIsNotAChange() {
        XCTAssertFalse(ScreenTextChangePolicy.isMeaningfulChange(from: inbox, to: inbox))
    }

    func test_ocrJitterOnTheSameWindowIsNotAChange() {
        // What consecutive passes over an unchanged Outlook window looked like: a misread glyph,
        // a caret read as a bar, a word split differently.
        let reread = inbox
            .replacingOccurrences(of: "18:28", with: "18.28")
            .replacingOccurrences(of: "Can", with: "Can |")
            .replacingOccurrences(of: "this morning", with: "thismorning")
        XCTAssertFalse(ScreenTextChangePolicy.isMeaningfulChange(from: inbox, to: reread))
    }

    func test_switchingToAnotherConversationIsAChange() {
        // Same window chrome, different conversation: the navigation signal must survive.
        let otherChat = """
        Inbox Focused Other
        Jacob Fu Upstream review 12:02 I left comments on the overlay PR and the scheduler change
        Jacob Fu Upstream review 12:05 Can you split the memory work into smaller pull requests
        Jacob Fu Upstream review 12:09 Also rebase onto main before Friday please
        """
        XCTAssertTrue(ScreenTextChangePolicy.isMeaningfulChange(from: inbox, to: otherChat))
    }

    func test_emptyExcerptsAreTheSameScreen() {
        XCTAssertEqual(ScreenTextChangePolicy.similarity("", "  "), 1)
    }
}
