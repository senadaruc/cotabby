import Foundation
import XCTest
@testable import Cotabby

/// Pins the rules that turn Teams' cached rows into memory messages: titles, participants (with the
/// group marker that keeps groups from sharing a 1:1's memory), which messages are kept, the cursor,
/// sender names and the HTML-to-text conversion. The fixtures are plain dictionaries shaped like
/// Teams' IndexedDB values, and the cases are those of the Python service's `test_teams.py`, which
/// these rules were ported from.
final class TeamsMessageMapperTests: XCTestCase {
    private let me = "8:orgid:aaaaaaaa-0000-0000-0000-000000000001"
    private let ali = "8:orgid:bbbbbbbb-0000-0000-0000-000000000002"
    private let valon = "8:orgid:cccccccc-0000-0000-0000-000000000003"
    private let oneToOne = "19:aaaaaaaa-0000-0000-0000-000000000001_bbbbbbbb-0000-0000-0000-000000000002@unq.gbl.spaces"
    private let group = "19:group0001@thread.v2"
    private let meeting = "19:meeting_abc@thread.v2"
    /// Teams arrival times are epoch milliseconds.
    private let t0: Double = 1_790_000_000_000

    private func message(
        _ conversation: String, _ creator: String, _ name: String, _ content: String, at milliseconds: Double,
        kind: String = "RichText/Html", id: String? = nil, deleted: Bool = false
    ) -> [String: Any] {
        [
            "id": id ?? String(Int64(milliseconds)), "conversationId": conversation, "creator": creator,
            "imDisplayName": name, "content": content, "messageType": kind, "originalArrivalTime": milliseconds,
            "deletionInfo": deleted ? ["deletedTime": 1] as [String: Any] : NSNull()
        ]
    }

    private func fixture() -> (conversations: [[String: Any]], messages: [[String: Any]], profiles: [String: String]) {
        let conversations: [[String: Any]] = [
            ["id": oneToOne, "type": "Chat", "members": [["id": me], ["id": ali]],
             "chatTitle": ["longTitle": "Ali Pakkan, Senad Aruc"]],
            // Teams' cached title names this group after one member; its members list is partial.
            ["id": group, "type": "Chat", "members": [["id": me], ["id": ali]],
             "chatTitle": ["longTitle": "Ali Pakkan, Senad Aruc"]],
            ["id": meeting, "type": "Meeting", "threadProperties": ["topic": "POC Planning"],
             "members": [["id": me], ["id": ali], ["id": valon]]]
        ]
        let messages: [[String: Any]] = [
            message(oneToOne, ali, "Ali Pakkan", "<p>The <b>POC</b> passed&nbsp;today</p>", at: t0 + 1_000),
            message(oneToOne, me, "Senad Aruc",
                    "<p>Great news</p><blockquote itemtype=\"http://schema.skype.com/Reply\">The POC passed today</blockquote>",
                    at: t0 + 2_000),
            message(group, valon, "Valon Dauti", "Budget is approved", at: t0 + 3_000, kind: "Text"),
            message(group, me, "Senad Aruc", "Thanks Valon", at: t0 + 4_000),
            message(meeting, me, "Senad Aruc", "Agenda is in the invite", at: t0 + 5_000),
            message(oneToOne, ali, "Ali Pakkan", "", at: t0 + 6_000, kind: "Event/Call"),
            message(oneToOne, ali, "Ali Pakkan", "removed", at: t0 + 7_000, deleted: true),
            message("48:notifications", ali, "Ali Pakkan", "You were mentioned", at: t0 + 8_000),
            // A message the user sent on someone's behalf carries that person's name.
            message(meeting, me, "Valon Dauti", "Forwarded note", at: t0 + 9_000)
        ]
        return (conversations, messages, [ali: "Ali Pakkan"])
    }

    private func mapFixture(after: Double = 0) -> TeamsMessageMapper.Result {
        let (conversations, messages, profiles) = fixture()
        return TeamsMessageMapper.map(conversations: conversations, messages: messages, profiles: profiles, afterMilliseconds: after)
    }

    private func byConversation(_ messages: [TeamsMessageMapper.Message]) -> [String: [TeamsMessageMapper.Message]] {
        Dictionary(grouping: messages, by: \.conversationID)
    }

    func test_titlesComeFromTopicsAndTheOneToOneIdNeverFromCachedTitles() {
        let result = mapFixture()
        let grouped = byConversation(result.messages)
        XCTAssertEqual(grouped[oneToOne]?.first?.conversationTitle, "Ali Pakkan")
        XCTAssertEqual(grouped[meeting]?.first?.conversationTitle, "POC Planning")
        // The group is titled by everyone in it, so it can never pass for the 1:1 with Ali.
        XCTAssertEqual(grouped[group]?.first?.conversationTitle, "Ali Pakkan, Valon Dauti")
        XCTAssertEqual(result.newestMilliseconds, t0 + 9_000)
    }

