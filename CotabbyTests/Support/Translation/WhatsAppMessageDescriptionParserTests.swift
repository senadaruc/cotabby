import XCTest
@testable import Cotabby

/// File overview:
/// Tests for `WhatsAppMessageDescriptionParser`, which recovers a message body from the accessibility
/// sentence WhatsApp's Mac app puts in a bubble's `AXDescription`. Every string is invented; only the
/// shape copies what was measured live (field order, the ", " separator, the U+200E LEFT-TO-RIGHT MARK
/// that starts the prefix, the sender and every trailing status field, the four-line reply layout).
/// The English words are stand-ins: the parser never reads them, which is why the RTL case swaps the
/// marks and the words without changing the expected body.
final class WhatsAppMessageDescriptionParserTests: XCTestCase {
    /// U+200E LEFT-TO-RIGHT MARK, the field marker measured in WhatsApp's descriptions.
    private let lrm = "\u{200E}"
    /// U+200F RIGHT-TO-LEFT MARK, the marker an RTL interface would plausibly use instead.
    private let rlm = "\u{200F}"

    private func body(_ description: String) -> String? {
        WhatsAppMessageDescriptionParser.messageBody(fromDescription: description)
    }

    // MARK: - Measured shapes

    func test_plainIncomingGroupMessage_returnsBody() {
        let description = "\(lrm)Message from \(lrm)Anna Berg, Kommer du imorgon?, 24 November at 10:19, \(lrm)Received in Bokklubben"
        XCTAssertEqual(body(description), "Kommer du imorgon?")
    }

    func test_bodyContainingFieldSeparator_keepsWholeBody() {
        let description = "\(lrm)Message from \(lrm)Tom Lind, Ja, men först kaffe, sen jobb, 24 November at 10:19, \(lrm)Received in Teamet"
        XCTAssertEqual(body(description), "Ja, men först kaffe, sen jobb")
    }

    func test_shortBodyWithDigit_returnsBody() {
        let description = "\(lrm)Message from \(lrm)Tom Lind, 5 min, 24 November at 10:19, \(lrm)Received in Teamet"
        XCTAssertEqual(body(description), "5 min")
    }

    func test_replyBubble_returnsReplyBodyNotQuotedText() {
        let description = [
            "\(lrm)Replying to \(lrm)Anna Berg.",
            "\(lrm)Message from \(lrm)Tom Lind, Det låter bra!!, 24 November at 10:19, \(lrm)Received in Teamet.",
            "\(lrm)Quoted message.",
            "Kommer du imorgon?"
        ].joined(separator: "\n")
        XCTAssertEqual(body(description), "Det låter bra!!")
    }

    // MARK: - Guessed shapes (not yet sampled live)

    func test_outgoingMessageWithTwoTrailingMarkedFields_returnsBody() {
        let description = "\(lrm)Your message, Vi ses klockan åtta, 24 November at 10:21, \(lrm)Sent to Teamet, \(lrm)Read"
        XCTAssertEqual(body(description), "Vi ses klockan åtta")
    }

    func test_multiLineBody_keepsItsLines() {
        let description = "\(lrm)Message from \(lrm)Tom Lind, Första raden\nAndra raden, 24 November at 10:19, \(lrm)Received in Teamet"
        XCTAssertEqual(body(description), "Första raden\nAndra raden")
    }

    func test_rightToLeftMarks_areFieldMarkersToo() {
        let description = "\(rlm)Message from \(rlm)Tom Lind, Hej igen, 24 November at 10:19, \(rlm)Received in Teamet"
        XCTAssertEqual(body(description), "Hej igen")
    }

    func test_marksInsideBody_areRemoved() {
        let description = "\(lrm)Message from \(lrm)Tom Lind, Hej \(lrm)Anna\(lrm), 24 November at 10:19, \(lrm)Received in Teamet"
        XCTAssertEqual(body(description), "Hej Anna")
    }

    func test_lastFieldWithoutDigit_isKeptAsBody() {
        // A shape with no timestamp: the guard keeps the body instead of dropping its last field.
        let description = "\(lrm)Your message, Hej då, \(lrm)Sent to Teamet"
        XCTAssertEqual(body(description), "Hej då")
    }

    // MARK: - Unrecognised shapes yield nil

    func test_noMarks_returnsNil() {
        XCTAssertNil(body("Message from Tom Lind, Hej, 24 November at 10:19, Received in Teamet"))
    }

    func test_emptyBody_returnsNil() {
        XCTAssertNil(body("\(lrm)Message from \(lrm)Tom Lind, , 24 November at 10:19, \(lrm)Received in Teamet"))
    }

    func test_whitespaceOnlyBody_returnsNil() {
        XCTAssertNil(body("\(lrm)Message from \(lrm)Tom Lind,  \(lrm) , 24 November at 10:19, \(lrm)Received in Teamet"))
    }

    func test_prefixAndTailOnly_returnsNil() {
        XCTAssertNil(body("\(lrm)Message from \(lrm)Tom Lind, \(lrm)Received in Teamet"))
    }

    func test_prefixTimestampAndTail_returnsNil() {
        XCTAssertNil(body("\(lrm)Message from \(lrm)Tom Lind, 24 November at 10:19, \(lrm)Received in Teamet"))
    }

    func test_chatListRow_returnsNil() {
        // A chat-list row reads "<mark>Name, <unread count>": no marked field at its end.
        XCTAssertNil(body("\(lrm)Bokklubben, 3"))
    }

    func test_replyHeaderAndQuoteWithoutSentence_returnsNil() {
        XCTAssertNil(body("\(lrm)Replying to \(lrm)Anna Berg.\n\(lrm)Quoted message.\nKommer du imorgon?"))
    }

    func test_emptyDescription_returnsNil() {
        XCTAssertNil(body(""))
    }
}
