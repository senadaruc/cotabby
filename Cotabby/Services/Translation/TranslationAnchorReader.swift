import ApplicationServices
import CoreGraphics
import Foundation

/// File overview:
/// Reads the chat app's own element under a translated message, so the translation can follow it
/// while the chat scrolls (`TranslationScrollFollow`). WhatsApp exposes each message as an element
/// whose frame moves live with scrolling and whose description is the message ("Your message,
/// Kardeşim orasi fena karisacak, 2Octoberat20:11, …", measured 2026-10-03).
///
/// MainActor because Accessibility reads go to the chat app over IPC from the main thread, like
/// every other AX read in Cotabby; each is one attribute read.
@MainActor
enum TranslationAnchorReader {
    /// One message's element and what identified it when the label was drawn.
    struct Anchor {
        let element: AXUIElement
        let frame: CGRect
        /// The element's description or value: a chat list reuses rows, and a row now showing
        /// another message must not carry this message's translation.
        let identity: String?

        func moved(by delta: CGVector) -> Anchor {
            Anchor(element: element, frame: frame.offsetBy(dx: delta.dx, dy: delta.dy), identity: identity)
        }
    }

    /// Message elements across `region` (global points), hit-tested on a small grid: messages sit
    /// left or right in a chat, so three columns by six rows always land on some. Containers as tall
    /// as the region (the whole message list) say nothing about a scroll and are skipped; one
    /// element hit twice is kept once. Fifteen-odd reads of about 0.5 ms (measured in WhatsApp).
    static func anchors(in region: CGRect, processIdentifier: pid_t) -> [Anchor] {
        guard region.width > 0, region.height > 0 else { return [] }
        var anchors: [Anchor] = []
        for row in 1...6 {
            for column in 1...3 {
                let point = CGPoint(
                    x: region.minX + region.width * CGFloat(column) / 4,
                    y: region.minY + region.height * CGFloat(row) / 7
                )
                guard let anchor = anchor(at: point, processIdentifier: processIdentifier),
                      anchor.identity?.isEmpty == false,
                      anchor.frame.height < region.height * 0.8,
                      !anchors.contains(where: { CFEqual($0.element, anchor.element) })
                else { continue }
                anchors.append(anchor)
            }
        }
        return anchors
    }

    /// The element of `processIdentifier` at `point` (global top-left points), or nil.
    static func anchor(at point: CGPoint, processIdentifier: pid_t) -> Anchor? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element) == .success,
              let element,
              let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: element)
        else { return nil }
        return Anchor(element: element, frame: frame, identity: identity(of: element))
    }

    /// The anchor's frame now, or nil when its element is gone or shows another message.
    static func currentFrame(of anchor: Anchor) -> CGRect? {
        guard identity(of: anchor.element) == anchor.identity else { return nil }
        return AXHelper.rectValue(for: "AXFrame" as CFString, on: anchor.element)
    }

    private static func identity(of element: AXUIElement) -> String? {
        AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)
            ?? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
    }
}
