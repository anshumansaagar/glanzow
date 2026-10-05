import Foundation

/// Learns how long the user wants to look before focus moves, from what they do after switches:
/// an undo is a clear "too eager" (+40 ms); a bounce straight back that was never typed or clicked
/// into is a likely glance (+15 ms); a switch the user immediately used is a mild "fine" (−3 ms).
/// Bounded to 250–600 ms, so it can't drift anywhere strange. Bursts of three or more switches
/// within 10 s are deliberate scanning or testing, and teach nothing.
public struct SettleLearner: Sendable, Equatable {
    public static let range: ClosedRange<Double> = 0.25...0.6
    public private(set) var dwell: Double
    private var switches: [TimeInterval] = []

    public init(dwell: Double = 0.3) { self.dwell = min(max(dwell, Self.range.lowerBound), Self.range.upperBound) }

    public mutating func switched(at t: TimeInterval) {
        switches = switches.filter { t - $0 < 10 } + [t]
    }

    private func inBurst(_ t: TimeInterval) -> Bool { switches.filter { t - $0 < 10 }.count >= 3 }

    public mutating func undone() { nudge(+0.04) }
    public mutating func bounced(at t: TimeInterval) { if !inBurst(t) { nudge(+0.015) } }
    public mutating func used(at t: TimeInterval) { if !inBurst(t) { nudge(-0.003) } }

    private mutating func nudge(_ d: Double) { dwell = min(max(dwell + d, Self.range.lowerBound), Self.range.upperBound) }
}
