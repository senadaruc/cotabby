import XCTest
@testable import Cotabby

/// Start/stop behavior of the menu bar monitor, driven through `tick()` so no timer has to fire.
/// Instances are kept alive for the process (same isolated-deinit quarantine as the other
/// MainActor stores' tests).
final class MenuResourceMonitorTests: XCTestCase {
    @MainActor private static var retained: [MenuResourceMonitor] = []

    @MainActor
    private func makeMonitor(mlx: Bool = false, stops: StopCounter = StopCounter()) -> (MenuResourceMonitor, StopCounter) {
        var calls = 0
        let monitor = MenuResourceMonitor(
            interval: 3600,
            sample: {
                calls += 1
                return ResourceUsageSummary(
                    cpuPercent: Double(calls), memoryBytes: 1, gpuPercent: nil, includesMLXServer: mlx)
            },
            onStop: { stops.count += 1 }
        )
        Self.retained.append(monitor)
        return (monitor, stops)
    }

    final class StopCounter { var count = 0 }

    @MainActor
    func testStartPublishesImmediatelyAndTickUpdates() {
        let (monitor, _) = makeMonitor()
        XCTAssertNil(monitor.summary)
        monitor.start()
        XCTAssertEqual(monitor.summary?.cpuPercent, 1)
        monitor.tick()
        XCTAssertEqual(monitor.summary?.cpuPercent, 2)
        monitor.stop()
    }

    @MainActor
    func testStopEndsTimerAndNotifies() {
        let (monitor, stops) = makeMonitor()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(stops.count, 1)
    }

    @MainActor
    func testStartTwiceDoesNotResample() {
        let (monitor, _) = makeMonitor()
        monitor.start()
        monitor.start()
        XCTAssertEqual(monitor.summary?.cpuPercent, 1)
        monitor.stop()
    }

    @MainActor
    func testMLXFlagPassesThrough() {
        let (monitor, _) = makeMonitor(mlx: true)
        monitor.tick()
        XCTAssertEqual(monitor.summary?.includesMLXServer, true)
    }
}
