import Foundation

/// File overview:
/// When `MLXRuntimeCore` sends MLX a tiny GPU job so the model stays resident between keystrokes.
/// Wiring the weights keeps them resident through about a second of idle; past roughly 2.5 s
/// without a job on MLX's command queue, the next prompt paid 136-220 ms to bring them back (31 ms
/// warm). A job a second keeps them resident, so a user who pauses to think still gets a fast
/// first word. The pings stop `window` seconds after the last suggestion, as llama.cpp's Metal
/// backend stops its residency requests after three idle minutes.
nonisolated struct MLXResidencyKeepAlive: Sendable {
    static let standard = MLXResidencyKeepAlive(interval: 1, window: 180)

    /// Seconds between jobs on the queue, a suggestion's own or a ping.
    let interval: TimeInterval
    /// Seconds after the last suggestion that pings continue.
    let window: TimeInterval

    /// Times are seconds on one monotonic clock; `lastWork` is when the last prompt was decoded.
    func shouldPing(now: TimeInterval, lastWork: TimeInterval?, lastPing: TimeInterval?) -> Bool {
        guard let lastWork, now - lastWork <= window else { return false }
        let lastJob = max(lastWork, lastPing ?? lastWork)
        return now - lastJob >= interval
    }
}
