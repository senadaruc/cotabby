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

    // MARK: - Recipient

    /// Outlook's quoted header when the user replies to someone else (measured 2026-10-11).
    private let replyToAndersonTail = """


    From: Anderson Lau <anderson.lau@imperum.io>
    Date: Sunday, 11 October 2026 at 12:35
    To: Senad Aruc <senad@imperum.io>; Dominique Meurisse <dme@imperum.io>
    Subject: Clarification required

    Hi Senad/Dominique,

    I have several questions/concerns that I'd like to have addressed.
    """

    func test_theRecipientIsTheQuotedMessagesSender() {
        XCTAssertEqual(MailReplyContext.replyRecipient(in: replyToAndersonTail, userName: "Senad"), "Anderson Lau")
        XCTAssertEqual(MailReplyContext.replyRecipient(in: replyToAndersonTail, userName: nil), "Anderson Lau")
        XCTAssertEqual(
            MailReplyContext.replyRecipient(in: "On 7 Oct 2026, at 16:14, Ayşe Yılmaz <a@x.com> wrote:\n> Hi", userName: "Senad"),
            "Ayşe Yılmaz"
        )
    }

    func test_noRecipientForTheUsersOwnMailABareAddressOrNoQuote() {
        // A follow-up to the user's own message goes to someone else; naming the user is the bug.
        XCTAssertNil(MailReplyContext.replyRecipient(in: outlookReplyTail, userName: "Senad"))
        XCTAssertNil(MailReplyContext.replyRecipient(in: outlookReplyTail, userName: "senad aruc"))
        XCTAssertNil(MailReplyContext.replyRecipient(in: "From: <a@x.com>\nSubject: Hi\n\nHello there", userName: nil))
        XCTAssertNil(MailReplyContext.replyRecipient(in: "the rest of my own paragraph", userName: "Senad"))
    }

    func test_anOutlookReplyPromptNamesWhoItIsAddressedTo() {
        let context = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.microsoft.Outlook", precedingText: "Dear ",
            trailingText: replyToAndersonTail, windowTitle: "Inbox • All Accounts"
        )
        let settings = CotabbyTestFixtures.settingsSnapshot(selectedEngine: .llamaOpenSource, userName: "Senad")
        let prompt = SuggestionRequestFactory.buildRequest(context: context, settings: settings, configuration: .standard)
            .request.prompt
        XCTAssertTrue(prompt.hasSuffix("\n\nTo: Anderson Lau\n\nDear "), prompt)

        // Outside mail the trailing text is the user's own paragraph, never an addressee.
        let notes = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.apple.TextEdit", precedingText: "Dear ", trailingText: replyToAndersonTail
        )
        XCTAssertFalse(SuggestionRequestFactory.buildRequest(context: notes, settings: settings, configuration: .standard)
            .request.prompt.contains("To: Anderson Lau"))
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

    /// Mail gets no memory scope from its window or its quoted original (both are the other
    /// person's to shape); the quoted subject still serves the prompt's reply context.
    func test_aMailReplyGetsNoMemoryScopeInlineOrInItsOwnWindow() {
        let sources = ["com.microsoft.Outlook": ["outlook"]]
        XCTAssertEqual(MailReplyContext.quotedSubject(in: outlookReplyTail), "Re: AFAD Use Case 3")
        XCTAssertNil(ConversationScopeResolver.scope(
            bundleIdentifier: "com.microsoft.Outlook", conversationTitle: "Inbox • All Accounts", sourcesByBundle: sources
        ))
        XCTAssertNil(ConversationScopeResolver.scope(
            bundleIdentifier: "com.microsoft.Outlook", conversationTitle: "Re: AFAD Use Case 3", sourcesByBundle: sources
        ))
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

    // MARK: - Condensed thread

    /// From a real reply: 1500 raw characters held two sentences of message among headers,
    /// addresses, signatures and a footer. The prompt gets who said what, and nothing else.
    func test_aQuotedThreadIsCondensedToWhoSaidWhat() {
        let tail = """


        From: Altay Seyfula <altay@imperum.io>
        Date: Wednesday, 7 October 2026 at 10:33
        To: Berker Pekel <berker.pekel@netsmart.com.tr>
        Cc: fatih.genc <fatih.genc@netsmart.com.tr>; Ali Pakkan <ali@imperum.io>
        Subject: Re: Imperum Lisans Süresi

        Tamamdır. Teşekkürler.\u{20}

        \u{20}
        ALTAY

        CO-FOUNDER, COO

         WhatsApp
        imperum.io | LinkedIn

        From: Berker Pekel <berker.pekel@netsmart.com.tr>
        Date: Wednesday, 7 October 2026 at 08:11
        To: Altay Seyfula <altay@imperum.io>
        Subject: YNT: Imperum Lisans Süresi

        Merhabalar,

        Eğitimin temel seviyesi olması yeterli olacaktır. Akabinde oluşan soruları ayrıca konuşuruz.

        Saygılarımla

        Berker Pekel
        Takım Lideri | Siber Güvenlik Çözümleri
        +90 538 012 94 40
        """
        XCTAssertEqual(
            MailReplyContext.condensedThread(tail),
            "Altay Seyfula: Tamamdır. Teşekkürler.\n\n"
                + "Berker Pekel: Merhabalar, Eğitimin temel seviyesi olması yeterli olacaktır. Akabinde oluşan soruları ayrıca konuşuruz."
        )
    }

    func test_textWithoutAQuoteIsLeftAsItIs() {
        XCTAssertEqual(MailReplyContext.condensedThread("the rest of my paragraph"), "the rest of my paragraph")
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
