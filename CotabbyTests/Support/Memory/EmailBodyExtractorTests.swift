import Foundation
import XCTest
@testable import Cotabby

/// Pins how memory reads mail bodies: the encodings and structures real mail uses, legacy Turkish
/// charsets, HTML-only mail, attachments, and Mail's `.emlx` framing.
final class EmailBodyExtractorTests: XCTestCase {
    private func body(_ raw: String) -> String? {
        EmailBodyExtractor.body(fromMessage: Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    func test_plainTextMessage() {
        XCTAssertEqual(body("Subject: Hi\nContent-Type: text/plain; charset=utf-8\n\nThe invoice is paid.\n"), "The invoice is paid.")
    }

    func test_quotedPrintableWithSoftBreaksAndEscapes() {
        let raw = "Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\n" +
            "Toplant=C4=B1 yar=C4=B1n saat =\n=C3=BC=C3=A7te.\n"
        XCTAssertEqual(body(raw), "Toplantı yarın saat üçte.")
    }

    func test_base64InWindows1254DecodesTurkishLetters() {
        // "Şirket güncellemesi" in Windows-1254: Ş = 0xDE, ü = 0xFC.
        let bytes: [UInt8] = [0xDE, 0x69, 0x72, 0x6B, 0x65, 0x74, 0x20, 0x67, 0xFC, 0x6E, 0x63, 0x65, 0x6C, 0x6C,
                              0x65, 0x6D, 0x65, 0x73, 0x69]
        let raw = "Content-Type: text/plain; charset=windows-1254\nContent-Transfer-Encoding: base64\n\n" +
            Data(bytes).base64EncodedString() + "\n"
        XCTAssertEqual(body(raw), "Şirket güncellemesi")
    }

    func test_multipartAlternativePrefersPlainTextAndSkipsAttachments() {
        let raw = """
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=utf-8

        Plain version.
        --inner
        Content-Type: text/html; charset=utf-8

        <p>HTML version.</p>
        --inner--
        --outer
        Content-Type: text/plain
        Content-Disposition: attachment; filename="notes.txt"

        Attachment text.
        --outer--
        """
        XCTAssertEqual(body(raw), "Plain version.")
    }

    func test_htmlOnlyMailBecomesTextAndMarksQuotedReplies() {
        let raw = """
        Content-Type: text/html; charset=utf-8

        <html><head><style>p{color:red}</style></head><body><p>Numbers look great &amp; on time.</p>\
        <blockquote>please send the numbers</blockquote></body></html>
        """
        let text = body(raw) ?? ""
        XCTAssertTrue(text.hasPrefix("Numbers look great & on time."))
        XCTAssertTrue(text.contains("> please send the numbers"))
        XCTAssertFalse(text.contains("color:red"))
    }

    func test_emlxFramingReadsOnlyTheMessageBytes() {
        let message = "Content-Type: text/plain\r\n\r\nHello there."
        let emlx = "\(message.utf8.count)\n\(message)<?xml version=\"1.0\"?><plist></plist>"
        XCTAssertEqual(EmailBodyExtractor.bodyFromEmlx(Data(emlx.utf8)), "Hello there.")
    }

    func test_numericEntities() {
        XCTAssertEqual(EmailBodyExtractor.decodeEntities("&#350;irket &#xFC;"), "Şirket ü")
    }
}
