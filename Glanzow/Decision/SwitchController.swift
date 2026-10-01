import Foundation

/// One completed switch, for the event log (NFR-01, NFR-03) and the learning engine.
public struct SwitchRecord: Sendable {
    public var time: TimeInterval            // capture time of the frame that decided it
    public var pendingSince: TimeInterval    // when the target first won: the "settled" moment
    public var from: DisplayKey?
    public var to: DisplayKey
    public var outcome: FocusOutcome
    public var focusDuration: TimeInterval   // time spent raising and warping
}

/// §6.4: turns per-frame classifications into focus changes, gated by dwell, the typing and
/// mouse guards, system UI and pause state. Time comes from the samples, never the wall clock,
/// so ReplayCLI and the tests drive it exactly like the camera does.
public actor SwitchController {
    public struct Snapshot: Sendable {
        public var classification: Classification?
        public var current: DisplayKey?
        public var pending: DisplayKey?
        public var noFace: Bool
        public var paused: Bool
        public var typingGuard: Bool
        public var mouseGuard: Bool
        public var blockedBy: String?
    }

    private var classifier: any DisplayClassifier
    private var tuning: Tuning
    private let focus: any FocusPerformer
    private let input: any InputMonitor
    private let systemBlock: @Sendable () async -> String?
    private var onSwitch: (@Sendable (SwitchRecord) -> Void)?

    public private(set) var current: DisplayKey?
    private var pending: DisplayKey?
    private var pendingSince = 0.0
    private var lastFace = -Double.infinity
    private var lastTime = 0.0
    private var noFace = true
    private var paused = true // the app un-pauses once permissions, camera and calibration are ready
    private var latest: Classification?
    private var retryAfter = -Double.infinity
    private var blockedBy: String?

    public init(classifier: any DisplayClassifier, tuning: Tuning, focus: any FocusPerformer, input: any InputMonitor,
                systemBlock: @escaping @Sendable () async -> String? = { nil }) {
        self.classifier = classifier
        self.tuning = tuning
        self.focus = focus
        self.input = input
        self.systemBlock = systemBlock
    }

    public func setOnSwitch(_ f: @escaping @Sendable (SwitchRecord) -> Void) { onSwitch = f }
    public func update(classifier: any DisplayClassifier) { self.classifier = classifier }
    public func update(tuning: Tuning) { self.tuning = tuning }

    public func setPaused(_ p: Bool) {
        paused = p
        if p { pending = nil }
    }

    /// The display holding the focused window, whoever focused it (user click, ⌘-Tab, us).
    public func setCurrent(_ key: DisplayKey?) { current = key }

    public func snapshot() -> Snapshot {
        Snapshot(classification: latest, current: current, pending: pending, noFace: noFace, paused: paused,
                 typingGuard: tuning.typingPause.map { lastTime - input.lastKeystroke < $0 } ?? false,
                 mouseGuard: lastTime - input.lastMouseActivity < tuning.mouseQuiet, blockedBy: blockedBy)
    }

    public func handle(_ e: PoseEvent) async {
        lastTime = e.timestamp
        switch e {
        case .noFace(let t):
            // FR-TRK-06: after 1 s without a face, forget any pending target. Shorter dropouts
            // (a blink, a hand) keep the dwell running.
            if !noFace, t - lastFace >= tuning.noFaceTimeout {
                noFace = true
                pending = nil
            }
        case .pose(let s):
            lastFace = s.timestamp
            noFace = false
            let c = classifier.classify(s, current: current)
            latest = c
            guard !paused else { return }
            switch c {
            case .offScreen:
                // SPEC: §6.3 says only "do nothing" for off-screen. A glance at the phone also
                // restarts the dwell, so a turn interrupted by looking away must settle again.
                pending = nil
            case .stay:
                if let current { await consider(current, at: s.timestamp) }
            case .candidate(let d):
                await consider(d, at: s.timestamp)
            }
        }
    }

    private func consider(_ d: DisplayKey, at t: TimeInterval) async {
        if d != pending {
            pending = d
            pendingSince = t
            blockedBy = nil
            return
        }
        guard d != current, t - pendingSince >= tuning.dwell else { return } // FR-CLS-04
        if tuning.confirmMode { blockedBy = "waiting for Fn double-tap"; return } // FR-SAF-08
        await attempt(d, at: t, confirmed: false)
    }

    /// FR-SAF-08: the user double-tapped Fn while facing a display: switch now, no dwell or typing wait.
    public func confirm(at t: TimeInterval) async {
        guard !paused, !noFace, case .candidate(let d)? = latest, d != current else { return }
        pending = d
        await attempt(d, at: t, confirmed: true)
    }

    private func attempt(_ d: DisplayKey, at t: TimeInterval, confirmed: Bool) async {
        guard t >= retryAfter else { return }
        if t - input.lastMouseActivity < tuning.mouseQuiet { blockedBy = "mouse"; return } // FR-SAF-02
        if !confirmed, let pause = tuning.typingPause, t - input.lastKeystroke < pause,
           t - pendingSince < tuning.typingOverride { // FR-SAF-01, with the 1 s sustained-turn override
            blockedBy = "typing"
            return
        }
        if let reason = await systemBlock() { // FR-SAF-06, 07, secure input
            blockedBy = reason
            retryAfter = t + 0.25
            return
        }
        // Actor reentrancy: state may have moved while we awaited.
        guard !paused, pending == d, current != d else { return }
        let from = current
        let started = now()
        let outcome = await focus.focus(display: d)
        let record = SwitchRecord(time: t, pendingSince: pendingSince, from: from, to: d, outcome: outcome,
                                  focusDuration: now() - started)
        switch outcome {
        case .focusedWindow, .pointerOnly:
            current = d
            blockedBy = nil
        case .skipped(let why):
            blockedBy = why
            retryAfter = t + 1 // don't hammer an unresponsive or excluded app every frame
        }
        onSwitch?(record)
    }
}
