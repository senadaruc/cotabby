import CoreGraphics
import Foundation

/// File overview:
/// The few Ghostty settings the pixel cursor needs: the cursor's colour (to find it) and the window
/// padding (where column 0 starts). Read from the user's own config files, never written.
///
/// Ghostty's config is `key = value` lines, later lines winning, `#` comments. A colour set only in
/// a theme file is not followed: without a `cursor-color` the cursor is assumed to be drawn in the
/// `foreground` colour, then in Ghostty's default light foreground.
nonisolated struct GhosttyConfiguration: Equatable, Sendable {
    var cursorColor: TerminalRGBColor
    /// Left padding in points (`window-padding-x`, the first value of a `left,right` pair).
    var paddingX: CGFloat

    static let defaultPadding: CGFloat = 2
    static let defaultCursorColor = TerminalRGBColor(red: 0xFF, green: 0xFF, blue: 0xFF)

    static func parse(_ text: String) -> GhosttyConfiguration {
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        let color = values["cursor-color"].flatMap(TerminalRGBColor.init(hex:))
            ?? values["foreground"].flatMap(TerminalRGBColor.init(hex:))
            ?? defaultCursorColor
        let padding = values["window-padding-x"]
            .flatMap { $0.split(separator: ",").first }
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map { CGFloat($0) } ?? defaultPadding
        return GhosttyConfiguration(cursorColor: color, paddingX: padding)
    }

    /// The user's config files in the order Ghostty loads them; later files win.
    static var configFileURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        return [
            xdg.appendingPathComponent("ghostty/config"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config")
        ]
    }

    static func load() -> GhosttyConfiguration {
        let text = configFileURLs
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        return parse(text)
    }
}
