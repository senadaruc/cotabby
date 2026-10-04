import Foundation
import XCTest
@testable import Cotabby

/// Pins the pure rules of drafting answers from memory: what counts as a question (English and
/// Turkish), when a reply field is still empty, how a mail reply's quoted original is read, how the
/// prompt is shaped, and when a draft is supported by the facts it came from.
final class AnswerRulesTests: XCTestCase {
    // MARK: - Questions

    func test_englishQuestionsAreDetectedAndStatementsAreNot() {
        XCTAssertEqual(QuestionDetector.question(in: "Hi Senad! How did the THY POC go?"), "How did the THY POC go?")
        XCTAssertEqual(QuestionDetector.question(in: "can you send me the pricing"), "can you send me the pricing")
        XCTAssertNotNil(QuestionDetector.question(in: "Please confirm the meeting time for Thursday."))
        XCTAssertNotNil(QuestionDetector.question(in: "Any update on the SIEM integration"))
        XCTAssertNil(QuestionDetector.question(in: "Thanks, see you tomorrow."))
        XCTAssertNil(QuestionDetector.question(in: "Can is joining the call."), "Can is a name, not a question")
        XCTAssertNil(QuestionDetector.question(in: "ok"))
    }

    func test_turkishQuestionsAreDetected() {
        XCTAssertNotNil(QuestionDetector.question(in: "Toplantı yarın mı"))
        XCTAssertNotNil(QuestionDetector.question(in: "Fiyat teklifini gönderebilir misin"))
        XCTAssertNotNil(QuestionDetector.question(in: "POC ne zaman bitiyor"))
        XCTAssertNotNil(QuestionDetector.question(in: "Kaç kullanıcı için lisans lazım?"))
        XCTAssertNil(QuestionDetector.question(in: "Teşekkürler, yarın görüşürüz."))
        XCTAssertNil(QuestionDetector.question(in: "Mimari çizimi ekte bulabilirsiniz."), "'mi' inside a word is no particle")
    }

    func test_onlyTheLatestTwoAskingSentencesAreKept() {
        let message = "Hi! Is the demo ready? Who joins from your side? What time works best?"
        XCTAssertEqual(QuestionDetector.question(in: message), "Who joins from your side? What time works best?")
    }

    // MARK: - Empty reply field

    func test_aReplyIsEmptyWithOnlyASignatureAndTheQuoteAfterTheCaret() {
        XCTAssertTrue(ReplyFieldEmptiness.isEmpty(precedingText: "", trailingText: "  \n"))
        let mailReply = "\n\nSenad Aruc\nImperum\n\nOn Mon, 3 Oct 2026 at 10:15, Ayşe Yılmaz <ayse@x.com> wrote:\n> Is the demo ready?"
        XCTAssertTrue(ReplyFieldEmptiness.isEmpty(precedingText: "", trailingText: mailReply))
        XCTAssertFalse(ReplyFieldEmptiness.isEmpty(precedingText: "Hi Ayşe,", trailingText: mailReply))
        XCTAssertFalse(ReplyFieldEmptiness.isEmpty(precedingText: "", trailingText: "a draft I started writing earlier"))
    }

    // MARK: - Quoted replies

    func test_englishAttributionGivesSenderAndOnlyTheLatestQuotedBody() throws {
        let text = """

        Senad

        On Mon, 3 Oct 2026 at 10:15, Ayşe Yılmaz <ayse@x.com> wrote:
        > How did the THY POC go?
        > Thanks

        On Sun, 2 Oct 2026, Senad Aruc wrote:
        > older text
        """
        let quoted = try XCTUnwrap(QuotedReplyParser.quotedMessage(in: text))
        XCTAssertEqual(quoted.sender, "Ayşe Yılmaz")
        XCTAssertEqual(quoted.body, "How did the THY POC go?\nThanks")
    }

    func test_turkishAttributionAndOutlookBlocksAreRead() throws {
        let turkish = "3 Eki 2026 tarihinde Ali Pakkan şunu yazdı:\n> Teklif ne durumda?"
        XCTAssertEqual(QuotedReplyParser.quotedMessage(in: turkish), .init(sender: "Ali Pakkan", body: "Teklif ne durumda?"))

        let outlook = """
        From: Dominique Meurisse <dme@imperum.io>
        Sent: Monday, October 3, 2026 10:15
        To: Senad Aruc <senad@imperum.io>
        Subject: Client and POC Status

        Can you share the POC numbers before Friday?
        """
        let quoted = try XCTUnwrap(QuotedReplyParser.quotedMessage(in: outlook))
        XCTAssertEqual(quoted.sender, "Dominique Meurisse")
        XCTAssertEqual(quoted.body, "Can you share the POC numbers before Friday?")
    }