    func test_participantsIncludeEveryoneWhoWroteAndNeverTheUser() {
        let grouped = byConversation(mapFixture().messages)
        XCTAssertEqual(grouped[oneToOne]?.first?.participants, [ali])
        XCTAssertEqual(grouped[group]?.first?.participants, [ali, valon, TeamsMessageMapper.groupMarker + group])
        XCTAssertTrue(grouped[group]?.allSatisfy { $0.participants == grouped[group]?.first?.participants } ?? false)
        XCTAssertEqual(grouped[oneToOne]?.map(\.isFromMe), [false, true])
    }

    func test_keepsOnlyWhatPeopleWrote() {
        let texts = mapFixture().messages.map(\.text)
        XCTAssertTrue(texts.contains("The POC passed today"))
        XCTAssertTrue(texts.contains("Great news"), "quoted replies are dropped")
        XCTAssertFalse(texts.contains { $0.contains("removed") || $0.contains("mentioned") }, "deleted and system feeds are skipped")
        XCTAssertEqual(texts.count, 6)
    }

    func test_resumesAfterTheCursor() {
        let result = mapFixture(after: t0 + 4_000)
        XCTAssertEqual(result.messages.map(\.timestamp.timeIntervalSince1970).sorted(), [(t0 + 5_000) / 1000, (t0 + 9_000) / 1000])
        XCTAssertEqual(result.newestMilliseconds, t0 + 9_000)
    }

    func test_senderNamesFollowThePersonNotOneMessage() throws {
        let forwarded = try XCTUnwrap(mapFixture().messages.first { $0.text == "Forwarded note" })
        XCTAssertTrue(forwarded.isFromMe)
        XCTAssertEqual(forwarded.sender, "Senad Aruc")
    }

    func test_idsJoinTheConversationAndTheMessageId() {
        let ids = mapFixture().messages.map(\.sourceMessageID)
        XCTAssertEqual(ids.first, "\(oneToOne)/\(Int64(t0 + 1_000))")
        // A message without a string id falls back to its arrival time.
        var unnamed = message(group, valon, "Valon Dauti", "No id", at: t0 + 10_000)
        unnamed["id"] = 42.0
        let result = TeamsMessageMapper.map(conversations: [], messages: [unnamed], profiles: [:], afterMilliseconds: 0)
        XCTAssertEqual(result.messages.first?.sourceMessageID, "\(group)/\(Int64(t0 + 10_000))")
    }

    func test_aGroupNeverSharesParticipantsWithAOneToOneEvenWhenOnlyThatPersonWrote() {
        // The cached member list of a group is often partial: here only Ali has written in it.
        let conversations: [[String: Any]] = [
            ["id": group, "type": "Chat", "members": [["id": me]], "threadProperties": ["topic": "Ops"]]
        ]
        let messages = [
            message(oneToOne, ali, "Ali Pakkan", "my salary negotiation is private", at: t0 + 1_000),
            message(group, ali, "Ali Pakkan", "the release is on Friday", at: t0 + 2_000),
            message(group, me, "Senad Aruc", "thanks", at: t0 + 3_000)
        ]
        let grouped = byConversation(
            TeamsMessageMapper.map(conversations: conversations, messages: messages, profiles: [:], afterMilliseconds: 0).messages
        )
        XCTAssertEqual(grouped[oneToOne]?.first?.participants, [ali])
        XCTAssertEqual(grouped[group]?.first?.participants, [ali, TeamsMessageMapper.groupMarker + group])
        XCTAssertEqual(grouped[group]?.last?.isFromMe, true)
        XCTAssertEqual(grouped[group]?.first?.conversationTitle, "Ops")
    }

    func test_meIsTheMemberOfMostConversationsAndTiesGoToTheMostFrequentSender() {
        let chats = [
            TeamsMessageMapper.Conversation(id: "a", topic: "", members: [ali, me]),
            TeamsMessageMapper.Conversation(id: "b", topic: "", members: [ali, me])
        ]
        // Tied at two conversations each: the user is whoever wrote more.
        let messages = [
            message("a", me, "Senad Aruc", "one", at: t0),
            message("b", me, "Senad Aruc", "two", at: t0 + 1),
            message("b", ali, "Ali Pakkan", "three", at: t0 + 2)
        ]
        XCTAssertEqual(TeamsMessageMapper.me(chats: chats, messages: messages), me)
        // Nobody wrote: the first of the tied, in the order they were counted.
        XCTAssertEqual(TeamsMessageMapper.me(chats: chats, messages: []), ali)
        XCTAssertEqual(TeamsMessageMapper.me(chats: [], messages: []), "")
    }

