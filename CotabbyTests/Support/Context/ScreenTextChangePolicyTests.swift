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

    func test_typingIntoAFieldThatFillsTheWindowIsNotAChange() {
        // A TextEdit document or a compose window: the draft is most of the excerpt, so a few new
        // words move the raw similarity under the threshold. They are the user's own text, not a
        // new screen, and retiring the suggestion for them hid ghost text mid-sentence.
        let chrome = "Untitled 3 — Edited\nHelvetica Regular 12 B I U S"
        let before = chrome + "\nHello Martin, thanks for the update on the"
        let after = chrome + "\nHello Martin, thanks for the update on the onboarding project. I wanted to che"
        let field = "Hello Martin, thanks for the update on the onboarding project. I wanted to check"
        XCTAssertFalse(ScreenTextChangePolicy.isMeaningfulChange(from: before, to: after, fieldText: field))
    }

    func test_ocrJitterOnAShortToolbarExcerptIsNotAChange() {
        // Consecutive readings of one TextEdit window while typing: the excerpt is only the title
        // bar and toolbar, so one split or stray glyph moves the word similarity under the
        // threshold. Each of these retired the visible suggestion every few seconds.
        let readings = [
            "Untitled 4 Edited\nBIUS\nHelvetica\nRegular c\n12\n10\n14\n16\n20",
            "Untitled 4 Edited\nBI US\nHelvetica\nRegular c\n12\n6\n10\n14\n16\n20",
            "Untitled 4 Edited\nHelvetica\nRegular\n12\nV\n10\n14\n16\n20",
            "Untitled 4 Edited\nHelvetica\nRegular\n12\n1 0\n6\n8\n10\n114\n16\n18\n20",
        ]
        for previous in readings {
            for current in readings where current != previous {
                XCTAssertFalse(
                    ScreenTextChangePolicy.isMeaningfulChange(from: previous, to: current, fieldText: "Hello Martin"),
                    "\(previous.debugDescription) -> \(current.debugDescription)"
                )
            }
        }
    }

    func test_switchingToAnotherConversationIsAChangeWhileTyping() {
        // Ignoring the draft must not hide navigation: the other chat's words are not in the field.
        let otherChat = """
        Inbox Focused Other
        Jacob Fu Upstream review 12:02 I left comments on the overlay PR and the scheduler change
        Jacob Fu Upstream review 12:05 Can you split the memory work into smaller pull requests
        Jacob Fu Upstream review 12:09 Also rebase onto main before Friday please
        Hello Arnaud, Can
        """
        let field = "Hello Arnaud, Can you confirm the rollout finished"
        XCTAssertTrue(ScreenTextChangePolicy.isMeaningfulChange(from: inbox, to: otherChat, fieldText: field))
    }

    func test_emptyExcerptsAreTheSameScreen() {
        XCTAssertEqual(ScreenTextChangePolicy.similarity("", "  "), 1)
    }
}