    // MARK: - Prompt and output

    func test_basePromptEndsWithTheUsersTurnAndOutputIsCutAtTheNextSpeaker() {
        let fact = AnswerPromptRenderer.Fact(sender: "Irem Dogru", isFromMe: false, conversationTitle: "THY - Imperum",
                                             timestamp: Date(timeIntervalSince1970: 1_746_900_000), text: "The POC passed all detection tests.")
        let prompt = AnswerPromptRenderer.basePrompt(question: "How did the POC go?", asker: "Ali Pakkan", facts: [fact])
        XCTAssertTrue(prompt.hasSuffix("Ali Pakkan: How did the POC go?\nYou:"))
        XCTAssertTrue(prompt.contains("Irem Dogru (THY - Imperum): The POC passed all detection tests."))
        XCTAssertEqual(
            AnswerPromptRenderer.cleanedAnswer(" It passed all detection tests.\nAli Pakkan: great", asker: "Ali Pakkan"),
            "It passed all detection tests."
        )
        XCTAssertNil(AnswerPromptRenderer.cleanedAnswer("NONE", asker: nil))
        XCTAssertNil(AnswerPromptRenderer.cleanedAnswer("   ", asker: nil))
    }

    // MARK: - Grounding

    func test_draftsMustNotInventNumbersOrNames() {
        let facts = ["The SOC platform costs 4.000 EUR per month for Turkish Airlines.", "Irem confirmed the pilot."]
        XCTAssertEqual(AnswerGroundingPolicy.unsupportedSpecifics(
            in: "It is 4000 EUR per month, Irem confirmed.", facts: facts, question: "What does it cost?"), [])
        XCTAssertEqual(AnswerGroundingPolicy.unsupportedSpecifics(
            in: "It is 5000 EUR per month.", facts: facts, question: "What does it cost?"), ["5000"])
        XCTAssertEqual(AnswerGroundingPolicy.unsupportedSpecifics(
            in: "Ask Mehmet about it.", facts: facts, question: "Who handles it?"), ["Mehmet"])
        XCTAssertEqual(AnswerGroundingPolicy.unsupportedSpecifics(
            in: "Yes, we meet at Karaköy'de office.", facts: ["Yarın Karaköy'de buluşalım."], question: "Nerede?"), [])
    }

    func test_draftingNeedsARelevantFactOrAnExactKeywordMatch() {
        XCTAssertTrue(AnswerGroundingPolicy.shouldDraft(bestSimilarity: 0.6, minimumSimilarity: 0.45, hasKeywordMatch: false))
        XCTAssertTrue(AnswerGroundingPolicy.shouldDraft(bestSimilarity: 0.2, minimumSimilarity: 0.45, hasKeywordMatch: true))
        XCTAssertFalse(AnswerGroundingPolicy.shouldDraft(bestSimilarity: 0.2, minimumSimilarity: 0.45, hasKeywordMatch: false))
    }

    // MARK: - Incoming messages

    private func message(_ id: String, _ text: String, fromMe: Bool = false, at minute: Double) -> MemoryStore.StoredMessage {
        MemoryStore.StoredMessage(recordID: id, source: "whatsapp", conversationID: "c", conversationKey: "k",
                                  sender: fromMe ? "" : "Ali", isFromMe: fromMe, timestamp: 1_790_000_000 + minute * 60,
                                  subject: nil, text: text)
    }

    func test_theLatestIncomingBurstIsTakenTogetherAndNothingAfterTheUsersReply() throws {
        let conversation = MemoryConversation(source: "whatsapp", conversationId: "c", title: "Ali", participants: ["ali"], lastTimestamp: 0)
        let latest = [
            message("3", "How did the POC go?", at: 12),
            message("2", "Hi!", at: 11),
            message("1", "See you", fromMe: true, at: 5),
        ]
        let incoming = try XCTUnwrap(IncomingMessageResolver.incomingRun(latest, conversation: conversation))
        XCTAssertEqual(incoming.text, "Hi!\nHow did the POC go?")
        XCTAssertEqual(incoming.recordIDs, ["2", "3"])
        XCTAssertEqual(incoming.sender, "Ali")

        let replied = [message("4", "It went well", fromMe: true, at: 13)] + latest
        XCTAssertNil(IncomingMessageResolver.incomingRun(replied, conversation: conversation), "already answered")

        let stale = [message("6", "Is the report ready?", at: 200), message("5", "Old question?", at: 10)]
        XCTAssertEqual(IncomingMessageResolver.incomingRun(stale, conversation: conversation)?.text, "Is the report ready?",
                       "a message from hours earlier belongs to another exchange")
    }
}
