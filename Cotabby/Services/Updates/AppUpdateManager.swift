import AppKit
import Foundation
import Logging
import Sparkle

/// File overview:
/// Owns Cotabby's Sparkle integration and keeps updater lifecycle out of SwiftUI views.
/// This is a classic service-layer boundary in the app's architecture: Sparkle is a side-effectful
/// framework that talks to the network, persists updater preferences, and may present system UI.
///
/// We keep it in `Services/` so the rest of the app only depends on a tiny, explicit surface:
/// `start()` for lifecycle wiring and `checkForUpdates()` for a future settings screen.
@MainActor
final class AppUpdateManager {
    /// The updater is created once and retained for the lifetime of the process, just like the
    /// runtime manager and the focus tracker. Sparkle expects its controller to stay alive.
    private let updaterController: SPUStandardUpdaterController

    private var isStarted = false
    /// Why the updater did not start, for the manual check to show instead of doing nothing.
    private var disabledReason = "The updater has not started yet."

    /// Sparkle persists this setting in user defaults, which take precedence over the value in
    /// `CotabbyInfo.plist`. Reapplying the product policy repairs older installs that may have saved
    /// a shorter development interval while the plist still gives fresh installs the same default.
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private static let debugCheckForUpdatesOnLaunchArgument = "-Cotabby-check-for-updates-on-launch"
    private static let publicKeyPlaceholder = "REPLACE_WITH_GENERATED_SPARKLE_PUBLIC_ED_KEY"

    init() {
        // `startingUpdater: false` keeps lifecycle explicit. The app delegate decides when the
        // updater starts instead of Sparkle implicitly doing work during dependency construction.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Starts Sparkle exactly once after app launch.
    /// We validate the minimal required Info.plist settings first so a development build with the
    /// placeholder public key does not trigger Sparkle's "app is misconfigured" alert.
    func start() {
        guard !isStarted else {
            return
        }

        guard Self.isUpdaterEnabledForThisBuild else {
            // Dev builds carry a distinct bundle identifier (`com.jacobfu.tabby.dev`) so they hold
            // their own Accessibility/TCC grant, independent of the released app. Sparkle must never
            // follow the official feed here: it points at the Developer ID-signed release, and
            // installing it would swap that bundle in over the dev app, collapsing the separate
            // identity this build exists to preserve. A fork's own feed is allowed (see below).
            log("Sparkle disabled for dev build (no feed of its own).")
            disabledReason = "This is a development build without an update feed, so it does not update itself. "
                + "Builds published as releases of a fork (scripts/publish_fork_release.sh) or built with "
                + "COTABBY_DEV_UPDATE_FEED_URL set update from that fork."
            return
        }

        guard hasUsableConfiguration else {
            log("Sparkle not started because updater configuration is incomplete.")
            disabledReason = "This build's update feed or signing key is missing, so it cannot check for updates."
            return
        }

        // Configure the interval before starting so Sparkle's first scheduling decision uses the
        // daily cadence together with its persisted last-check date.
        let updater = updaterController.updater
        updater.updateCheckInterval = Self.automaticCheckInterval
        updaterController.startUpdater()
        isStarted = true
        log("Sparkle updater started.")

        // Catch up immediately when the app returns after the daily interval. Recent launches leave
        // the check to Sparkle's scheduler, so reopening Cotabby cannot bypass the daily cadence.
        let shouldCatchUp = updater.lastUpdateCheckDate
            .map { Date().timeIntervalSince($0) >= Self.automaticCheckInterval } ?? true
        if shouldCatchUp {
            updater.checkForUpdatesInBackground()
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.debugCheckForUpdatesOnLaunchArgument) {
            log("Debug launch argument requested an immediate update check.")
            checkForUpdates()
        }
        #endif
    }

    /// Future UI surfaces, such as Settings, should call this method instead of touching Sparkle
    /// directly. That keeps the rest of the codebase decoupled from Sparkle APIs.
    func checkForUpdates() {
        guard isStarted else {
            // Say why, rather than a menu item that silently does nothing.
            log("Manual update check while the updater is off.")
            let alert = NSAlert()
            alert.messageText = "Updates are off in this build"
            alert.informativeText = disabledReason
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Releases")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(ProjectLinks.repository.appendingPathComponent("releases"))
            }
            return
        }

        updaterController.checkForUpdates(nil)
    }

    /// Whether Sparkle should run for this build. Compiled out to `false` in the dev configuration
    /// (the `COTABBY_DEV` flag), which ships under a distinct bundle identifier that the prod appcast
    /// must never replace. Released builds resolve to `true` and follow the normal update path.
    ///
    /// The one exception in dev: a build given its own feed (a fork publishing its builds as GitHub
    /// releases, `scripts/publish_fork_release.sh`) updates from that feed. Those releases are dev
    /// builds themselves, so the identity stays separate; the official feed is still refused.
    private static var isUpdaterEnabledForThisBuild: Bool {
        #if COTABBY_DEV
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let host = URL(string: feed.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return !host.isEmpty && host != officialFeedHost && !host.hasSuffix("." + officialFeedHost)
        #else
        true
        #endif
    }

    /// The official appcast's domain; a dev build never updates from it.
    private static let officialFeedHost = "cotabby.app"

    private var hasUsableConfiguration: Bool {
        guard let feedURLString = configuredString(forInfoDictionaryKey: "SUFeedURL"),
              URL(string: feedURLString) != nil
        else {
            log("Missing or invalid SUFeedURL.")
            return false
        }

        guard let publicKey = configuredString(forInfoDictionaryKey: "SUPublicEDKey"),
              publicKey != Self.publicKeyPlaceholder
        else {
            log("SUPublicEDKey is missing or still using the placeholder value.")
            return false
        }

        return true
    }

    private func configuredString(forInfoDictionaryKey key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func log(_ message: String) {
        CotabbyLogger.updates.info("\(message)")
    }
}
