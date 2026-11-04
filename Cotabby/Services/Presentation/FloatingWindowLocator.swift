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
/// Only window bounds, level and owner are read, which needs no permission; window titles would
/// need Screen Recording and are never asked for.
@MainActor
enum FloatingWindowLocator {
    /// Windows farther than this from the anchor cannot be in the strip's way.
    static let searchMargin: CGFloat = 240
    /// Anything larger is a full-screen overlay (a screen recorder's frame, a notch utility), not a
    /// toolbar; stepping over it would push the strip off the selection entirely.
    static let maximumObstacleSize = CGSize(width: 900, height: 600)

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
            guard !cgRect.isEmpty, cgRect.width <= maximumObstacleSize.width, cgRect.height <= maximumObstacleSize.height,
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
