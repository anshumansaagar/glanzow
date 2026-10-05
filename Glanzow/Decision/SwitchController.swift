import Foundation

/// One completed switch, for the event log (NFR-01, NFR-03) and the learning engine.
public struct SwitchRecord: Sendable {
    public var time: TimeInterval            // capture time of the frame that decided it
    public var pendingSince: TimeInterval    // when the target first won: the "settled" moment
    public var from: DisplayKey?
    public var to: DisplayKey
    public var outcome: FocusOutcome
    public var focusDuration: TimeInterval   // time spent raising and warping
    /// Set for a window or pane switch within one display (FR-P2).
    public var region: String? = nil
    /// The region that had focus before a within-screen switch, so it can be undone.
    public var fromRegion: String? = nil
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
        /// FR-P2: estimated gaze point on the current display, global coordinates.
        public var gaze: CGPoint?
        public var focusedRegion: String?
        public var pendingRegion: String?
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
    private var inFlight = false
    private var layout: ScreenLayout?
    private var regionPending: String?
    private var fixation = FixationDetector(dispersion: 150, duration: 0.45)
    private var gaze: CGPoint?
    private var lastSuccess: SwitchRecord?
    /// After an undo: don't go straight back to what was undone (a display key or region id).
    private var suppressed: (target: String, until: TimeInterval)?
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

    /// FR-P2: the current display's windows and panes, refreshed by the app.
    public func update(layout: ScreenLayout?) {
        if layout?.display != self.layout?.display { fixation.reset() }
        self.layout = layout
        if let id = regionPending, layout?.regions.contains(where: { $0.id == id }) != true { regionPending = nil }
    }

    public func setPaused(_ p: Bool) {
        paused = p
        if p { pending = nil }
    }

    /// The display holding the focused window, whoever focused it (user click, ⌘-Tab, us).
    public func setCurrent(_ key: DisplayKey?) {
        if key != current { fixation.reset() }
        current = key
    }

    public func snapshot() -> Snapshot {
        Snapshot(classification: latest, current: current, pending: pending, noFace: noFace, paused: paused,
                 typingGuard: tuning.typingPause.map { lastTime - input.lastKeystroke < $0 } ?? false,
                 mouseGuard: lastTime - input.lastMouseActivity < tuning.mouseQuiet, blockedBy: blockedBy,
                 gaze: gaze, focusedRegion: layout?.focused, pendingRegion: regionPending)
    }

