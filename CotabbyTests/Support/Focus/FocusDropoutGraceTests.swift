import XCTest
@testable import Cotabby

/// Verifies the grace that keeps a live field through a host's brief "no focused field" read.
///
/// The reproduction is WhatsApp (and Safari, Teams) while typing: a single poll reports "No focused
/// Accessibility element" or "Missing text value" and the next one finds the same composer again,
/// usually 100-400 ms later. Publishing that read hid the ghost, cancelled the prediction, and
/// restarted screen capture as though the user had changed fields.
final class FocusDropoutGraceTests: XCTestCase {
    func test_sameAppDropoutAfterALiveFieldIsHeld() {
        var grace = FocusDropoutGrace()

        let decision = grace.evaluateDropout(published: supported(), captured: noField(), now: 10)

        XCTAssertEqual(decision, .hold)
        XCTAssertTrue(grace.isHolding)
    }

    func test_missingTextValueDropoutIsHeldToo() {
        var grace = FocusDropoutGrace()

        let decision = grace.evaluateDropout(
            published: supported(),
            captured: noField(reason: "Missing text value."),
            now: 10
        )

        XCTAssertEqual(decision, .hold)
    }

    func test_dropoutOutlastingTheWindowIsReleased() {
        var grace = FocusDropoutGrace()
        XCTAssertEqual(grace.evaluateDropout(published: supported(), captured: noField(), now: 10), .hold)
        XCTAssertEqual(grace.evaluateDropout(published: supported(), captured: noField(), now: 10.3), .hold)

        // The window is measured from the first missing read, not the latest one, so a field that
        // really went away is published once the window has passed however often it is polled.
        let decision = grace.evaluateDropout(
            published: supported(),
            captured: noField(),
            now: 10 + FocusDropoutGrace.window
        )

        XCTAssertEqual(decision, .release)
        XCTAssertFalse(grace.isHolding)
    }

    func test_fieldReturningEndsTheHoldSoTheNextDropoutGetsAFullWindow() {
        var grace = FocusDropoutGrace()
        _ = grace.evaluateDropout(published: supported(), captured: noField(), now: 10)
        grace.fieldObserved()

        XCTAssertFalse(grace.isHolding)
        XCTAssertEqual(grace.evaluateDropout(published: supported(), captured: noField(), now: 10.45), .hold)
        XCTAssertEqual(grace.evaluateDropout(published: supported(), captured: noField(), now: 10.8), .hold)
    }

    func test_dropoutInAnotherAppIsReleased() {
        var grace = FocusDropoutGrace()

        let decision = grace.evaluateDropout(
            published: supported(bundle: "net.whatsapp.WhatsApp"),
            captured: noField(bundle: "com.apple.finder"),
            now: 10
        )

        XCTAssertEqual(decision, .release)
    }

    func test_nothingIsHeldWhenNoFieldWasLive() {
        var grace = FocusDropoutGrace()
        let unsupportedField = FocusSnapshot(
            applicationName: "WhatsApp",
            bundleIdentifier: "net.whatsapp.WhatsApp",
            capability: .unsupported("Missing text value."),
            context: nil
        )

        XCTAssertEqual(grace.evaluateDropout(published: unsupportedField, captured: noField(), now: 10), .release)
    }

    func test_blockedCaptureIsNeverHeld() {
        // Blocked without a field is a deliberate state (the app was disabled, Cotabby itself took
        // focus, permission went away), not a host redraw, and must take effect at once.
        var grace = FocusDropoutGrace()
        let disabled = FocusSnapshot(
            applicationName: "WhatsApp",
            bundleIdentifier: "net.whatsapp.WhatsApp",
            capability: .blocked("Cotabby is disabled for this app."),
            context: nil
        )

        XCTAssertEqual(grace.evaluateDropout(published: supported(), captured: disabled, now: 10), .release)
    }

    func test_recentClickReleasesTheDropoutAtOnce() {
        // A click is how a user leaves the composer inside the same app (the chat list, the search
        // box). The ghost must not stay on screen for the grace window after it.
        var grace = FocusDropoutGrace()
        grace.notePointerDown(at: 10)

        XCTAssertEqual(grace.evaluateDropout(published: supported(), captured: noField(), now: 10.1), .release)
    }

    func test_clickDuringAHoldReleasesOnTheNextRead() {
        var grace = FocusDropoutGrace()
        XCTAssertEqual(grace.evaluateDropout(published: supported(), captured: noField(), now: 10), .hold)
        grace.notePointerDown(at: 10.05)

        XCTAssertEqual(grace.evaluateDropout(published: supported(), captured: noField(), now: 10.1), .release)
        XCTAssertFalse(grace.isHolding)
    }

    func test_oldClickDoesNotPreventAHold() {
        var grace = FocusDropoutGrace()
        grace.notePointerDown(at: 10)

        XCTAssertEqual(
            grace.evaluateDropout(published: supported(), captured: noField(), now: 10 + FocusDropoutGrace.window),
            .hold
        )
    }

    // MARK: - Fixtures

    private func supported(bundle: String = "net.whatsapp.WhatsApp") -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "WhatsApp",
            bundleIdentifier: bundle,
            capability: .supported,
            context: CotabbyTestFixtures.focusedInputSnapshot(applicationName: "WhatsApp", bundleIdentifier: bundle)
        )
    }

    private func noField(
        bundle: String = "net.whatsapp.WhatsApp",
        reason: String = "No focused Accessibility element."
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "WhatsApp",
            bundleIdentifier: bundle,
            capability: .unsupported(reason),
            context: nil
        )
    }
}
