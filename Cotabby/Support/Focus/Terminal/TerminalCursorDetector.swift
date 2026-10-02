import CoreGraphics
import Foundation

/// File overview:
/// Finds a terminal's cursor in a capture of its text area, for terminals whose Accessibility
/// element reports neither the cursor's offset nor any character bounds (Ghostty: the insertion
/// point is always 0 of the whole scrollback and `AXBoundsForRange` is unsupported, measured
/// 2026-10-02). The terminal has painted the answer: its cursor is a bar, block or hollow box in the
/// configured cursor colour, one cell tall, a shape ordinary glyphs do not make.
///
/// Also measures the grid from the same pixels: the row and column pitch (a monospace grid makes the
/// per-row and per-column ink profiles periodic) and the lowest inked row, which ties a screen row to
/// a line of the terminal's text (`TerminalScreenTextMapper`).
///
/// Pure and synchronous: `TerminalCursorTracker` owns capture and scheduling and runs this off the
/// main actor. Measured in a live Ghostty window (190 x 60 cells at 2x): row pitch 39 px, column pitch
/// 17 px, the cursor's two box edges the only cursor-coloured full-cell strokes on screen.

/// An RGBA8 image, row-major, four bytes per pixel, no row padding.
struct TerminalPixelBuffer: Equatable, Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init?(width: Int, height: Int, rgba: [UInt8]) {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// Draws `image` into an RGBA8 buffer. CGImage pixel formats vary by source (ScreenCaptureKit
    /// returns BGRA); drawing into a known context is the one portable way to read the bytes.
    init?(image: CGImage) {
        let width = image.width
        let height = image.height
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
}

/// An sRGB colour as configured for the terminal (`cursor-color = #e6edf3`).
struct TerminalRGBColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rrggbb` or `rrggbb`.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }
}

nonisolated enum TerminalCursorDetector {
    /// What one capture shows, in the capture's pixels (top-left origin).
    struct Measurement: Equatable, Sendable {
        /// Left edge of the cursor: the cell's left edge for a bar, block or hollow box.
        let cursorX: Int
        /// Top of the cursor's cell.
        let cursorTop: Int
        let cursorHeight: Int
        let rowPitch: Double
        let columnPitch: Double
        /// Lowest pixel row with any ink, which lies in the last inked text row.
        let lastInkY: Int

        /// Text rows from the cursor's row down to the last inked row (0 when the cursor is on it).
        var rowsFromCursorToLastInk: Int {
            max(0, Int(((Double(lastInkY) - Double(cursorTop)) / rowPitch).rounded(.down)))
        }
    }

    /// Per-channel distance under which a pixel counts as the cursor colour. Antialiasing never
    /// touches the stroke's interior, so the run stays unbroken at this tolerance.
    static let colorTolerance = 24
    /// Luminance distance from the background above which a pixel counts as ink.
    static let inkThreshold = 40

    static func measure(_ buffer: TerminalPixelBuffer, cursorColor: TerminalRGBColor) -> Measurement? {
        // The cursor comes first and calibrates the grid: autocorrelation alone cannot tell a pitch
        // from its multiples on a real screen (measured live: rows alternating with blank rows
        // scored 78 px far above the true 39 px, and columns scored 17 and 34 px within 1%).
        guard let cursor = cursorBox(buffer, color: cursorColor) else { return nil }
        let background = backgroundLuminance(buffer)
        let rows = rowInkProfile(buffer, background: background)
        let columns = columnInkProfile(buffer, background: background)
        let height = Double(cursor.height)
        // A cursor is drawn inside its cell, so the cell is at least as tall and not much taller.
        guard let rowPitch = pitch(of: rows, within: (height * 0.95)...(height * 1.4)),
              // A cursor fills most of its cell. With the cursor blinked off, the tallest
              // cursor-coloured strokes are glyphs (measured 29 px in a 39 px row): not a cursor.
              height >= rowPitch * 0.85,
              let lastInkY = rows.lastIndex(where: { $0 > 0 })
        else { return nil }
        // A hollow box or block spans the cell's width; a bar does not, so its cell width is searched
        // over terminal cell proportions (0.35-0.75 of the height; 8.5 x 19.5 pt measured).
        let span = Double(cursor.width)
        let columnRange = span >= rowPitch * 0.3
            ? (span * 0.85)...(span * 1.2)
            : (rowPitch * 0.35)...(rowPitch * 0.75)
        guard let columnPitch = pitch(of: columns, within: columnRange) else { return nil }
        return Measurement(
            cursorX: cursor.x, cursorTop: cursor.top, cursorHeight: cursor.height,
            rowPitch: rowPitch, columnPitch: columnPitch, lastInkY: lastInkY
        )
    }

    // MARK: - Grid

    /// The median luminance of a sparse sample: a terminal screen is mostly background.
    static func backgroundLuminance(_ buffer: TerminalPixelBuffer) -> Int {
        var samples: [Int] = []
        let step = max(1, (buffer.width * buffer.height) / 4000)
        var index = 0
        while index < buffer.width * buffer.height {
            samples.append(luminance(buffer, pixel: index))
            index += step
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    static func rowInkProfile(_ buffer: TerminalPixelBuffer, background: Int) -> [Double] {
        (0..<buffer.height).map { y in
            var count = 0
            var x = 0
            while x < buffer.width {
                if abs(luminance(buffer, pixel: y * buffer.width + x) - background) > inkThreshold { count += 1 }
                x += 2
            }
            return Double(count)
        }
    }

    static func columnInkProfile(_ buffer: TerminalPixelBuffer, background: Int) -> [Double] {
        (0..<buffer.width).map { x in
            var count = 0
            var y = 0
            while y < buffer.height {
                if abs(luminance(buffer, pixel: y * buffer.width + x) - background) > inkThreshold { count += 1 }
                y += 2
            }
            return Double(count)
        }
    }

    /// The lag within `range` at which the ink profile best repeats, refined to a fraction of a pixel
    /// by a parabola through the peak so the error does not add up over sixty rows. Nil when the
    /// profile does not repeat there (no positive score) or is too short to tell.
    static func pitch(of profile: [Double], within range: ClosedRange<Double>) -> Double? {
        let lower = max(2, Int(range.lowerBound.rounded(.down)))
        let upper = Int(range.upperBound.rounded(.up))
        guard upper > lower, profile.count > upper * 2 else { return nil }
        let mean = profile.reduce(0, +) / Double(profile.count)
        let centered = profile.map { $0 - mean }
        func score(_ lag: Int) -> Double {
            var sum = 0.0
            for index in 0..<(centered.count - lag) { sum += centered[index] * centered[index + lag] }
            return sum / Double(centered.count - lag)
        }
        let scores = Dictionary(uniqueKeysWithValues: ((lower - 1)...(upper + 1)).map { ($0, score($0)) })
        guard let lag = (lower...upper).max(by: { scores[$0]! < scores[$1]! }), scores[lag]! > 0 else { return nil }
        let left = scores[lag - 1]!, center = scores[lag]!, right = scores[lag + 1]!
        let denominator = left - 2 * center + right
        guard denominator < 0 else { return Double(lag) }
        return Double(lag) + min(max(0.5 * (left - right) / denominator, -0.5), 0.5)
    }

    // MARK: - Cursor

    /// The cursor: the tallest cursor-coloured vertical strokes on screen, which must form exactly
    /// one group (sharing a top, side by side within a few stroke heights). A bar is one stroke, a
    /// hollow box two, a block many. Glyphs drawn in the same colour make shorter strokes (measured
    /// 26 px against the cursor's 37 px) and are ignored; two equally tall groups are ambiguous, so
    /// the answer is none rather than a guess that would put the ghost on the wrong line.
    static func cursorBox(_ buffer: TerminalPixelBuffer, color: TerminalRGBColor) -> (x: Int, top: Int, width: Int, height: Int)? {
        var strokes: [(x: Int, top: Int, height: Int)] = []
        for x in 0..<buffer.width {
            var run = 0
            for y in 0...buffer.height {
                if y < buffer.height, matches(buffer, pixel: y * buffer.width + x, color: color) {
                    run += 1
                    continue
                }
                if run >= minimumStrokeHeight { strokes.append((x, y - run, run)) }
                run = 0
            }
        }
        guard let tallest = strokes.map(\.height).max() else { return nil }
        let tall = strokes.filter { Double($0.height) >= Double(tallest) * 0.9 }
        var groups: [[(x: Int, top: Int, height: Int)]] = []
        for stroke in tall.sorted(by: { ($0.top, $0.x) < ($1.top, $1.x) }) {
            if let index = groups.firstIndex(where: { group in
                abs(group[0].top - stroke.top) <= 2 && stroke.x - group[0].x <= tallest
            }) {
                groups[index].append(stroke)
            } else {
                groups.append([stroke])
            }
        }
        guard groups.count == 1, let group = groups.first else { return nil }
        let left = group.map(\.x).min() ?? 0
        let right = group.map(\.x).max() ?? left
        return (
            x: left,
            top: group.map(\.top).min() ?? 0,
            width: right - left + 1,
            height: group.map(\.height).max() ?? 0
        )
    }

    /// Shortest stroke considered: well under any terminal cell at 1x.
    static let minimumStrokeHeight = 10

    // MARK: - Pixels

    private static func luminance(_ buffer: TerminalPixelBuffer, pixel: Int) -> Int {
        let offset = pixel * 4
        // Integer Rec. 601 weights; exact enough to separate ink from background.
        return (Int(buffer.rgba[offset]) * 299 + Int(buffer.rgba[offset + 1]) * 587 + Int(buffer.rgba[offset + 2]) * 114) / 1000
    }

    private static func matches(_ buffer: TerminalPixelBuffer, pixel: Int, color: TerminalRGBColor) -> Bool {
        let offset = pixel * 4
        return abs(Int(buffer.rgba[offset]) - Int(color.red)) <= colorTolerance
            && abs(Int(buffer.rgba[offset + 1]) - Int(color.green)) <= colorTolerance
            && abs(Int(buffer.rgba[offset + 2]) - Int(color.blue)) <= colorTolerance
    }
}
