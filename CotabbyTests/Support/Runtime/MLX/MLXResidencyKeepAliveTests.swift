import XCTest
@testable import Cotabby

/// The keep-alive pings MLX once a second while suggestions are recent, and stays quiet otherwise.
final class MLXResidencyKeepAliveTests: XCTestCase {
    private let keepAlive = MLXResidencyKeepAlive(interval: 1, window: 180)

    func testPingsASecondAfterTheLastWork() {
        XCTAssertTrue(keepAlive.shouldPing(now: 101, lastWork: 100, lastPing: nil))
    }

    func testWorkWithinTheIntervalNeedsNoPing() {
        XCTAssertFalse(keepAlive.shouldPing(now: 100.5, lastWork: 100, lastPing: nil))
    }

    func testPingsAgainASecondAfterTheLastPing() {
        XCTAssertFalse(keepAlive.shouldPing(now: 110.5, lastWork: 100, lastPing: 110))
        XCTAssertTrue(keepAlive.shouldPing(now: 111, lastWork: 100, lastPing: 110))
    }

    func testStopsOnceTheWindowAfterTheLastWorkHasPassed() {
        XCTAssertTrue(keepAlive.shouldPing(now: 279, lastWork: 100, lastPing: 278))
        XCTAssertFalse(keepAlive.shouldPing(now: 281, lastWork: 100, lastPing: 279))
    }

    func testNeverPingsBeforeAnyWork() {
        XCTAssertFalse(keepAlive.shouldPing(now: 100, lastWork: nil, lastPing: nil))
    }
}
