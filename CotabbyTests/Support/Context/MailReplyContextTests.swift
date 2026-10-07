import XCTest
@testable import Cotabby

/// Pins what a mail reply contributes to a suggestion: the quoted thread after the caret, its
/// subject as the conversation's name, and screen text from the compose column only.
final class MailReplyContextTests: XCTestCase {
    /// What Outlook's inline reply exposes after the caret: the quoted header, then the message.
    private let outlookReplyTail = """


    From: Senad Aruc <senad@imperum.io>
    Date: Wednesday, 7 October 2026 at 16:14
    To: Malaya Panda <malaya.panda@imperum.io>; Arnaud Reichenauer <arnaud.reichenauer@imperum.io>
    Cc: Jayesh Kammili <jayesh.kammili@imperum.io>
    Subject: Re: AFAD Use Case 3

    Since imperum forensics agent can detect the USB devices..
    """

    // MARK: - Subject

    func test_readsTheSubjectFromOutlooksQuotedHeader() {
        XCTAssertEqual(MailReplyContext.quotedSubject(in: outlookReplyTail), "Re: AFAD Use Case 3")
        XCTAssertEqual(QuotedReplyParser.quotedSubject(in: "Kimden: Ali\nKonu: Teklif\n\nNe durumda?"), "Teklif")
    }

    func test_noSubjectWithoutAQuotedHeader() {
        XCTAssertNil(MailReplyContext.quotedSubject(in: ""))
        XCTAssertNil(MailReplyContext.quotedSubject(in: "the rest of my own paragraph"))
        // Mail's attribution quote names no subject; its compose window title already does.
        XCTAssertNil(MailReplyContext.quotedSubject(in: "On 7 Oct 2026, at 16:14, Ayşe wrote:\n> Hi"))
    }

    func test_aSubjectLineAfterTheHeaderBlockIsNotTheThreadsSubject() {
        let tail = "From: Ayşe <a@x.com>\nTo: Senad\n\nSubject: this line is part of her message"
        XCTAssertNil(MailReplyContext.quotedSubject(in: tail))
    }

    // MARK: - Budgets and titles

    func test_mailAppsCarryTheQuotedThreadOtherAppsKeepTheDefault() {
        XCTAssertEqual(MailReplyContext.trailingBudget(bundleIdentifier: "com.microsoft.Outlook", defaultBudget: 192), 1500)
        XCTAssertEqual(MailReplyContext.trailingBudget(bundleIdentifier: "com.apple.mail", defaultBudget: 192), 1500)
        XCTAssertEqual(MailReplyContext.trailingBudget(bundleIdentifier: "com.apple.TextEdit", defaultBudget: 192), 192)
    }

    func test_outlooksFolderWindowTitlesAreMailboxesNotConversations() {
        XCTAssertTrue(MailReplyContext.isMailboxWindowTitle("Inbox • All Accounts", bundleIdentifier: "com.microsoft.Outlook"))
        XCTAssertFalse(MailReplyContext.isMailboxWindowTitle("Re: AFAD Use Case 3", bundleIdentifier: "com.microsoft.Outlook"))
        XCTAssertFalse(MailReplyContext.isMailboxWindowTitle("Inbox • All Accounts", bundleIdentifier: "com.apple.mail"))
    }

    // MARK: - Memory scope

    func test_anInlineOutlookReplyFindsItsThreadByTheQuotedSubject() {
        let sources = ["com.microsoft.Outlook": ["outlook"]]
        XCTAssertEqual(
            ConversationScopeResolver.scope(
                bundleIdentifier: "com.microsoft.Outlook", conversationTitle: "Inbox • All Accounts",
                trailingText: outlookReplyTail, sourcesByBundle: sources
            ),
            ConversationScope(title: "Re: AFAD Use Case 3", sources: ["outlook"])
        )
        // Without a quote the mailbox title names no conversation, so memory stays out.
        XCTAssertNil(ConversationScopeResolver.scope(
            bundleIdentifier: "com.microsoft.Outlook", conversationTitle: "Inbox • All Accounts",
            trailingText: "", sourcesByBundle: sources
        ))
        // A reply in its own window keeps working through the window title.
        XCTAssertEqual(
            ConversationScopeResolver.scope(
                bundleIdentifier: "com.microsoft.Outlook", conversationTitle: "Re: AFAD Use Case 3", sourcesByBundle: sources
            ),
            ConversationScope(title: "Re: AFAD Use Case 3", sources: ["outlook"])
        )
    }

    // MARK: - Request

    func test_anOutlookReplyPromptCarriesTheThreadAndItsSubject() {
        let context = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.microsoft.Outlook", precedingText: "Dear M",
            trailingText: outlookReplyTail, windowTitle: "Inbox • All Accounts"
        )
        let request = SuggestionRequestFactory.buildRequest(
            context: context, settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .llamaOpenSource),
            configuration: .standard
        ).request
        XCTAssertTrue(request.prompt.contains("Since imperum forensics agent can detect the USB devices"))
        XCTAssertTrue(request.prompt.contains("Re: AFAD Use Case 3"))
        XCTAssertFalse(request.prompt.contains("Inbox • All Accounts"))
        XCTAssertTrue(request.prompt.hasSuffix("Dear M"))
    }

    // MARK: - Screen text

    func test_mailScreenTextKeepsTheComposeColumnAndDropsTheMessageList() {
        let focus = CGRect(x: 0.4, y: 0.4, width: 0.55, height: 0.3)
        let lines = [
            OCRTextHygiene.OCRLine(text: "Subject Re AFAD Use Case 3", confidence: 1,
                                   boundingBox: CGRect(x: 0.42, y: 0.8, width: 0.3, height: 0.03)),
            OCRTextHygiene.OCRLine(text: "Dear Massimo and Alberto As agreed during our call", confidence: 1,
                                   boundingBox: CGRect(x: 0.05, y: 0.75, width: 0.3, height: 0.03))
        ]
        let mail = VisualContextExcerptSelector.select(
            lines: lines, fieldText: "", focusBounds: focus, maxCharacters: 4000, keepsOnlyFieldColumn: true
        )
        XCTAssertEqual(mail, "Subject Re AFAD Use Case 3")
        let other = VisualContextExcerptSelector.select(lines: lines, fieldText: "", focusBounds: focus, maxCharacters: 4000)
        XCTAssertTrue(other.contains("Massimo"), "Other apps keep neighbouring columns")
    }
}
