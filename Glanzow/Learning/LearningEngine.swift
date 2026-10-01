import Foundation

/// FR-LRN-01…03: clicks label the current pose with the display clicked on. Each one nudges that
/// display's model (weight 0.02, §6.6) and feeds a rolling agreement score over the last 50 clicks.
public struct LearningEngine: Sendable {
    public struct Update: Sendable {
        public var model: DisplayModel?
        /// Set once when more than 30% of the last 50 clicks disagreed with the classifier.
        public var driftAlert: Double?
    }

    public var window = 50
    public var alertAbove = 0.3
    public private(set) var outcomes: [Bool] = []
    private var latest: PoseSample?
    private var lastSwitch = -Double.infinity
    private var alerted = false

    public init() {}

    public mutating func observe(_ e: PoseEvent) {
        if case .pose(let s) = e { latest = s }
    }

    public mutating func noteSwitch(at t: TimeInterval) { lastSwitch = t }

    /// After recalibration the old score no longer means anything.
    public mutating func reset() {
        outcomes.removeAll()
        alerted = false
    }

    public mutating func click(at t: TimeInterval, on display: DisplayKey, classifier: MahalanobisClassifier, model: DisplayModel?) -> Update {
        var update = Update()
        // FR-LRN-01: only with a face seen right now; §6.6: never within 500 ms of our own switch.
        guard let s = latest, t - s.timestamp <= 0.25, t - lastSwitch >= 0.5 else { return update }

        outcomes.append(classifier.classify(s, current: nil) == .candidate(display))
        if outcomes.count > window { outcomes.removeFirst(outcomes.count - window) }
        let missRate = Double(outcomes.filter { !$0 }.count) / Double(outcomes.count)
        if outcomes.count == window, missRate > alertAbove, !alerted { // FR-LRN-03
            alerted = true
            update.driftAlert = missRate
        }

        // SPEC: §6.6 learns from every confident click. A click made while looking at another
        // screen (dragging across, say) would pull the model toward the wrong place, so only
        // poses within the off-screen threshold of the clicked display teach anything.
        if var m = model, let d = classifier.distances(s).first(where: { $0.key == display })?.distance, d <= classifier.rejectThreshold {
            m.learn(classifier.compensated(s)) // FR-LRN-02
            update.model = m
        }
        return update
    }
}
