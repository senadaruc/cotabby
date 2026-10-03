import Foundation

/// How hard Cotabby's performance tuner may hold back, chosen in Settings → Performance.
///
/// Every mode works inside the user's own settings: tuning can shorten suggestions below the chosen
/// word range, slow the reaction to typing, or skip screen text, but it never lengthens anything
/// and never writes to the saved settings. Turning the mode to Off restores exactly what Settings say.
enum PerformanceTuningMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    /// No tuning: every request uses the saved settings as they are.
    case off
    /// Fits suggestion length to each model's measured speed and to the lengths that get accepted,
    /// and pulls the battery levers when unplugged, in Low Power Mode, hot, or the GPU is contended.
    case balanced
    /// The battery levers all the time, with a tighter latency target.
    case batterySaver
    /// Leaves length alone and holds back only when the Mac is critically hot.
    case maxQuality

    static let `default`: PerformanceTuningMode = .balanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .balanced: return "Balanced"
        case .batterySaver: return "Battery Saver"
        case .maxQuality: return "Max Quality"
        }
    }

    var summary: String {
        switch self {
        case .off:
            return "Always use your settings exactly as they are."
        case .balanced:
            return "Fit length to each model's speed and what you accept; save energy on battery or when hot."
        case .batterySaver:
            return "Shorter suggestions, calmer typing reaction, and no screen text, all the time."
        case .maxQuality:
            return "Keep your length and context; hold back only when the Mac is critically hot."
        }
    }
}
