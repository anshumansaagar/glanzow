import Foundation

/// The 20-20-20 rule (every 20 minutes, look at something 20 feet away for 20 seconds), done
/// by watching rather than by clock: screen time only counts while the user faces a screen, a
/// natural 20-second look away resets it, and a due break completes once they've looked away
/// for 20 seconds in total — no button to press.
public struct EyeBreakTimer: Sendable, Equatable {
    public enum Event: Equatable, Sendable { case due, done }
    public enum State: Equatable, Sendable { case working, due(progress: Double) }

    public var workPeriod: TimeInterval = 20 * 60
    public var breakLength: TimeInterval = 20
    public private(set) var state = State.working
    public private(set) var screenTime: TimeInterval = 0
    private var awayRun: TimeInterval = 0
    private var awayInBreak: TimeInterval = 0
    private var last: TimeInterval?

    public init() {}

    /// Feed every few frames. `onScreen`: a face is seen and it faces one of the screens.
    public mutating func update(at t: TimeInterval, onScreen: Bool) -> Event? {
        defer { last = t }
        guard let last else { return nil }
        let dt = min(max(t - last, 0), 1) // gaps (camera off) count as at most a second
        if onScreen {
            awayRun = 0
            if case .working = state { screenTime += dt }
        } else {
            awayRun += dt
            if case .due = state { awayInBreak += dt }
        }
        switch state {
        case .working:
            if awayRun >= breakLength { screenTime = 0 } // took a break unprompted
            if screenTime >= workPeriod {
                state = .due(progress: 0)
                awayInBreak = 0
                return .due
            }
        case .due:
            let progress = min(awayInBreak / breakLength, 1)
            state = .due(progress: progress)
            if progress >= 1 {
                state = .working
                screenTime = 0
                return .done
            }
        }
        return nil
    }

    /// "Not now": ask again in five minutes.
    public mutating func snooze() {
        state = .working
        screenTime = max(workPeriod - 5 * 60, 0)
    }
}
