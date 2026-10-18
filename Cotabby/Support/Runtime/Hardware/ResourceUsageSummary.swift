import Foundation

/// File overview:
/// The menu bar popover's one-line "what is Cotabby using" readout. This file holds the pure value
/// and its text formatting; `MenuResourceMonitor` produces the values and `MenuBarView` shows the
/// string. Kept pure in `Support/` so every formatting branch is testable without a UI or a Mac.

/// CPU, memory and GPU use of Cotabby at one moment (MLX and llama.cpp both run in its process).
nonisolated struct ResourceUsageSummary: Equatable {
    let cpuPercent: Double
    let memoryBytes: UInt64
    /// `nil` when the GPU cannot be read, or on the first sample (no earlier reading to compare).
    let gpuPercent: Double?

    /// e.g. `Cotabby uses  CPU 34% · RAM 2.5 GB · GPU 12%`. Memory uses 1024-based units, like the
    /// Performance pane's byte formatter.
    static func menuLine(_ summary: ResourceUsageSummary) -> String {
        let cpu = "CPU \(Int(summary.cpuPercent.rounded()))%"
        let gpu = summary.gpuPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        return "Cotabby uses  \(cpu) · RAM \(memoryText(summary.memoryBytes)) · GPU \(gpu)"
    }

    static func memoryText(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes.rounded() < 1024 { return "\(Int(megabytes.rounded())) MB" }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

/// Builds `ResourceUsageSummary` values for the menu bar monitor. Owns what makes two periodic
/// samplers safe side by side: its own CPU baseline (so the Performance pane's sampling cannot reset
/// it) and its own GPU baseline. Used from the monitor's timer only.
nonisolated final class MenuResourceSampler {
    private let cpuBaseline = PreviousCPUReadings()
    private var gpuTracker = GPUShareTracker()

    /// Forget both baselines. Called when the popover closes so the next opening measures a fresh
    /// interval instead of averaging over the whole time the menu was closed.
    func reset() {
        cpuBaseline.withLock { $0.removeAll() }
        gpuTracker = GPUShareTracker()
    }

    /// `extraProcessID` is a helper process to count with Cotabby, if any.
    func sample(extraProcessID: Int32?) -> ResourceUsageSummary {
        sample(extraProcessIDs: extraProcessID.map { [$0] } ?? [])
    }

    /// `extraProcessIDs` are helper processes to count with Cotabby.
    func sample(extraProcessIDs: [Int32]) -> ResourceUsageSummary {
        let pids = [getpid()] + extraProcessIDs
        let resources = SystemResourceSampler.sample(extraProcessIDs: extraProcessIDs, baseline: cpuBaseline)
        let gpu = GPUStatisticsReader.read(pids: pids)
        let share = gpuTracker.update(pids: pids, nanoseconds: gpu.processGPUTimeNanoseconds, at: Date())
        return ResourceUsageSummary(
            cpuPercent: resources.cpuPercent,
            memoryBytes: resources.footprintBytes,
            gpuPercent: share
        )
    }
}
