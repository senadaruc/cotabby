import AppKit
import CoreGraphics
import Foundation

/// File overview:
/// Other apps' floating windows near a rectangle on screen, in AppKit coordinates, so the translation
/// strip can stay clear of a selection toolbar another utility put over the same selection. PopClip
/// shows its bar above any selection the moment the mouse goes up, half a second before Cotabby's
/// strip arrives; without this the strip landed on top of it. Owned by nobody: one bounded
/// `CGWindowListCopyWindowInfo` call per placement, made by `SelectionTranslationPanelController`.
///
/// Which windows count is decided by `isObstacle`: a thin bar is a toolbar at any width, but a
/// full-width strip or a large window is screen furniture. PopClip's bar is 28pt tall and 778 to
/// 1126pt wide depending on how many extensions it shows, so a plain width cap threw the wide ones away.
///
/// Only window bounds, level and owner are read, which needs no permission; window titles would
/// need Screen Recording and are never asked for.
@MainActor
enum FloatingWindowLocator {
    /// Windows farther than this from the anchor cannot be in the strip's way.
    static let searchMargin: CGFloat = 240
    /// A window this thin is a toolbar however wide it is. PopClip's selection bar measures 28pt tall
    /// and 778, 928 or 1126pt wide depending on its extensions, so width alone cannot tell it apart
    /// from an overlay.
    static let maximumToolbarHeight: CGFloat = 80
    /// A thin window spanning this share of its display is screen furniture (the menu bar, a notch
    /// utility's strip), not a selection toolbar; stepping over it would push the strip off the
    /// selection. Just under 1 so a window a few points short of the edge still counts as full width.
    static let fullWidthFraction: CGFloat = 0.98
    /// Anything taller than a toolbar and larger than this is a full-screen overlay (a screen
    /// recorder's frame, a dock-like panel), not a toolbar.
    static let maximumObstacleSize = CGSize(width: 900, height: 600)

    /// Whether a window of `size` is a selection toolbar the strip should step over. Pure so the rule
    /// is testable without a window list. `displayWidth` is the width of the display the window is on
    /// (nil when no display could be found, in which case a thin window is kept: wrongly stepping
    /// over a menu bar costs less than landing on a toolbar).
    nonisolated static func isObstacle(size: CGSize, displayWidth: CGFloat?) -> Bool {
        if size.height <= maximumToolbarHeight {
            guard let displayWidth, displayWidth > 0 else { return true }
            return size.width < displayWidth * fullWidthFraction
        }
        return size.width <= maximumObstacleSize.width && size.height <= maximumObstacleSize.height
    }

    /// Floating windows of other processes that come within `searchMargin` of `anchor`.
    static func floatingWindows(near anchor: CGRect) -> [CGRect] {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = displayGeometries()
        let region = anchor.insetBy(dx: -searchMargin, dy: -searchMargin)
        return infos.compactMap { info -> CGRect? in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != ownPID,
                  // Layer 0 is an ordinary document window: the host the selection lives in, never an
                  // obstacle. Everything a utility floats over it sits on a higher layer.
                  let layer = info[kCGWindowLayer as String] as? Int, layer > 0, layer < 1000,
                  (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            let cgRect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            // The converter picks the display by the rect's midpoint; mirror that to know how wide it is.
            let midpoint = CGPoint(x: cgRect.midX, y: cgRect.midY)
            let displayWidth = displays.first { $0.coreGraphicsBounds.contains(midpoint) }?.coreGraphicsBounds.width
            guard !cgRect.isEmpty, isObstacle(size: cgRect.size, displayWidth: displayWidth),
                  let rect = DisplayCoordinateConverter.appKitRect(fromCoreGraphicsRect: cgRect, displays: displays),
                  rect.intersects(region)
            else { return nil }
            return rect
        }
    }

    /// `CGWindowListCopyWindowInfo` reports bounds with a top-left origin; the converter flips them
    /// inside the display that owns them, which is what keeps a second monitor above or left of the
    /// main one from mirroring the rect.
    private static func displayGeometries() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayGeometry(
                appKitFrame: screen.frame, visibleFrame: screen.visibleFrame,
                coreGraphicsBounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)),
                backingScaleFactor: screen.backingScaleFactor
            )
        }
    }
}
