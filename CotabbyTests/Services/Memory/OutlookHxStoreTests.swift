import Foundation
import XCTest
@testable import Cotabby

/// Pins the reader of New Outlook's local store: LZ4 blocks, record framing, the message fields
/// read from a record, versioned records collapsing to one message, and the mapping into memory.
/// Records are built by hand here in the shape observed in a real store; an optional test reads a
/// copy of a real store (`COTABBY_TEST_HXSTORE`) and reports only counts.
final class OutlookHxStoreTests: XCTestCase {
    // MARK: - Builders

    /// An LZ4 block made of one literal run (valid LZ4: a final sequence may be literals only).
    static func lz4Literals(_ bytes: [UInt8]) -> [UInt8] {
        var block: [UInt8] = []
        if bytes.count < 15 {
            block.append(UInt8(bytes.count << 4))
        } else {
            block.append(0xF0)
            var rest = bytes.count - 15
            while rest >= 255 { block.append(255); rest -= 255 }
            block.append(UInt8(rest))
        }
        return block + bytes
    }

    static func utf16z(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
    }

    static func ticks(_ date: Date) -> [UInt8] {
        let value = HxStoreRecordParser.ticks(for: date)
        return (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }

    /// A mail record: binary head with a send time, then the string table, optionally a body.
    static func record(strings: [String], sent: Date, body: String? = nil) -> [UInt8] {
        var bytes: [UInt8] = [1, 0, 0, 0] + [UInt8](repeating: 0, count: 60) + ticks(sent) + [UInt8](repeating: 0, count: 40)
        if let body {
            bytes += utf16z("IPM.Note") + Array(body.utf8)
        }
        for string in strings { bytes += utf16z(string) }
        return bytes
    }

    static func framed(_ record: [UInt8], id: UInt64 = 1) -> [UInt8] {
        let block = lz4Literals(record)
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        return le32(block.count) + le32(record.count) + le32(4) + (0..<8).map { UInt8((id >> (8 * UInt64($0))) & 0xFF) } + block
    }

    private let sent = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - LZ4

    func test_lz4DecodesLiteralsAndOverlappingMatchesAndRejectsBadInput() throws {
        // "abcabcabca": literals "abc", then a 7-byte match at offset 3 (overlapping), then empty literals.
        let block: [UInt8] = [0x33, 0x61, 0x62, 0x63, 0x03, 0x00, 0x00]
        let decoded = try block.withUnsafeBytes { try LZ4BlockDecoder.decode($0, range: 0..<block.count, maximumOutput: 64) }
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "abcabcabca")
        let badOffset: [UInt8] = [0x10, 0x61, 0x09, 0x00]
        XCTAssertThrowsError(try badOffset.withUnsafeBytes { try LZ4BlockDecoder.decode($0, range: 0..<4, maximumOutput: 64) })
        XCTAssertThrowsError(try block.withUnsafeBytes { try LZ4BlockDecoder.decode($0, range: 0..<block.count, maximumOutput: 5) },
                             "output is capped at the declared size")
    }

    // MARK: - Records

