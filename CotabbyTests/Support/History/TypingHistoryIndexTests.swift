@testable import Cotabby
import XCTest

final class TypingHistoryIndexTests: XCTestCase {
    private func record(_ text: String, app: String = "com.microsoft.Outlook", domain: String? = nil) -> TypingHistoryRecord {
        TypingHistoryRecord(
            id: UUID(), bundleIdentifier: app, domain: domain,
            createdAt: Date(), updatedAt: Date(), text: text, source: .imported
        )
    }

    private func query(_ text: String, app: String = "com.microsoft.Outlook", domain: String? = nil, field: String = "") -> TypingHistoryQuery {
        TypingHistoryQuery(text: text, bundleIdentifier: app, domain: domain, currentFieldText: field)
    }

    func test_returnsThePassageThatSharesTheMostInformativeWords() {
        let index = TypingHistoryIndex(records: [
            record("The Imperum POC for the SOC team starts Monday. We will connect Microsoft Sentinel first."),
            record("Dinner tonight at eight? I can book the Italian place near the station if you like."),
            record("Our quarterly report covers revenue, hiring and the office move planned for spring.")
        ])

        let examples = index.examples(for: query("schedule the Imperum POC with Sentinel for the SOC"))

        XCTAssertEqual(examples.first?.contains("Sentinel"), true)
        XCTAssertFalse(examples.contains { $0.contains("Dinner") })
    }

    /// An email is written in email's register: text typed into a terminal (an assistant session,
    /// commands) must not be shown to the model as how the user writes mail.
    func test_anEmailTakesOnlyEarlierEmailAsItsExamples() {
        let index = TypingHistoryIndex(records: [
            record("The Imperum POC lookup in Outlook found nothing for the Sentinel connector inbox.", app: "com.mitchellh.ghostty"),
            record("Hi Arnaud, the Imperum POC with Sentinel is ready; the connector inbox is configured.")
        ])

        let examples = index.examples(for: query("Imperum POC Sentinel connector inbox"))

        XCTAssertEqual(examples.count, 1)
        XCTAssertEqual(examples.first?.hasPrefix("Hi Arnaud"), true)
        XCTAssertFalse(TypingHistoryIndex.mayExemplify(.terminal, for: .chat))
        XCTAssertTrue(TypingHistoryIndex.mayExemplify(.email, for: .chat))
    }

    func test_weakOverlapReturnsNothing() {
        let index = TypingHistoryIndex(records: [
            record("The Imperum POC for the SOC team starts Monday. We will connect Microsoft Sentinel first.")
        ])

        XCTAssertEqual(index.examples(for: query("the team")), [])
    }

    func test_anOlderSnapshotOfTheSameFieldIsSkipped() {
        let draft = "Hi Arnaud, the Imperum POC with Sentinel is ready for the SOC team to review this week."
        let index = TypingHistoryIndex(records: [record(draft)])

        XCTAssertEqual(index.examples(for: query("Imperum POC Sentinel SOC review", field: draft + " Let me")), [])
    }

    func test_passageIsBoundedAndKeepsWholeSentences() {
        let long = "Short opener here. " + String(repeating: "Filler words about nothing in particular. ", count: 20)
            + "The Imperum POC uses Sentinel connectors for SOC alerts. " + String(repeating: "More filler text follows. ", count: 20)
        let index = TypingHistoryIndex(records: [record(long)])

        let passage = index.examples(for: query("Imperum POC Sentinel connectors SOC alerts"), maxCharacters: 120).first

        XCTAssertNotNil(passage)
        XCTAssertLessThanOrEqual(passage?.count ?? .max, 120)
        XCTAssertEqual(passage?.contains("The Imperum POC uses Sentinel connectors for SOC alerts."), true)
    }

    func test_sameSiteWinsATie() {
        let index = TypingHistoryIndex(records: [
            record("Pipeline status for the Imperum connector build is green again today.", app: "com.google.Chrome", domain: "github.com"),
            record("Pipeline status for the Imperum connector build is green again today!", app: "com.google.Chrome", domain: "claude.ai")
        ])

        let examples = index.examples(for: query("Imperum connector pipeline build status", app: "com.google.Chrome", domain: "claude.ai"), limit: 1)

        XCTAssertEqual(examples, ["Pipeline status for the Imperum connector build is green again today!"])
    }

    /// After the first short block the query moves in larger steps, so long texts refresh their
    /// examples (and re-decode that prompt section) less often.
    func test_stableTextUsesLargerBlocksAfterTheFirst() {
        let words = (1...60).map { "w\($0)" }
        let text = { (count: Int) in words.prefix(count).joined(separator: " ") }
        XCTAssertEqual(TypingHistoryQuery.stableText(from: text(7)), "")
        XCTAssertEqual(TypingHistoryQuery.stableText(from: text(8)), text(8))
        XCTAssertEqual(TypingHistoryQuery.stableText(from: text(15)), text(8))
        XCTAssertEqual(TypingHistoryQuery.stableText(from: text(23)), text(16))
        XCTAssertEqual(TypingHistoryQuery.stableText(from: text(24)), text(24))
        XCTAssertEqual(TypingHistoryQuery.stableText(from: text(47)), text(24))
        XCTAssertEqual(TypingHistoryQuery.stableText(from: text(48)), text(48))
    }

    func test_stableTextOnlyChangesOnWholeWordBlocks() {
        XCTAssertEqual(TypingHistoryQuery.stableText(from: "one two three", wordsPerBlock: 4), "")
        XCTAssertEqual(TypingHistoryQuery.stableText(from: "a b c d e f", wordsPerBlock: 4), "a b c d")
        XCTAssertEqual(
            TypingHistoryQuery.stableText(from: "a b c d e f g", wordsPerBlock: 4),
            TypingHistoryQuery.stableText(from: "a b c d e f", wordsPerBlock: 4)
        )
    }
}