    func test_oneToOneIdsAndSenderURLsResolveToMemberIds() {
        XCTAssertEqual(
            TeamsMessageMapper.oneToOneMembers("19:AAAAAAAA-0000-0000-0000-000000000001_bbbbbbbb-0000-0000-0000-000000000002@unq.gbl.spaces"),
            [me, ali]
        )
        XCTAssertEqual(TeamsMessageMapper.oneToOneMembers(group), [])
        XCTAssertEqual(TeamsMessageMapper.mri("https://emea.ng.msg.teams.microsoft.com/v1/users/ME/contacts/\(ali) "), ali)
    }

    func test_arrivalTimesAcceptMillisecondsSecondsAndStrings() {
        XCTAssertEqual(TeamsMessageMapper.milliseconds(t0), t0)
        XCTAssertEqual(TeamsMessageMapper.milliseconds(1_790_000_000), t0, "seconds are scaled")
        XCTAssertEqual(TeamsMessageMapper.milliseconds(" 1790000000000.5 "), t0 + 0.5)
        XCTAssertEqual(TeamsMessageMapper.milliseconds("2026-09-21T13:33:20.250Z"), 1_789_997_600_250)
        XCTAssertEqual(TeamsMessageMapper.milliseconds("2026-09-21T15:33:20+02:00"), 1_789_997_600_000)
        XCTAssertNil(TeamsMessageMapper.milliseconds(true))
        XCTAssertNil(TeamsMessageMapper.milliseconds(0.0))
        XCTAssertNil(TeamsMessageMapper.milliseconds("yesterday"))
        XCTAssertNil(TeamsMessageMapper.milliseconds(NSNull()))
    }

    // MARK: - HTML

    func test_htmlToTextKeepsLineBreaksAndMentions() {
        XCTAssertEqual(
            TeamsMessageHTML.text("<div>Hi <span itemtype=\"http://schema.skype.com/Mention\">Ali</span>,</div><div>see you</div>"),
            "Hi Ali,\nsee you"
        )
        XCTAssertEqual(TeamsMessageHTML.text("plain &amp; simple"), "plain & simple")
        XCTAssertEqual(TeamsMessageHTML.text(""), "")
    }

    func test_htmlToTextFollowsPythonsParserOnEdgeCases() {
        // Self-closing and bare line breaks, collapsed blank lines and spaces.
        XCTAssertEqual(TeamsMessageHTML.text("one<br/>two<br>three<p></p><p>  four \t five</p>"), "one\ntwo\nthree\nfour five")
        // Nested quotes are dropped whole; comments and doctype vanish; scripts and styles too.
        XCTAssertEqual(
            TeamsMessageHTML.text("<!DOCTYPE html><!-- note -->Yes<blockquote>a<blockquote>b</blockquote>c</blockquote> sir"
                + "<script>if (a < b) { x() }</script><style>p { color: red }</style>"),
            "Yes sir"
        )
        // Attribute values may contain ">" inside quotes.
        XCTAssertEqual(TeamsMessageHTML.text("<a title=\"x > y\" href='z'>link</a>"), "link")
        // A "<" that starts no tag is text; an unterminated tag at the end is dropped.
        XCTAssertEqual(TeamsMessageHTML.text("a < b <i>ok</i> <b"), "a < b ok")
        // Character references: numeric, legacy names without ";", longest prefix, Windows-1252 fix-ups.
        XCTAssertEqual(TeamsMessageHTML.text("<p>&#246;&#xFC; &ampfoo &lt;3 &euro; &#150; &bogus;</p>"), "öü &foo <3 € – &bogus;")
        // Non-breaking spaces become spaces; carriage returns vanish.
        XCTAssertEqual(TeamsMessageHTML.text("<p>a&nbsp;&nbsp;b\r\nc</p>"), "a b\nc")
        // Without any tag the text is only decoded and trimmed (no space collapsing), as in Python.
        XCTAssertEqual(TeamsMessageHTML.text("  a&nbsp;&nbsp;b  "), "a\u{A0}\u{A0}b")
    }

    func test_pythonStripTreatsTheSameCharactersAsSpace() {
        XCTAssertEqual(PythonText.strip("\u{1C}\u{A0} x \u{3000}\u{85}"), "x")
        XCTAssertEqual(PythonText.strip("\u{200B}x"), "\u{200B}x", "a zero-width space is not whitespace to Python")
    }
}