    func test_aReceivedMessageRecordYieldsItsFields() throws {
        let bytes = Self.record(strings: [
            "ayse@client.com", "Ayşe Yılmaz", "IPM.Note", "<abc123@client.com>",
            "Hi Senad, could you send the POC numbers before Friday? Thanks a lot", "RE: POC numbers", "POC numbers",
        ], sent: sent)
        let message = try XCTUnwrap(HxStoreRecordParser.parse(bytes, now: sent.addingTimeInterval(3600)))
        XCTAssertEqual(message.messageID, "<abc123@client.com>")
        XCTAssertEqual(message.senderAddress, "ayse@client.com")
        XCTAssertEqual(message.senderName, "Ayşe Yılmaz")
        XCTAssertEqual(message.subject, "RE: POC numbers")
        XCTAssertEqual(message.topic, "POC numbers")
        XCTAssertEqual(message.preview, "Hi Senad, could you send the POC numbers before Friday? Thanks a lot")
        XCTAssertEqual(message.sent?.timeIntervalSince1970 ?? 0, sent.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_aBodyRecordKeepsItsHTMLAndReadsStringsAfterIt() throws {
        let bytes = Self.record(strings: ["dme@imperum.io", "Dominique", "<m1@imperum.io>", "Status update", "Status update"],
                                sent: sent, body: "<html><body><p>The client approved the Q4 budget.</p></body></html>")
        let message = try XCTUnwrap(HxStoreRecordParser.parse(bytes, now: sent.addingTimeInterval(60)))
        XCTAssertEqual(message.bodyHTML, "<html><body><p>The client approved the Q4 budget.</p></body></html>")
        XCTAssertEqual(message.subject, "Status update")
        XCTAssertEqual(message.senderAddress, "dme@imperum.io")
    }

    func test_nonMailAndFutureDatedRecordsAreNotMessages() {
        XCTAssertNil(HxStoreRecordParser.parse(Self.record(strings: ["IPM.Appointment", "<x@y.z>", "Lunch"], sent: sent)))
        XCTAssertNil(HxStoreRecordParser.parse([UInt8](repeating: 7, count: 300)))
        let future = Self.record(strings: ["a@b.co", "IPM.Note", "<f@b.co>", "Hello there friend", "Hello there friend"],
                                 sent: Date().addingTimeInterval(30 * 86_400))
        XCTAssertNil(HxStoreRecordParser.parse(future)?.sent, "a time from the future is not a send time")
    }

    // MARK: - File

    func test_theFileScanFindsRecordsBetweenNoiseAndKeepsTheFullestVersion() throws {
        let preview = Self.record(strings: ["ali@x.com", "Ali", "IPM.Note", "<v@x.com>", "Short preview of the message here", "Pilot", "Pilot"], sent: sent)
        let full = Self.record(strings: ["ali@x.com", "Ali", "<v@x.com>", "Pilot", "Pilot"], sent: sent,
                               body: "<html>The pilot runs six weeks.</html>")
        let other = Self.record(strings: ["can@x.com", "Can", "IPM.Note", "<w@x.com>", "Another message body preview text", "Budget", "Budget"], sent: sent)
        var file: [UInt8] = Array("Nostromo".utf8)
        file += [UInt8](repeating: 0xAB, count: 37) + Self.framed(preview, id: 7)
        file += [UInt8](repeating: 0x11, count: 101) + Self.framed(other, id: 9)
        file += Self.framed(full, id: 7) + [UInt8](repeating: 0, count: 50)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hx-\(UUID().uuidString).hxd")
        try Data(file).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let messages = try HxStoreFile.messages(at: url, now: sent.addingTimeInterval(60))
        XCTAssertEqual(Set(messages.map(\.messageID)), ["<v@x.com>", "<w@x.com>"])
        XCTAssertEqual(messages.first { $0.messageID == "<v@x.com>" }?.bodyText, "The pilot runs six weeks.",
                       "the version with the body wins, kept as text")
    }

    func test_messagesMapToMemoryRecordsWithThreadsAndOwnership() throws {
        let received = HxMailRecord(messageID: "<a@x.com>", messageClass: "IPM.Note", subject: "RE: POC numbers",
                                    senderAddress: "ayse@client.com", senderName: "Ayşe", preview: "preview",
                                    bodyHTML: "<html><p>Numbers attached.</p></html>", sent: sent)
        let mine = HxMailRecord(messageID: "<b@x.com>", messageClass: "IPM.Note", subject: "POC numbers",
                                senderAddress: "senad@imperum.io", senderName: "Senad", preview: "Here they are", bodyHTML: nil, sent: sent)
        let a = try XCTUnwrap(OutlookHistoryReader.ingestRecord(received, sent: sent, ownAddresses: ["senad@imperum.io"]))
        let b = try XCTUnwrap(OutlookHistoryReader.ingestRecord(mine, sent: sent, ownAddresses: ["senad@imperum.io"]))
        XCTAssertEqual(a.conversationID, b.conversationID, "replies share their thread")
        XCTAssertEqual(a.conversationTitle, "POC numbers")
        XCTAssertEqual(a.text, "Numbers attached.")
        XCTAssertEqual(a.participants, ["ayse@client.com"])
        XCTAssertFalse(a.isFromMe)
        XCTAssertTrue(b.isFromMe)
        XCTAssertEqual(b.text, "Here they are", "no body: the preview")
    }

    func test_cursorReadsOldAndNewForms() {
        XCTAssertEqual(OutlookHistoryReader.Cursor("108155"), .init(legacy: "108155", newOutlookMilliseconds: nil))
        let both = OutlookHistoryReader.Cursor(legacy: "5", newOutlookMilliseconds: 1_790_000_000_000)
        XCTAssertEqual(OutlookHistoryReader.Cursor(both.text), both)
        XCTAssertEqual(OutlookHistoryReader.Cursor("L|H1790000000000"), .init(legacy: nil, newOutlookMilliseconds: 1_790_000_000_000))
    }

    // MARK: - A real store

    /// Reads a copy of a real `HxStore.hxd` and reports counts only (no content).
    func test_aRealStoreYieldsMessages() throws {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_TEST_HXSTORE"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set COTABBY_TEST_HXSTORE to a copy of HxStore.hxd")
        }
        let started = Date()
        let messages = try HxStoreFile.messages(at: URL(fileURLWithPath: path))
        let seconds = Date().timeIntervalSince(started)
        let dated = messages.compactMap(\.sent).sorted()
        print(String(format: "hxstore: %d messages in %.1fs; dated %d (%@ … %@); subject %d; sender %d; body %d", messages.count, seconds,
                     dated.count, dated.first.map { "\($0)" } ?? "-", dated.last.map { "\($0)" } ?? "-",
                     messages.filter { $0.subject != nil }.count, messages.filter { $0.senderAddress != nil }.count,
                     messages.filter { $0.bodyText != nil }.count))
        XCTAssertGreaterThan(messages.count, 0)
    }
}
