import XCTest
@testable import Cotabby

/// Per-chat scope for chat apps whose window title never changes (WhatsApp).
final class ConversationHeaderPolicyTests: XCTestCase {
    func testWhatsAppNamesTheChatByItsHeaderButton() {
        XCTAssertEqual(
            ConversationHeaderPolicy.headerIdentifier(forBundleIdentifier: "net.whatsapp.WhatsApp"),
            "NavigationBar_HeaderViewButton"
        )
        XCTAssertNil(ConversationHeaderPolicy.headerIdentifier(forBundleIdentifier: "com.apple.TextEdit"))
        XCTAssertNil(ConversationHeaderPolicy.headerIdentifier(forBundleIdentifier: nil))
    }

    func testTitlesLoseBidiMarksAndBlankTitlesAreMissing() {
        XCTAssertEqual(ConversationHeaderPolicy.cleanedTitle("\u{200E}Dominique Meurisse "), "Dominique Meurisse")
        XCTAssertNil(ConversationHeaderPolicy.cleanedTitle("\u{200E} "))
        XCTAssertNil(ConversationHeaderPolicy.cleanedTitle(nil))
    }

    func testTheOpenChatKeysPerWindowChoicesBeforeTheWindowTitle() {
        let chat = CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "\u{200E}WhatsApp")
        XCTAssertEqual(chat.featureScopeWindowTitle, "\u{200E}WhatsApp")
        let withConversation = FocusedInputSnapshot(
            applicationName: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp", processIdentifier: 1,
            elementIdentifier: "composer", role: "AXTextArea", subrole: nil,
            caretRect: CGRect(x: 0, y: 0, width: 2, height: 16), inputFrameRect: nil,
            caretSource: "test", caretQuality: .exact, observedCharWidth: nil,
            precedingText: "", trailingText: "", selection: NSRange(location: 0, length: 0), isSecure: false,
            windowTitle: "\u{200E}WhatsApp", conversationTitle: "Dominique Meurisse"
        )
        XCTAssertEqual(withConversation.featureScopeWindowTitle, "Dominique Meurisse")
    }
}
