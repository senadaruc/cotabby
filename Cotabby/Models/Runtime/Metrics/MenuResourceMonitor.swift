import Combine
import Foundation

/// File overview:
/// Publishes `ResourceUsageSummary` for the menu bar popover. Unlike `SystemMetricsStore` it keeps
/// no history: it holds only the latest value and polls only between `start()` and `stop()`, which
/// the popover calls from `.onAppear` / `.onDisappear`, so a closed menu costs nothing. One instance
/// lives for the app's lifetime (built by `CotabbyAppEnvironment`).
@MainActor
final class MenuResourceMonitor: ObservableObject {
    nonisolated static let defaultInterval: TimeInterval = 2.0

    @Published private(set) var summary: ResourceUsageSummary?

    private let interval: TimeInterval
    private let sample: () -> ResourceUsageSummary
    private let onStop: () -> Void
    private var timer: Timer?

    init(
        interval: TimeInterval = MenuResourceMonitor.defaultInterval,
        sample: @escaping () -> ResourceUsageSummary,
        onStop: @escaping () -> Void = {}
    ) {
        self.interval = interval
        self.sample = sample
        self.onStop = onStop
    }

    nonisolated deinit {
        // Same reasoning as `SystemMetricsStore`: no cleanup from a nonisolated deinit; the timer
        // holds `self` weakly and invalidates itself on its first tick after we are gone.
    }

    /// Takes a reading now (so the popover is not empty for a full interval) and starts the timer.
    func start() {
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] fired in
            guard let self else {
                fired.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onStop()
    }

    /// One reading. Internal so tests can drive it without waiting for a real timer.
    func tick() {
        summary = sample()
    }

    var isRunning: Bool { timer != nil }
}
