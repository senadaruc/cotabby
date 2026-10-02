import CoreGraphics
import Foundation

/// File overview:
/// How a translation is drawn *over* the message it translates so it reads as the message itself:
/// on the bubble's own colour, in the message's text colour and size, covering exactly the text
/// lines and leaving the bubble's time and read receipt visible.
///
/// macOS gives no app a way to change another app's text (a chat message is read-only to
/// Accessibility), so replacing it visually is the closest Cotabby can come. Colours are sampled
/// from the same capture the messages were read from; the size comes from the lines' OCR boxes,
/// calibrated on WhatsApp (measured 2026-10-03): wrapped lines 16.5 pt apart for ~15 pt text, a
/// single line's box about 13 pt without descenders and about 17 pt with them.
///
/// Pure: `TranslationCoordinator` runs it off the main actor on each pass that re-reads the chat.

/// An sRGB colour sampled from a capture.
nonisolated struct ChatColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var luminance: Int { (Int(red) * 299 + Int(green) * 587 + Int(blue) * 114) / 1000 }

    func distance(to other: ChatColor) -> Int {
        max(abs(Int(red) - Int(other.red)), abs(Int(green) - Int(other.green)), abs(Int(blue) - Int(other.blue)))
    }
}

/// What to paint for one message: where (global points, top-left origin), on what, in what.
nonisolated struct TranslationCover: Equatable, Sendable {
    let rect: CGRect
    let background: ChatColor
    let foreground: ChatColor
    let fontSize: CGFloat
}

/// An RGBA8 copy of a capture, row-major, no padding.
nonisolated struct ChatPixelImage: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init?(width: Int, height: Int, rgba: [UInt8]) {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// Draws `image` into a known RGBA8 layout; capture formats vary (ScreenCaptureKit is BGRA).
    init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, rgba: bytes)
    }

    func color(x: Int, y: Int) -> ChatColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = (y * width + x) * 4
        return ChatColor(red: rgba[offset], green: rgba[offset + 1], blue: rgba[offset + 2])
    }
}

nonisolated enum TranslationCoverStyle {
    /// Points painted beyond the text's OCR box on every side, so antialiased edges of the original
    /// glyphs do not show around the translation.
    static let bleed: CGFloat = 2

    /// The cover for `block` in a capture of `windowFrame`, or nil when the bubble behind the text is
    /// not one flat colour (an image, a link preview) or the text does not stand out from it; the
    /// translation is then shown as a card instead.
    static func cover(for block: MessageBlock, in image: ChatPixelImage, windowFrame: CGRect) -> TranslationCover? {
        guard windowFrame.width > 0, !block.frame.isEmpty else { return nil }
        let scale = CGFloat(image.width) / windowFrame.width
        func pixel(_ point: CGPoint) -> ChatColor? {
            image.color(
                x: Int(((point.x - windowFrame.minX) * scale).rounded(.down)),
                y: Int(((point.y - windowFrame.minY) * scale).rounded(.down))
            )
        }
        let lines = block.lineFrames.isEmpty ? [block.frame] : block.lineFrames
        // The bubble shows in its padding: just left of every line, and just above the first.
        var samples = lines.compactMap { pixel(CGPoint(x: $0.minX - 4, y: $0.midY)) }
        samples += stride(from: block.frame.minX, to: block.frame.maxX, by: max(8, block.frame.width / 6))
            .compactMap { pixel(CGPoint(x: $0, y: block.frame.minY - 3)) }
        guard let background = median(samples),
              samples.allSatisfy({ $0.distance(to: background) <= 18 })
        else { return nil }
        // The text's core pixels carry its full colour; antialiased edges only blend towards it.
        var foreground: ChatColor?
        var best = 0
        for line in lines {
            var y = line.minY
            while y < line.maxY {
                var x = line.minX
                while x < line.maxX {
                    if let color = pixel(CGPoint(x: x, y: y)), color.distance(to: background) > best {
                        best = color.distance(to: background)
                        foreground = color
                    }
                    x += 0.5
                }
                y += 0.5
            }
        }
        guard let foreground, best >= 60 else { return nil }
        return TranslationCover(
            rect: block.frame.insetBy(dx: -bleed, dy: -bleed),
            background: background,
            foreground: foreground,
            fontSize: fontSize(lineFrames: lines)
        )
    }

    /// The message's text size from its lines' OCR boxes: the line pitch when it wraps, else the
    /// single box scaled for whether it holds descenders (see the file overview).
    static func fontSize(lineFrames: [CGRect]) -> CGFloat {
        let size: CGFloat
        if lineFrames.count >= 2 {
            let tops = lineFrames.map(\.minY).sorted()
            let pitches = zip(tops, tops.dropFirst()).map { $1 - $0 }.sorted()
            size = pitches[pitches.count / 2] * 0.9
        } else if let height = lineFrames.first?.height {
            size = height >= 15.5 ? height * 0.88 : height * 1.15
        } else {
            size = 14
        }
        return min(max(size, 10), 24)
    }

    private static func median(_ colors: [ChatColor]) -> ChatColor? {
        guard !colors.isEmpty else { return nil }
        func middle(_ values: [UInt8]) -> UInt8 { values.sorted()[values.count / 2] }
        return ChatColor(
            red: middle(colors.map(\.red)), green: middle(colors.map(\.green)), blue: middle(colors.map(\.blue))
        )
    }
}
