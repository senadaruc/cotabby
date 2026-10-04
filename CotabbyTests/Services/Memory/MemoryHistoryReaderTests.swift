import Foundation
import SQLite3
import XCTest
@testable import Cotabby

/// Pins the readers of protected stores against fixture databases with the same tables WhatsApp
/// and Mail use: what becomes a record, who the participants are, how cursors advance, which
/// messages are skipped, and that an unrecognized layout is refused rather than misread.
final class MemoryHistoryReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("memory-readers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDatabase(_ path: String, _ sql: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    // MARK: - WhatsApp

    private func whatsAppFixture() throws -> WhatsAppHistoryReader {
        let path = directory.appendingPathComponent("ChatStorage.sqlite").path
        // Apple-epoch dates: 810000000 is 2026-09-01.
        try makeDatabase(path, """
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR, ZSESSIONTYPE INTEGER);
        CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMEMBERJID VARCHAR, ZCONTACTNAME VARCHAR, ZFIRSTNAME VARCHAR);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZTEXT VARCHAR, ZISFROMME INTEGER, ZMESSAGEDATE TIMESTAMP,
            ZCHATSESSION INTEGER, ZGROUPMEMBER INTEGER, ZSTANZAID VARCHAR, ZPUSHNAME VARCHAR, ZGROUPEVENTTYPE INTEGER);
        INSERT INTO ZWACHATSESSION VALUES (1, '905551112233@s.whatsapp.net', 'Ayşe', 0), (2, '12036@g.us', 'Trip', 1),
            (3, 'status@broadcast', 'Status', 3);
        INSERT INTO ZWAGROUPMEMBER VALUES (10, 2, '905551112233@s.whatsapp.net', 'Ayşe', 'Ayşe'), (11, 2, '905559998877@s.whatsapp.net', NULL, 'Can');
        INSERT INTO ZWAMESSAGE VALUES
            (1, 'the invoice is paid', 0, 810000000, 1, NULL, 'A1', NULL, 0),
            (2, 'thanks!', 1, 810000100, 1, NULL, 'A2', NULL, 0),
            (3, 'budget is fixed', 0, 810000200, 2, 11, 'G1', 'Can P', 0),
            (4, NULL, 0, 810000300, 1, NULL, 'A3', NULL, 0),
            (5, 'Can joined', 0, 810000400, 2, NULL, 'G2', NULL, 1),
            (6, 'my status', 1, 810000500, 3, NULL, 'S1', NULL, 0),
            (7, printf('%.*c', 20000, 'x'), 0, 810000600, 1, NULL, 'A4', NULL, 0);
        """)
        return WhatsAppHistoryReader(databasePath: path)
    }

    func test_whatsAppReadsTextFromChatsAndGroupsWithJIDParticipants() throws {
        let reader = try whatsAppFixture()
        XCTAssertEqual(reader.readiness(), .ready)
        let page = try reader.read(after: nil, since: nil, limit: 100)

        XCTAssertEqual(page.records.prefix(3).map(\.text), ["the invoice is paid", "thanks!", "budget is fixed"])
        XCTAssertEqual(page.records.last?.text.count, EmailBodyExtractor.maximumCharacters, "huge messages are capped")
        let first = page.records[0]
        XCTAssertEqual(first.conversationID, "905551112233@s.whatsapp.net")
        XCTAssertEqual(first.conversationTitle, "Ayşe")
        XCTAssertEqual(first.sender, "Ayşe")
        XCTAssertEqual(first.participants, ["905551112233@s.whatsapp.net"])
        XCTAssertEqual(first.timestamp.timeIntervalSince1970, 810000000 + WhatsAppHistoryReader.appleEpochOffset)
        XCTAssertTrue(page.records[1].isFromMe)
        let group = page.records[2]
        XCTAssertEqual(group.sender, "Can")
        XCTAssertEqual(Set(group.participants), ["905551112233@s.whatsapp.net", "905559998877@s.whatsapp.net"])
        // The cursor is the last row returned; rows the query skips (no text, system events, status)
        // are simply re-checked by the next read.
        XCTAssertEqual(page.nextCursor, "7")
        XCTAssertFalse(page.hasMore)
    }

    func test_whatsAppResumesAfterTheCursorAndPages() throws {
        let reader = try whatsAppFixture()
        let first = try reader.read(after: nil, since: nil, limit: 2)
        XCTAssertTrue(first.hasMore)
        let rest = try reader.read(after: first.nextCursor, since: nil, limit: 10)
        XCTAssertEqual(rest.records.first?.text, "budget is fixed")
    }

    func test_anUnrecognizedLayoutIsRefused() throws {
        let path = directory.appendingPathComponent("Other.sqlite").path
        try makeDatabase(path, "CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZBODY TEXT);")
        if case .failed = WhatsAppHistoryReader(databasePath: path).readiness() {} else {
            XCTFail("a different layout must be refused")
        }
        XCTAssertEqual(WhatsAppHistoryReader(databasePath: path + ".missing").readiness().isReady, false)
    }

    // MARK: - Apple Mail

    func test_mailUsesSummariesOrEmlxAndKnowsWhichMailIsMine() throws {
        let root = directory.appendingPathComponent("V10")
        let mailData = root.appendingPathComponent("MailData")
        let messages = root.appendingPathComponent("ACCOUNT/INBOX.mbox/UUID/Data/Messages")
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let emlxBody = "Content-Type: text/plain\r\n\r\nNumbers look great, see you Friday."
        try Data("\(emlxBody.utf8.count)\n\(emlxBody)".utf8).write(to: messages.appendingPathComponent("2.emlx"))
        try makeDatabase(mailData.appendingPathComponent("Envelope Index").path, """
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, subject INTEGER, summary INTEGER,
            date_received INTEGER, mailbox INTEGER, deleted INTEGER, conversation_id INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
        INSERT INTO mailboxes VALUES (1, 'imap://ACCOUNT/INBOX'), (2, 'imap://ACCOUNT/Sent%20Messages');
        INSERT INTO addresses VALUES (1, 'Me@Example.com', 'Senad'), (2, 'ayse@example.com', 'Ayşe Yılmaz');
        INSERT INTO subjects VALUES (1, 'POC results');
        INSERT INTO summaries VALUES (1, 'Could you send the POC numbers before the call on Thursday please?');
        INSERT INTO messages VALUES
            (1, 1, 1, 1, 1790000000, 2, 0, 77),
            (2, 2, 1, NULL, 1790000500, 1, 0, 77),
            (3, 2, 1, NULL, 1790000900, 1, 1, 77);
        INSERT INTO recipients VALUES (1, 1, 2, 0, 0), (2, 2, 1, 0, 0);
        """)
        let reader = AppleMailHistoryReader(mailRoot: root.path)
        XCTAssertEqual(reader.readiness(), .ready)
        let page = try reader.read(after: nil, since: nil, limit: 50)

        XCTAssertEqual(page.records.count, 2, "the deleted message is skipped")
        let mine = page.records[0]
        XCTAssertTrue(mine.isFromMe)
        XCTAssertEqual(mine.text, "Could you send the POC numbers before the call on Thursday please?")
        XCTAssertEqual(mine.participants, ["ayse@example.com"])
        XCTAssertEqual(mine.conversationID, "77")
        XCTAssertEqual(mine.subject, "POC results")
        let theirs = page.records[1]
        XCTAssertFalse(theirs.isFromMe)
        XCTAssertEqual(theirs.sender, "Ayşe Yılmaz")
        XCTAssertEqual(theirs.text, "Numbers look great, see you Friday.")
        XCTAssertEqual(theirs.participants, ["ayse@example.com"])
    }

    func test_mailSubjectsLoseReplyPrefixes() {
        XCTAssertEqual(AppleMailHistoryReader.baseSubject("Re: Fwd: POC results"), "POC results")
        XCTAssertEqual(AppleMailHistoryReader.baseSubject("YNT: Teklif"), "Teklif")
        XCTAssertEqual(AppleMailHistoryReader.baseSubject("Reminder: invoice"), "Reminder: invoice")
    }

    // MARK: - Sync batching

    func test_batchesStayUnderTheRequestLimit() {
        let big = String(repeating: "x", count: 250_000)
        let records = (0..<5).map {
            MemoryIngestRecord(sourceMessageID: "\($0)", conversationID: "c", conversationTitle: "t", sender: "s",
                               isFromMe: false, timestamp: Date(), text: big, participants: [], subject: nil)
        }
        let batches = MemoryHistorySync.batches(records)
        XCTAssertEqual(batches.map(\.count), [2, 2, 1])
        XCTAssertEqual(MemoryHistorySync.batches([]).count, 0)
    }
}
