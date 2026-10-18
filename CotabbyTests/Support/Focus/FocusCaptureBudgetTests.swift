import XCTest
@testable import Cotabby

final class FocusCaptureBudgetTests: XCTestCase {
    func test_aFastAppIsReadAgainAlmostAtOnce() {
        // TextEdit answers a full read in about 2 ms: the budget must not slow it down.
        var budget = FocusCaptureBudget()
        budget.record(processIdentifier: 10, costMs: 2, endedAtMs: 1_000)
        XCTAssertFalse(budget.allowsCapture(processIdentifier: 10, atMs: 1_004))
        XCTAssertTrue(budget.allowsCapture(processIdentifier: 10, atMs: 1_006))
    }

    func test_aSlowAppGetsAtMostAQuarterOfItsMainThread() {
        // WhatsApp took 30-98 ms a read; back-to-back reads held its main thread over half the time
        // while the user typed, and typing and deleting lagged in WhatsApp itself.
        var budget = FocusCaptureBudget()
        budget.record(processIdentifier: 20, costMs: 30, endedAtMs: 1_000)
        XCTAssertFalse(budget.allowsCapture(processIdentifier: 20, atMs: 1_050))
        XCTAssertTrue(budget.allowsCapture(processIdentifier: 20, atMs: 1_090))
    }

    func test_anotherAppIsReadAtOnce() {
        var budget = FocusCaptureBudget()
        budget.record(processIdentifier: 20, costMs: 80, endedAtMs: 1_000)
        XCTAssertTrue(budget.allowsCapture(processIdentifier: 30, atMs: 1_001))
        XCTAssertTrue(budget.allowsCapture(processIdentifier: nil, atMs: 1_001))
    }

    func test_theCostIsARunningAverageThatRestartsForANewApp() {
        var budget = FocusCaptureBudget()
        budget.record(processIdentifier: 20, costMs: 30, endedAtMs: 0)
        budget.record(processIdentifier: 20, costMs: 130, endedAtMs: 0)
        XCTAssertEqual(budget.averageCostMs, 60, accuracy: 0.001)
        budget.record(processIdentifier: 30, costMs: 2, endedAtMs: 0)
        XCTAssertEqual(budget.averageCostMs, 2, accuracy: 0.001)
    }
}
