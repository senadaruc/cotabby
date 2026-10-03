import Combine
import Foundation

/// File overview:
/// Gathers the machine conditions the performance tuner reacts to into one published
/// `PerformanceConditions` value: AC or battery, Low Power Mode, the thermal state, and how busy the
/// whole GPU is.
///
/// Why its own service: each signal arrives differently (two existing monitors, a ProcessInfo
/// notification, and an IOKit registry read with no notification at all), and the tuner, the
/// router's Recent Requests entries and the Performance pane all need the same answer. Built once
/// by `CotabbyAppEnvironment`, which owns it for the process lifetime.
///
/// The GPU read has no change notification and is not free (it walks the accelerator's registry
/// children), so it is never polled on a timer: `currentConditions(sampleGPU:)` refreshes it when a
/// request asks and the last reading is older than `gpuSampleInterval`. With tuning off, nothing
/// asks, and the GPU is never read.
@MainActor
final class PerformanceConditionsMonitor: ObservableObject {
    @Published private(set) var conditions: PerformanceConditions

    static let gpuSampleInterval: TimeInterval = 5

    private let readDeviceGPUPercent: () -> Double?
    private let now: () -> Date
    private var lastGPUSampleAt: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var thermalObserver: NSObjectProtocol?

    init(
        powerSourceMonitor: PowerSourceMonitor,
        lowPowerModeMonitor: LowPowerModeMonitor,
        readDeviceGPUPercent: @escaping () -> Double? = { GPUStatisticsReader.read().deviceUtilizationPercent },
        now: @escaping () -> Date = Date.init
    ) {
        self.readDeviceGPUPercent = readDeviceGPUPercent
        self.now = now
        conditions = PerformanceConditions(
            isOnBattery: !powerSourceMonitor.isPluggedIn,
            isLowPowerMode: lowPowerModeMonitor.isLowPowerModeEnabled,
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            deviceGPUBusyPercent: nil
        )

        // `@Published` emits its current value on subscribe; the assignments are idempotent.
        powerSourceMonitor.$isPluggedIn
            .removeDuplicates()
            .sink { [weak self] isPluggedIn in self?.update { $0.isOnBattery = !isPluggedIn } }
            .store(in: &cancellables)
        lowPowerModeMonitor.$isLowPowerModeEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.update { $0.isLowPowerMode = enabled } }
            .store(in: &cancellables)

        // ProcessInfo posts thermal changes on an unspecified queue; hop to the main queue so the
        // published value is only ever mutated on the main actor.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.update { $0.thermal = ThermalLevel(ProcessInfo.processInfo.thermalState) }
            }
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    /// The conditions for a request being built now. With `sampleGPU`, a GPU reading older than
    /// `gpuSampleInterval` is refreshed first; without it the last reading (or none) is kept.
    func currentConditions(sampleGPU: Bool) -> PerformanceConditions {
        if sampleGPU {
            let time = now()
            if lastGPUSampleAt.map({ time.timeIntervalSince($0) >= Self.gpuSampleInterval }) ?? true {
                lastGPUSampleAt = time
                let busy = readDeviceGPUPercent()
                update { $0.deviceGPUBusyPercent = busy }
            }
        }
        return conditions
    }

    private func update(_ change: (inout PerformanceConditions) -> Void) {
        var next = conditions
        change(&next)
        guard next != conditions else { return }
        conditions = next
    }
}