    public func handle(_ e: PoseEvent) async {
        lastTime = e.timestamp
        switch e {
        case .noFace(let t):
            // SPEC: FR-CLS-04 says the candidate must win "continuously", so any frame without a
            // face restarts the dwell (and with it the 1 s typing override). Switches less than
            // carrying the dwell across short dropouts. FR-TRK-06's "No face" state still waits 1 s.
            pending = nil
            fixation.reset()
            if !noFace, t - lastFace >= tuning.noFaceTimeout { noFace = true }
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
                if let current {
                    await consider(current, at: s.timestamp)
                    await considerRegion(s)
                }
            case .candidate(let d):
                await consider(d, at: s.timestamp)
                if d == current {
                    await considerRegion(s)
                } else {
                    regionPending = nil
                    fixation.reset() // eyes on another screen: no fixation here
                }
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
        if let s = suppressed {
            if s.target == d && t < s.until { return }
            if s.target != d { suppressed = nil } // the gaze moved on: the undo has done its job
        }
        guard d != current, t - pendingSince >= tuning.dwell else { return } // FR-CLS-04
        if tuning.confirmMode { blockedBy = "waiting for confirm double-tap"; return } // FR-SAF-08
        await attempt(d, at: t, confirmed: false)
    }

    /// FR-P2-01…04: within the current display, move focus to the window or pane the user
    /// fixates. A fixation (I-DT) over the region dwell replaces "every sample inside", so one
    /// noisy sample can't restart the wait and the decision uses the averaged gaze point.
    private func considerRegion(_ s: PoseSample) async {
        let t = s.timestamp
        guard tuning.focusWithinScreen, !tuning.confirmMode, let cur = current, let layout, layout.display == cur,
              let g = classifier.gazePoint(s, on: cur) else {
            regionPending = nil
            gaze = nil
            fixation.reset()
            return
        }
        // A blink leaves the frame without an eye reading: skip it rather than mix in the cruder
        // head-only estimate, which would widen the fixation's spread.
        if classifier.expectsEyes(on: cur), s.pupilOffset == nil { return }
        let p = CGPoint(x: layout.bounds.minX + g.x * layout.bounds.width, y: layout.bounds.minY + g.y * layout.bounds.height)
        gaze = p
        fixation.duration = tuning.regionDwell
        fixation.dispersion = tuning.regionDispersion * layout.bounds.width
        guard let centre = fixation.add(p, at: t) else { return }
        let margin = tuning.regionMargin * layout.bounds.width
        let focusedRegion = layout.focusedRegion
        if let r = focusedRegion, r.frame.insetBy(dx: -margin, dy: -margin).contains(centre) { // hysteresis
            regionPending = nil
            return
        }
        guard let target = layout.region(at: centre, inset: margin / 2), target.id != layout.focused,
              // Looking at a pane's own window chrome (tab bar, title) keeps the pane.
              !(focusedRegion.map { !target.isPane && $0.windowID == target.windowID } ?? false) else {
            regionPending = nil
            return
        }
        if let s = suppressed {
            if s.target == target.id && t < s.until { return }
            if s.target != target.id { suppressed = nil }
        }
        regionPending = target.id
        guard t >= retryAfter, !inFlight else { return }
        if t - input.lastMouseActivity < tuning.mouseQuiet { blockedBy = "mouse"; return }
        // FR-P2-04: while typing, windows and panes stay put. No sustained-look override here.
        if let pause = tuning.typingPause, t - input.lastKeystroke < pause { blockedBy = "typing"; return }
        if let reason = await systemBlock() {
            blockedBy = reason
            retryAfter = t + 0.25
            return
        }
        guard !paused, regionPending == target.id, current == cur, self.layout?.focused != target.id, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let started = now()
        let outcome = await focus.focus(region: target)
        let record = SwitchRecord(time: t, pendingSince: t - tuning.regionDwell, from: cur, to: cur, outcome: outcome,
                                  focusDuration: now() - started, region: target.id, fromRegion: layout.focused)
        switch outcome {
        case .focusedWindow, .focusedPane, .pointerOnly:
            self.layout?.focused = target.id
            regionPending = nil
            blockedBy = nil
            fixation.reset() // the next move needs a fresh fixation
            lastSuccess = record
        case .skipped(let why):
            blockedBy = why
            retryAfter = t + 1
        }
        onSwitch?(record)
    }

    /// Undo the last switch (within 10 s): focus goes back to what it replaced, and the undone
    /// target is held off for 5 s or until the gaze moves elsewhere. Returns what was undone.
    public func undo(at t: TimeInterval) async -> SwitchRecord? {
        guard let last = lastSuccess, t - last.time < 10, !inFlight else { return nil }
        inFlight = true
        defer { inFlight = false }
        if let region = last.region {
            guard let back = last.fromRegion, let r = layout?.regions.first(where: { $0.id == back }) else { return nil }
            _ = await focus.focus(region: r)
            layout?.focused = back
            suppressed = (region, t + 5)
        } else {
            guard let from = last.from, from != last.to else { return nil }
            _ = await focus.focus(display: from)
            current = from
            suppressed = (last.to, t + 5)
        }
        pending = nil
        regionPending = nil
        fixation.reset()
        lastSuccess = nil
        return last
    }

    /// FR-SAF-08: the user double-tapped the confirm key while facing a display: switch now, no dwell or typing wait.
    public func confirm(at t: TimeInterval) async {
        guard !paused, !noFace, case .candidate(let d)? = latest, d != current else { return }
        if pending != d {
            pending = d
            pendingSince = t
        }
        await attempt(d, at: t, confirmed: true)
    }

    private func attempt(_ d: DisplayKey, at t: TimeInterval, confirmed: Bool) async {
        guard t >= retryAfter, !inFlight else { return }
        inFlight = true // a confirm and a frame must not both raise the window
        defer { inFlight = false }
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
        case .focusedWindow, .focusedPane, .pointerOnly:
            // If the user focused something else while we were raising, theirs wins.
            if current == from { current = d }
            blockedBy = nil
            lastSuccess = record
        case .skipped(let why):
            blockedBy = why
            retryAfter = t + 1 // don't hammer an unresponsive or excluded app every frame
        }
        onSwitch?(record)
    }
}
