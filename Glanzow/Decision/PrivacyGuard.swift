import Foundation

/// Veils the screens while someone besides the user watches them: a second face looking toward
/// the screens for 2 s raises the veil; it lifts 1.5 s after they've gone, or at once when the
/// user dismisses it — and then stays down for that person until they leave and come back.
public struct PrivacyGuard: Sendable, Equatable {
    public var onset: TimeInterval = 2
    public var release: TimeInterval = 1.5
    public private(set) var veiled = false
    private var watchingSince: TimeInterval?
    private var goneSince: TimeInterval?
    private var dismissed = false

    public init() {}

    /// Returns true when the veil should change state (read `veiled` for which way).
    public mutating func update(at t: TimeInterval, watchers: Int) -> Bool {
        let before = veiled
        if watchers > 0 {
            goneSince = nil
            if watchingSince == nil { watchingSince = t }
            if !dismissed, let since = watchingSince, t - since >= onset { veiled = true }
        } else {
            watchingSince = nil
            if goneSince == nil { goneSince = t }
            if let gone = goneSince, t - gone >= release {
                veiled = false
                dismissed = false // they left: the next watcher counts again
            }
        }
        return veiled != before
    }

    /// The user said it's fine (any key or click): lift now, and not again for this watcher.
    public mutating func dismiss() {
        veiled = false
        dismissed = true
    }
}
