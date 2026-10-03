import Foundation

/// File overview:
/// The machine conditions the performance tuner reacts to, as one plain value.
///
/// Why its own type: the signals come from four different places (the power source, Low Power
/// Mode, the thermal state, and the GPU's own statistics), each with its own notification shape.
/// `PerformanceConditionsMonitor` gathers them; everything downstream, the tuning policy, the logs
/// and the Performance pane, reads this one value, so they can never disagree about why Cotabby is
/// holding back.

/// The Mac's thermal state in Cotabby's own terms, so stored and logged values do not depend on
/// `ProcessInfo.ThermalState`'s raw integers.
enum ThermalLevel: String, Codable, Equatable, Sendable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

struct PerformanceConditions: Equatable, Sendable {
    /// One reason the Mac is under pressure. Several can hold at once; `pressures` lists them in
    /// the order the UI names them.
    enum Pressure: String, Equatable, Sendable {
        case battery
        case lowPowerMode
        case hot
        case gpuContended
    }

    var isOnBattery: Bool
    var isLowPowerMode: Bool
    var thermal: ThermalLevel
    /// The whole GPU's busy share across every app (0-100), or nil when it was not read.
    var deviceGPUBusyPercent: Double?

    /// Plugged in, cool, and an idle GPU: nothing to react to.
    static let unconstrained = PerformanceConditions(
        isOnBattery: false, isLowPowerMode: false, thermal: .nominal, deviceGPUBusyPercent: nil
    )

    /// Above this whole-GPU share another app (a game, a video export, a second model) is using the
    /// GPU hard, and a suggestion decode would compete with it for the same cores.
    static let gpuContentionPercent: Double = 85

    var pressures: [Pressure] {
        var result: [Pressure] = []
        if isOnBattery { result.append(.battery) }
        if isLowPowerMode { result.append(.lowPowerMode) }
        if thermal == .serious || thermal == .critical { result.append(.hot) }
        if let busy = deviceGPUBusyPercent, busy >= Self.gpuContentionPercent { result.append(.gpuContended) }
        return result
    }
}
