import AppKit
import Carbon
import ApplicationServices
import AVFoundation
import ServiceManagement
import SwiftUI
import GlanzowKit

/// Owns every module, wires the pipeline together, and turns permission, pause, camera and
/// calibration state into one menu bar status.
@MainActor final class AppModel: ObservableObject {
    enum Status: Equatable {
        case active, paused, pausedBySystem, resting, noFace, needsPermission, needsCalibration, noCamera, cameraBusy, calibrating

        var title: String {
            switch self {
            case .active: "Following you"
            case .paused: "Holding — focus stays where it is"
            case .pausedBySystem: "Holding while your Mac is locked"
            case .resting: "Resting — camera off until you're back"
            case .noFace: "Can't see you right now"
            case .needsPermission: "Needs your permission"
            case .needsCalibration: "Needs to learn your screens"
            case .noCamera: "No camera available"
            case .cameraBusy: "Camera busy — trying again"
            case .calibrating: "Learning your screens"
            }
        }

        /// One or two words, for the panel's status pill.
        var short: String {
            switch self {
            case .active: "Following"
            case .paused, .pausedBySystem: "Holding"
            case .resting: "Resting"
            case .noFace: "Can't see you"
            case .needsPermission, .needsCalibration, .noCamera, .cameraBusy: "Needs you"
            case .calibrating: "Learning"
            }
        }

        var glyph: Glyph.Style {
            switch self {
            case .active: .following
            case .paused, .pausedBySystem, .resting: .holding
            case .noFace: .faint
            case .needsPermission, .needsCalibration, .noCamera, .cameraBusy: .attention
            case .calibrating: .learning
            }
        }

        var tint: Color {
            switch self {
            case .active: .green
            case .needsPermission, .needsCalibration, .noCamera, .cameraBusy: .orange
            default: .secondary
            }
        }

        var symbol: String {
            switch self {
            case .active: "eye"
            case .paused, .pausedBySystem: "pause.circle"
            case .resting: "moon"
            case .noFace: "eye.slash"
            case .needsPermission: "exclamationmark.triangle"
            case .needsCalibration, .calibrating: "scope"
            case .noCamera, .cameraBusy: "video.slash"
            }
        }
    }

    @Published private(set) var status: Status = .needsPermission
    @Published private(set) var cameraAuthorized = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var axTrusted = false
    @Published private(set) var inputOK = true
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var userPaused = false { didSet { reconcile() } }
    @Published private(set) var cameraState = CameraCapture.State.stopped
    @Published private(set) var faceVisible = false
    @Published private(set) var isRecording = false
    @Published private(set) var calibrating = false
    @Published private(set) var uncalibrated: [DisplayInfo] = []
    /// What the live view shows: the screen being looked at and, within it, the gaze point.
    struct Live: Equatable {
        var display: DisplayKey?
        var gaze: CGPoint?
    }
    @Published private(set) var live = Live()
    @Published private(set) var todayLine = ""
    private var liveTimer: Timer?
    /// FR-CAL-07: displays are changing; the old map can't be trusted until it is rebuilt.
    private var reconfiguring = false { didSet { reconcile() } }

    let defaults = UserDefaults.standard
    let registry = DisplayRegistry.shared
    let tracker = PoseTracker()
    let store = CalibrationStore()
    private(set) var classifier = MahalanobisClassifier(models: [])
    private var promptedFor: Set<DisplayKey> = []
    lazy var camera = CameraCapture(tracker: tracker)
    let input = EventTapInputMonitor()
    let windows = WindowTracker(displays: .shared)
    private(set) lazy var focusManager = FocusManager(windows: windows, displays: registry, input: input)
    private(set) lazy var controller = SwitchController(
        classifier: classifier, tuning: Tuning(defaults), focus: focusManager, input: input,
        systemBlock: { [focusManager] in await focusManager.blockingReason() })
    private let feedback = FocusFeedback()
    private lazy var notifier = Notifier() // lazy: UNUserNotificationCenter needs a real .app bundle
    private var hotkey: Hotkey?
    private var undoHotkey: Hotkey?
    private lazy var settle = SettleLearner(dwell: Tuning(defaults).dwell)
    private var previousSwitch: SwitchRecord?
    private var lastClickAt = -Double.infinity
    private var hotkeySetting: (code: Int, modifiers: Int)?
    private var undoHotkeySetting: (code: Int, modifiers: Int)?
    /// FR-SAF-04: lock, sleep, screensaver, fast user switching. Any reason stops the camera.
    private var systemPauses: Set<String> = [] { didSet { reconcile() } }
    private let eventLog = EventLog()
    private let recorder = PoseRecorder()
    private let log = logger("app")
    private var menu: MenuBarController?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsShowsDebug = false
    private var debugOverlay: DebugOverlay?
    private var permissionPoll: Timer?
    private var cameraWanted = false
    private var switchingEnabled = true // first reconcile pushes the real value
    private var monitorsStarted = false
    private var callbacksWired = false
    private var lastSwitchAt = -Double.infinity
    private var snapshot: SwitchController.Snapshot?
    private var layoutPoke: AsyncStream<Void>.Continuation?
    private var eyesNeeded = false
    private var perfTimer: Timer?
    private var learning = LearningEngine()
    private var eyeBreak = EyeBreakTimer()
    private let eyePill = EyeBreakPill()
    private var privacy = PrivacyGuard()
    private let veil = PrivacyVeil()
    private var clicksSinceRefit: [DisplayKey: Int] = [:]
    private var governor = FrameRateGovernor()
    private var saveScheduled = false
    private var preferredCamera: String?
    private var lastSample: PoseSample?
    private var lastFaceTime = -Double.infinity
    private var tasks: [Task<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []

    var cameraID: String {
        if case .running(let id, _) = cameraState { return id }
        return ""
    }

    init() {
        Pref.register()
        Paths.tightenAppSupport()
    }

    #if DEBUG
    func preview(displays list: [DisplayInfo]) { displays = list }
    func previewLive() {
        live = Live(display: displays.first?.key, gaze: displays.first.map { CGPoint(x: $0.bounds.midX + 300, y: $0.bounds.midY - 120) })
        status = .active
        todayLine = "Today: 128 switches, 2 undone"
    }
    #endif

    func start() {
        registry.start()
        displays = registry.displays
        registry.onChange = { [weak self] list in self?.displaysChanged(list) }
        registry.onChangeBegan = { [weak self] in self?.reconfiguring = true }
        menu = MenuBarController(model: self)
        camera.onState = { [weak self] s in self?.cameraChanged(s) }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        // A permission granted in System Settings is noticed when the user comes back.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        })
        let poses = tracker.events()
        tasks.append(Task { [weak self] in
            for await e in poses { self?.handlePose(e) }
        })
        // The hot path: frames → decisions, off the main thread.
        let decisions = tracker.events()
        let controller = controller
        tasks.append(Task.detached {
            for await e in decisions { await controller.handle(e) }
        })
        wireCallbacks()
        startLayoutLoop()
        startPerfReports()
        startLockWatchdog()
        observeSystem()
        hotkey = Hotkey { [weak self] in self?.userPaused.toggle() }
        undoHotkey = Hotkey { [weak self] in self?.undoSwitch() }
        notifier.onExclude = { [weak self] bundle in self?.exclude(bundle) }
        if defaults.bool(forKey: Pref.onboardingDone) { notifier.requestPermission() }
        applySettings()
        refreshPermissions()
        if !defaults.bool(forKey: Pref.onboardingDone) { showOnboarding() }
        reconcile()
    }

    func shutdown() {
        store.save()
        camera.stop()
        tasks.forEach { $0.cancel() }
    }

    private func wireCallbacks() {
        let controller = controller, focusManager = focusManager, windows = windows
        Task { [weak self] in
            guard self != nil else { return }
            defer {
                // Window tracking starts only now, so its first focus report finds the callbacks.
                self?.callbacksWired = true
                self?.startMonitors()
            }
            await controller.setOnSwitch { [weak self] r in Task { @MainActor in self?.didSwitch(r) } }
            await focusManager.setCallbacks(
                onFocused: { [weak self] rect, area in Task { @MainActor in self?.focused(rect, area: area) } },
                onAXDisabled: { [weak self] in Task { @MainActor in self?.accessibilityLost() } })
            await windows.setCallbacks(
                onFocus: { [weak self] key, ref in
                    Task { @MainActor in self?.layoutPoke?.yield(()) }
                    // A window-less app keeps the last display as current (switch less).
                    if let key { Task { await controller.setCurrent(key) } }
                    let frame = ref?.frame
                    Task { @MainActor in self?.focusChanged(key, frame) }
                },
                onAXDisabled: { [weak self] in Task { @MainActor in self?.accessibilityLost() } })
        }
        input.onClick = { [weak self] click in self?.clicked(click) }
        input.onConfirm = { t in Task { await controller.confirm(at: t) } }
        input.onActivity = { [weak self, recorder] kind, t in
            recorder.record(kind, at: t)
            guard let self else { return }
            if self.resting { self.setSystemPause("away", false) } // a key or the mouse: someone's back
            if self.veil.isShown { // the user says it's fine
                self.privacy.dismiss()
                self.veil.hide()
            }
        }
        eyePill.onLater = { [weak self] in
            self?.eyeBreak.snooze()
            self?.eyePill.hide()
        }
        // A warp (the pointer coming along with a switch) otherwise mutes the mouse for 0.25 s.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
    }

    /// FR-P2: keeps the controller's picture of the current display's windows and panes fresh.
    /// Rebuilt on every focus change and switch, and at least once a second, at most 4 times a second.
    private func startLayoutLoop() {
        let (pokes, poke) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        layoutPoke = poke
        let controller = controller, focusManager = focusManager, store = store
        tasks.append(Task.detached { [weak self] in
            for await _ in pokes {
                let d = UserDefaults.standard
                var layout: ScreenLayout?
                // Only screens with a gaze map can focus within themselves; skip the AX work elsewhere.
                if d.bool(forKey: Pref.focusWithinScreen), let current = await controller.current, store.model(current)?.gaze != nil {
                    layout = await focusManager.layout(for: current, panes: d.bool(forKey: Pref.focusPanes))
                }
                await controller.update(layout: layout)
                // Eye landmarks cost CPU; they only matter with two or more windows or panes to choose from.
                let worthIt = (layout?.regions.count ?? 0) >= 2
                await self?.setEyesNeeded(worthIt)
                try? await Task.sleep(for: .milliseconds(250))
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                // Focus and window changes poke at once; this only catches windows moved silently.
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if self.switchingEnabled { self.layoutPoke?.yield(()) }
            }
        })
    }

    private func setEyesNeeded(_ needed: Bool) {
        guard needed != eyesNeeded else { return }
        eyesNeeded = needed
        applySettings()
    }

    /// Once a minute while the camera runs: where the time goes (PerfMeter), into the switch log.
    private func startPerfReports() {
        perfTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var fields = PerfMeter.shared.report()
                guard case .running = self.cameraState else { return }
                fields["eyes"] = self.eyesNeeded
                self.eventLog.append("perf", fields)
            }
        }
    }

    /// Window tracking and the input tap need Accessibility; start them once it is granted.
    private func startMonitors() {
        guard axTrusted, callbacksWired else { return }
        if !monitorsStarted {
            monitorsStarted = true
            windows.start()
        }
        if !input.isRunning {
            inputOK = input.start()
            if !inputOK { log.error("event tap unavailable; Input Monitoring needed") }
        }
    }

    // MARK: State

    /// Brings the camera and status in line with permissions, pauses and calibration.
    private func reconcile() {
        let wantCamera = cameraAuthorized && !userPaused && systemPauses.isEmpty
            && (defaults.bool(forKey: Pref.onboardingDone) || calibrating)
        if wantCamera != cameraWanted {
            cameraWanted = wantCamera
            if wantCamera { camera.start(preferredID: preferredCamera) } else { camera.stop() }
        }
        let running: Bool = { if case .running = cameraState { return true }; return false }()
        // SPEC: FR-CAL-07 says pause and prompt. Switching stays off until every connected display
        // is calibrated: looking at an unknown display would otherwise read as its neighbour.
        let wantSwitching = cameraWanted && running && permissionsGranted && !calibrating && !reconfiguring && uncalibrated.isEmpty
            && !classifier.keys.isEmpty && defaults.bool(forKey: Pref.onboardingDone)
        if wantSwitching != switchingEnabled {
            switchingEnabled = wantSwitching
            log.info("switching \(wantSwitching ? "on" : "off", privacy: .public)")
            Task { await controller.setPaused(!switchingEnabled) } // reads the latest value when it runs
        }
        status = computeStatus()
    }

    private func computeStatus() -> Status {
        if !cameraAuthorized || !permissionsGranted { return .needsPermission }
        if userPaused { return .paused }
        if systemPauses == ["away"] { return .resting }
        if !systemPauses.isEmpty { return .pausedBySystem }
        if calibrating { return .calibrating }
        if cameraState == .noCamera { return .noCamera }
        if cameraState == .busy { return .cameraBusy }
        if !uncalibrated.isEmpty { return .needsCalibration }
        if !faceVisible { return .noFace }
        return .active
    }

    private func cameraChanged(_ s: CameraCapture.State) {
        log.info("camera state \(String(describing: s), privacy: .public)")
        cameraState = s
        if case .running = s {} else { setFaceVisible(false) }
        switch s { // §7: tell the user once per episode
        case .noCamera:
            notifier.once("noCamera", title: "Glanzow has no camera",
                          body: "The built-in camera is off (lid closed?) and no other camera is connected. Glanzow resumes when a camera appears.")
        case .busy:
            notifier.once("cameraBusy", title: "Camera unavailable",
                          body: "Another app may be using the camera. Glanzow is paused and retries every 10 seconds.")
        case .running:
            notifier.forget("noCamera")
            notifier.forget("cameraBusy")
        case .stopped: break
        }
        rebuildModels()
        reconcile()
        promptIfUncalibrated()
    }

    /// Re-reads settings after any UserDefaults change; cheap and idempotent.
    private func applySettings() {
        // FR-P2-01 needs eye offsets, but only when there is more than one window or pane to pick
        // from; landmarks are the costliest step. Every frame while calibrating, every other otherwise.
        tracker.configure(smoothing: SmoothingParams(defaults),
                          trackPupils: defaults.bool(forKey: Pref.trackPupils) || calibrating || (eyesNeeded && defaults.bool(forKey: Pref.focusWithinScreen)),
                          pupilStride: calibrating ? 1 : 2)
        layoutPoke?.yield(())
        let tuning = Tuning(defaults)
        Task { await controller.update(tuning: tuning) }
        if tuning.rejectThreshold != classifier.rejectThreshold || tuning.hysteresisFactor != classifier.hysteresisFactor {
            rebuildModels()
        }
        if !defaults.bool(forKey: Pref.showActiveBorder) { feedback.showActive(nil) }
        input.confirmFlag = EventTapInputMonitor.confirmFlag(named: defaults.string(forKey: Pref.confirmKey) ?? "fn")
        let undoKey = (defaults.integer(forKey: Pref.undoHotkeyCode), defaults.integer(forKey: Pref.undoHotkeyModifiers))
        if undoHotkeySetting.map({ $0 != undoKey }) ?? true {
            undoHotkeySetting = undoKey
            undoHotkey?.register(keyCode: UInt32(undoKey.0), modifiers: UInt32(undoKey.1))
        }
        let key = (defaults.integer(forKey: Pref.hotkeyCode), defaults.integer(forKey: Pref.hotkeyModifiers))
        if hotkeySetting.map({ $0 != key }) ?? true {
            hotkeySetting = key
            if hotkey?.register(keyCode: UInt32(key.0), modifiers: UInt32(key.1)) == false {
                log.error("pause shortcut is taken by another app")
            }
        }
        let preferred = defaults.string(forKey: Pref.cameraID).flatMap { $0.isEmpty ? nil : $0 }
        if preferred != preferredCamera {
            preferredCamera = preferred
            if cameraWanted { camera.start(preferredID: preferred) }
        }
        if defaults.bool(forKey: Pref.showDebugOverlay) {
            if debugOverlay == nil { debugOverlay = DebugOverlay() }
        } else {
            debugOverlay?.hide()
            debugOverlay = nil
        }
    }

    // MARK: Pose pipeline (main-thread consumers; the hot path runs elsewhere)

    private func handlePose(_ e: PoseEvent) {
        learning.observe(e)
        updateEyeFeatures(e)
        if let fps = governor.update(e) { // FR-TRK-08
            tracker.setFrameRate(fps)                                   // frames analysed
            camera.setFrameRate(fps == FrameRateGovernor.idle ? 5 : 15) // frames captured
        }
        switch e {
        case .pose(let s):
            lastSample = s
            lastFaceTime = s.timestamp
            setFaceVisible(true)
        case .noFace(let t):
            if t - lastFaceTime >= 1 { setFaceVisible(false) } // FR-TRK-06
        }
        if let debugOverlay {
            // The controller's gaze point when there is one (FR-P2), else the centre of the screen faced.
            let gaze = snapshot?.gaze ?? lastSample.flatMap { s -> CGPoint? in
                guard faceVisible, case .candidate(let key) = classifier.classify(s, current: nil),
                      let d = registry.display(key) else { return nil }
                return CGPoint(x: d.bounds.midX, y: d.bounds.midY)
            }
            debugOverlay.update(debugText(), gaze: gaze)
            Task { snapshot = await controller.snapshot() }
        }
    }

    private func setFaceVisible(_ v: Bool) {
        guard v != faceVisible else { return }
        faceVisible = v
        reconcile()
    }

    private func debugText() -> String {
        func f(_ x: Double) -> String { String(format: "%+6.1f", x) }
        var lines = ["Glanzow debug — \(status.title)"]
        if let s = lastSample, faceVisible {
            lines.append("yaw \(f(s.yaw))°  pitch \(f(s.pitch))°  roll \(f(s.roll))°")
            lines.append(String(format: "face scale %.3f  confidence %.2f", s.faceScale, s.confidence))
            if let p = s.pupilOffset { lines.append(String(format: "pupils %+.3f %+.3f", p.x, p.y)) }
        } else {
            lines.append("no face")
        }
        if let s = lastSample, faceVisible {
            let names = Dictionary(displays.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
            let d = classifier.distances(s).map { "\(names[$0.key] ?? $0.key) \(String(format: "%.2f", $0.distance))" }
            lines.append("distance " + (d.isEmpty ? "no calibration" : d.joined(separator: "  ")))
        }
        if let snap = snapshot {
            let names = Dictionary(displays.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
            func name(_ k: DisplayKey?) -> String { k.map { names[$0] ?? $0 } ?? "—" }
            let c: String
            switch snap.classification {
            case .candidate(let k)?: c = name(k)
            case .stay?: c = "stay"
            case .offScreen?: c = "off-screen"
            case nil: c = "—"
            }
            lines.append("class \(c)  current \(name(snap.current))  pending \(name(snap.pending))")
            lines.append("guards typing \(snap.typingGuard ? "ON" : "off")  mouse \(snap.mouseGuard ? "ON" : "off")  \(snap.paused ? "PAUSED" : "")")
            if let b = snap.blockedBy { lines.append("blocked by \(b)") }
            if snap.gaze != nil {
                lines.append("region \(snap.focusedRegion ?? "—")  pending \(snap.pendingRegion ?? "—")")
            } else if defaults.bool(forKey: Pref.focusWithinScreen), let cur = snap.current, store.model(cur)?.gaze == nil {
                lines.append("window focus needs a recalibration")
            }
        }
        if case .running(_, let name) = cameraState { lines.append("camera \(name)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Recording (debug builds; numbers only)

    func toggleRecording() {
        if recorder.isRecording {
            tracker.setRawTap(nil)
            do {
                if let url = try recorder.stop() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                log.error("recording: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            recorder.start(cameraID: cameraID, models: store.valid(for: displays, cameraID: cameraID))
            tracker.setRawTap { [recorder] e in recorder.record(e) }
        }
        isRecording = recorder.isRecording
    }

    /// FR-CAL-07: rebuild the display map; any display without calibration keeps switching
    /// paused (status "Needs calibration") and gets one prompt.
    private func displaysChanged(_ list: [DisplayInfo]) {
        displays = list
        rebuildModels()
        reconfiguring = false // reconciles
        promptIfUncalibrated()
    }

    /// Classifier from the models that fit the connected displays and the running camera.
    private func rebuildModels() {
        let tuning = Tuning(defaults)
        classifier = MahalanobisClassifier(models: store.valid(for: displays, cameraID: cameraID),
                                           rejectThreshold: tuning.rejectThreshold, hysteresisFactor: tuning.hysteresisFactor)
        // Until the camera runs we cannot tell which camera's calibration applies.
        uncalibrated = cameraID.isEmpty ? [] : store.uncalibrated(displays, cameraID: cameraID)
        let c = classifier
        Task { await controller.update(classifier: c) }
    }

    // MARK: Switch feedback and logging

    private func didSwitch(_ r: SwitchRecord) {
        let t = now()
        layoutPoke?.yield(())
        var fields: [String: Any] = ["to": r.to, "from": r.from ?? "", "region": r.region ?? "", "settleToFocusMs": Int((t - r.pendingSince) * 1000),
                                     "frameToFocusMs": Int((t - r.time) * 1000), "focusMs": Int(r.focusDuration * 1000)]
        switch r.outcome {
        case .focusedWindow: fields["outcome"] = "window"
        case .focusedPane(let how): fields["outcome"] = "pane"; fields["method"] = how
        case .pointerOnly: fields["outcome"] = "pointer"
        case .skipped(let why): fields["outcome"] = "skipped"; fields["reason"] = why
        }
        eventLog.append("switch", fields) // NFR-01 latency, NFR-03 review
        if case .skipped = r.outcome { return }
        lastSwitchAt = r.time
        countToday(switches: 1)
        learning.noteSwitch(at: r.time)
        learnSettle(from: r)
        log.info("switch → \(r.to, privacy: .public) settle-to-focus \(Int((t - r.pendingSince) * 1000)) ms")
    }

    /// FR-UI-03, as the user's chosen feedback. `area` is what the wash covers: the whole screen
    /// after a move between screens, the window or pane itself within one.
    private func focused(_ rect: CGRect, area: CGRect) {
        switch defaults.string(forKey: Pref.feedbackStyle) ?? "wash" {
        case "none": break
        case "ring": feedback.flash(rect)
        default: // "wash", and "spotlight" from before the wash replaced it
            guard let d = registry.display(containing: area) else { return feedback.flash(rect) }
            feedback.wash(rect, over: area, on: d.bounds)
        }
    }

    // MARK: Eye features

    /// Eye breaks and the privacy guard, from the pose stream (main thread, cheap).
    private func updateEyeFeatures(_ e: PoseEvent) {
        let t = e.timestamp
        var sample: PoseSample?
        if case .pose(let s) = e { sample = s }
        if defaults.bool(forKey: Pref.eyeBreaks) {
            let onScreen = sample.map { classifier.classify($0, current: nil) != .offScreen } ?? false
            switch eyeBreak.update(at: t, onScreen: onScreen) {
            case .due?:
                eventLog.append("eyeBreak", ["due": true])
                eyePill.show(progress: 0)
            case .done?:
                eventLog.append("eyeBreak", ["done": true])
                eyePill.finish()
            case nil:
                if case .due(let progress) = eyeBreak.state { eyePill.show(progress: progress) }
            }
        }
        if defaults.bool(forKey: Pref.privacyGuard) {
            if privacy.update(at: t, watchers: sample?.watchers ?? 0) {
                if privacy.veiled {
                    eventLog.append("privacyGuard", ["veiled": true])
                    veil.show()
                } else {
                    veil.hide()
                }
            }
        } else if veil.isShown {
            veil.hide()
        }
    }

    private func focusChanged(_ key: DisplayKey?, _ frame: CGRect?) {
        if defaults.bool(forKey: Pref.showActiveBorder) { feedback.showActive(frame) } // FR-UI-05
        // Replays should see the user's focus changes, not echoes of our own switches.
        if let key, now() - lastSwitchAt > 0.5 { recorder.record(.focus, at: now(), display: key) }
    }

    /// FR-LRN-01…04: learn from clicks while switching is live.
    // MARK: Panel

    /// The live view polls the controller ten times a second, only while the panel is open.
    func panelOpened() {
        refreshToday()
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    let snap = await self.controller.snapshot()
                    var looked: DisplayKey? = nil
                    if !snap.noFace, case .candidate(let k)? = snap.classification { looked = k }
                    if !snap.noFace, case .stay? = snap.classification { looked = snap.current }
                    let next = Live(display: looked, gaze: looked == snap.current ? snap.gaze : nil)
                    if next != self.live { self.live = next }
                }
            }
        }
    }

    func panelClosed() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// Today's switches and undos, kept as two counters that reset at midnight.
    private func countToday(switches: Int = 0, undos: Int = 0) {
        let day = Date().formatted(.iso8601.year().month().day())
        if defaults.string(forKey: Pref.statsDay) != day {
            defaults.set(day, forKey: Pref.statsDay)
            defaults.set(0, forKey: Pref.statsSwitches)
            defaults.set(0, forKey: Pref.statsUndos)
        }
        defaults.set(defaults.integer(forKey: Pref.statsSwitches) + switches, forKey: Pref.statsSwitches)
        if switches > 0 { defaults.set(defaults.integer(forKey: Pref.switchesTotal) + switches, forKey: Pref.switchesTotal) }
        defaults.set(defaults.integer(forKey: Pref.statsUndos) + undos, forKey: Pref.statsUndos)
        refreshToday()
    }

    private func refreshToday() {
        let day = Date().formatted(.iso8601.year().month().day())
        let switches = defaults.string(forKey: Pref.statsDay) == day ? defaults.integer(forKey: Pref.statsSwitches) : 0
        let undos = defaults.string(forKey: Pref.statsDay) == day ? defaults.integer(forKey: Pref.statsUndos) : 0
        let s = switches == 0 ? "No switches yet today" : "Today: \(switches) switch\(switches == 1 ? "" : "es")"
        todayLine = undos == 0 ? s : "\(s), \(undos) undone"
    }

    /// ⌃⌥Z: put focus back where the last switch took it from, and learn from it.
    func undoSwitch() {
        Task {
            guard let r = await controller.undo(at: now()) else { return NSSound.beep() }
            eventLog.append("undo", ["to": r.to, "region": r.region ?? "", "afterMs": Int((now() - r.time) * 1000)])
            countToday(undos: 1)
            settle.undone()
            storeSettle()
        }
    }

    /// The learned settle time (SettleLearner): bounces nobody typed into slow it down a little,
    /// switches that were used at once speed it up a little. Screen switches only.
    private func learnSettle(from r: SwitchRecord) {
        guard r.region == nil, defaults.bool(forKey: Pref.adaptiveSettle) else { return }
        settle.switched(at: r.time)
        if let p = previousSwitch, p.region == nil, p.to == r.from, p.from == r.to, r.time - p.time < 1.5,
           input.lastKeystroke < p.time, lastClickAt < p.time {
            settle.bounced(at: r.time)
            storeSettle()
        }
        previousSwitch = r
        // Three seconds later: did the user type or click on the screen they switched to?
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.previousSwitch?.time == r.time else { return }
            if self.input.lastKeystroke > r.time || self.lastClickAt > r.time {
                self.settle.used(at: r.time + 3)
                self.storeSettle()
            }
        }
    }

    private func storeSettle() {
        let ms = (settle.dwell * 1000).rounded()
        if defaults.double(forKey: Pref.learnedDwellMs) != ms { defaults.set(ms, forKey: Pref.learnedDwellMs) } // applySettings pushes it
    }

    /// Privacy: forget everything learned — screen models, learned timing, the switch log.
    func eraseLearnedData() {
        store.removeAll()
        resetLearnedSettle()
        eventLog.erase()
        rebuildModels()
        reconcile()
    }

    func resetLearnedSettle() {
        defaults.removeObject(forKey: Pref.learnedDwellMs)
        settle = SettleLearner(dwell: Tuning(defaults).dwell)
    }

    private func clicked(_ click: EventTapInputMonitor.Click) {
        lastClickAt = click.time
        guard let key = registry.display(at: click.location)?.key else { return }
        recorder.record(.click, at: click.time, display: key)
        guard switchingEnabled, defaults.bool(forKey: Pref.learnFromClicks) else { return }
        let update = learning.click(at: click.time, on: key, classifier: classifier, model: store.model(key))
        if var m = update.model {
            // FR-P2-01 implicit calibration: the click point is where the eyes were.
            if let s = update.sample, m.gaze != nil, let d = registry.display(key) {
                let target = SIMD2(Double((click.location.x - d.bounds.minX) / d.bounds.width), Double((click.location.y - d.bounds.minY) / d.bounds.height))
                m.clickPairs = Array(((m.clickPairs ?? []) + [GazePair(s, target: target)]).suffix(DisplayModel.maxClickPairs))
                clicksSinceRefit[key, default: 0] += 1
                if clicksSinceRefit[key]! >= 10, let refit = GazeMap.fit(calibration: m.gazePairs ?? [], clicks: m.clickPairs ?? []) {
                    clicksSinceRefit[key] = 0
                    m.gaze = refit
                    eventLog.append("gazeRefit", ["display": key, "clicks": m.clickPairs?.count ?? 0,
                                                  "errorPercent": Int((((refit.eyesError ?? refit.headError)) * 100).rounded())])
                }
            }
            store.set([m], persist: false)
            rebuildModels()
            scheduleSave()
        }
        if let miss = update.driftAlert {
            eventLog.append("drift", ["missRate": miss])
            notifier.once("drift", title: "Glanzow may need recalibrating",
                          body: "On \(Int((miss * 100).rounded()))% of your last 50 clicks, the screen you clicked wasn't the one Glanzow thought you were facing. Recalibrate from the menu.")
        }
    }

    /// Click learning changes models often; write them at most every 30 s.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.saveScheduled = false
            self?.store.save()
        }
    }

    /// FR-SAF-04: stop the camera while the Mac is locked, asleep, in the screensaver, or
    /// switched to another user; resume when all of those end.
    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let workspace: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.willSleepNotification, "sleep", true), (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.screensDidSleepNotification, "display sleep", true), (NSWorkspace.screensDidWakeNotification, "display sleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, "user switch", true), (NSWorkspace.sessionDidBecomeActiveNotification, "user switch", false),
        ]
        for (name, reason, on) in workspace {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSystemPause(reason, on) }
            })
        }
        let distributed: [(String, String, Bool)] = [
            ("com.apple.screenIsLocked", "lock", true), ("com.apple.screenIsUnlocked", "lock", false),
            ("com.apple.screensaver.didstart", "screensaver", true), ("com.apple.screensaver.didstop", "screensaver", false),
        ]
        for (name, reason, on) in distributed {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSystemPause(reason, on) }
            })
        }
        // §7 video calls: suggest excluding a call app the first time it comes to the front.
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let bundle { self?.suggestExclusion(bundle) } }
        })
    }

    private func setSystemPause(_ reason: String, _ on: Bool) {
        // Any process can post "screen unlocked" or "screensaver stopped" (they are distributed
        // notifications), so a resume is accepted only if the system agrees it's true.
        if !on, reason == "lock" || reason == "screensaver", Self.systemLockState().contains(reason) { return }
        guard on != systemPauses.contains(reason) else { return }
        eventLog.append("state", ["pause": reason, "on": on])
        if on { systemPauses.insert(reason) } else { systemPauses.remove(reason) }
    }

    /// What the system itself says right now: "lock" if the screen is locked, "screensaver" if it runs.
    static func systemLockState() -> Set<String> {
        var state = Set<String>()
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            state.insert("lock")
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty {
            state.insert("screensaver")
        }
        return state
    }

    /// Every 30 s, reconcile lock and screensaver pauses with the real state, so a missed (or
    /// faked) notification can neither leave the camera on while locked nor off after unlocking.
    private func startLockWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let actual = Self.systemLockState()
                for reason in ["lock", "screensaver"] { self.setSystemPause(reason, actual.contains(reason)) }
                self.restIfAway()
            }
        }
    }

    private var resting: Bool { systemPauses.contains("away") }

    /// Nobody seen for 2 minutes and no keyboard or mouse for 2 minutes: turn the camera off (its
    /// light goes out) until the next keystroke or mouse movement. Less camera time, less battery.
    private func restIfAway() {
        guard defaults.bool(forKey: Pref.restWhenAway), !resting, !calibrating, case .running = cameraState, !faceVisible else { return }
        let t = now()
        guard t - lastFaceTime >= 120, t - max(input.lastKeystroke, input.lastMouseActivity) >= 120 else { return }
        setSystemPause("away", true)
    }

    static let callApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
                                        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "com.skype.skype"]

    private func suggestExclusion(_ bundle: String) {
        guard Self.callApps.contains(bundle) else { return }
        let excluded = defaults.stringArray(forKey: Pref.excludedApps) ?? []
        var suggested = defaults.stringArray(forKey: Pref.suggestedCallApps) ?? []
        guard !excluded.contains(bundle), !suggested.contains(bundle) else { return }
        suggested.append(bundle)
        defaults.set(suggested, forKey: Pref.suggestedCallApps)
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName ?? bundle
        notifier.once("call-\(bundle)", title: "Exclude \(name) from Glanzow?",
                      body: "During calls you may look at other screens without wanting focus to move. Excluded apps never lose or gain focus to Glanzow.",
                      category: "callApp", userInfo: ["bundleID": bundle])
    }

    private func exclude(_ bundle: String) {
        var list = defaults.stringArray(forKey: Pref.excludedApps) ?? []
        if !list.contains(bundle) { list.append(bundle) }
        defaults.set(list, forKey: Pref.excludedApps)
    }

    /// §7: Accessibility revoked — show "Needs permission" and wait for it to come back.
    private func accessibilityLost() {
        guard axTrusted else { return }
        log.error("Accessibility revoked")
        refreshPermissions()
    }

    private func promptIfUncalibrated() {
        if displays.contains(where: \.ambiguous) {
            notifier.once("ambiguous", title: "Identical monitors detected", body: Self.ambiguousNote)
        }
        // FR-P2-01: calibrations from before window focus have no gaze map, and maps fitted on
        // the old eye measurement can't use the new iris tracking.
        if uncalibrated.isEmpty, defaults.bool(forKey: Pref.focusWithinScreen),
           store.valid(for: displays, cameraID: cameraID).contains(where: { $0.gaze.map { $0.eyes != nil && !$0.eyesCurrent } ?? true }) {
            notifier.once("needsGaze", title: "Recalibrate for sharper window focus",
                          body: "Glanzow now tracks your eyes, not just your head, to pick the window or pane you look at. Recalibrate once from the menu to turn it on.")
        }
        let fresh = uncalibrated.filter { !promptedFor.contains($0.key) }
        guard !fresh.isEmpty, !calibrating, defaults.bool(forKey: Pref.onboardingDone) else { return }
        promptedFor.formUnion(fresh.map(\.key))
        let alert = NSAlert()
        alert.messageText = fresh.count == 1 ? "Calibrate \(fresh[0].name)?" : "Calibrate \(fresh.count) displays?"
        var info = "\(fresh.map(\.name).joined(separator: ", ")) has no calibration for this camera. Glanzow won't switch screens until every connected display is calibrated."
        if displays.contains(where: \.ambiguous) { info += "\n\n" + Self.ambiguousNote }
        alert.informativeText = info
        alert.addButton(withTitle: "Calibrate Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await calibrate(fresh.map(\.key)) }
        }
    }

    static let ambiguousNote = "Two identical monitors don't report distinct serial numbers, so Glanzow tells them apart by their position. If you rearrange them in System Settings, recalibrate."

    // MARK: Permissions (FR-ONB-02, FR-ONB-03)

    func refreshPermissions() {
        let cam = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorized = cam == .authorized
        cameraDenied = cam == .denied || cam == .restricted
        axTrusted = AXIsProcessTrusted()
        startMonitors()
        if !permissionsGranted || !cameraAuthorized { startPermissionPolling() }
        reconcile()
    }

    func requestCamera() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refreshPermissions()
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        startPermissionPolling()
    }

    /// FR-ONB-03: polls every second until camera, Accessibility and (if the tap needs it)
    /// Input Monitoring are granted, so onboarding advances on its own.
    private func startPermissionPolling() {
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ax = AXIsProcessTrusted()
                let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                guard ax != self.axTrusted || camera != self.cameraAuthorized || (ax && !self.inputOK) else { return }
                self.refreshPermissions()
                if self.permissionsGranted && self.cameraAuthorized {
                    self.permissionPoll?.invalidate()
                    self.permissionPoll = nil
                }
            }
        }
    }

    var permissionsGranted: Bool { axTrusted && inputOK }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        Self.openPrivacySettings("Privacy_ListenEvent")
    }

    static func openPrivacySettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    // MARK: Launch at login (FR-ONB-05)

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("launch at login: \(error.localizedDescription, privacy: .public)")
            }
            objectWillChange.send()
        }
    }

    func finishOnboarding(launchAtLogin: Bool) {
        defaults.set(true, forKey: Pref.onboardingDone)
        self.launchAtLogin = launchAtLogin
        notifier.requestPermission()
        onboardingWindow?.close()
        reconcile()
    }

    // MARK: Calibration

    /// FR-CAL-01…06: calibrate `keys` (nil = all displays), validate every calibrated display,
    /// and offer to redo the ones under 90%. Returns a short result line for onboarding.
    @discardableResult
    func calibrate(_ keys: [DisplayKey]?) async -> String? {
        guard !calibrating else { return nil }
        guard cameraAuthorized else { return "Camera access is needed first." }
        calibrating = true
        applySettings() // pupils on every frame: the gaze map needs them (FR-P2-01)
        reconcile() // starts the camera, pauses switching
        defer {
            calibrating = false
            applySettings()
            rebuildModels()
            reconcile()
        }
        guard await waitForCamera() else { return "No camera is available." }
        let overlay = CalibrationOverlay(source: tracker)
        defer { overlay.close() }
        var targets = displays.filter { keys?.contains($0.key) ?? true }
        while true {
            guard let outcome = await overlay.calibrate(targets, among: displays, cameraID: cameraID) else {
                return "Calibration cancelled."
            }
            store.set(outcome.models)
            for (key, c) in outcome.spotChecks { // would the tour alone have found the fixed spots?
                func pct(_ v: Double) -> Int { Int((v * 100).rounded()) }
                eventLog.append("spotCheck", ["display": key, "spots": c.spots, "tourOnlyX": pct(c.tourOnly.x), "tourOnlyY": pct(c.tourOnly.y),
                                              "finalX": pct(c.final.x), "finalY": pct(c.final.y)])
            }
            learning.reset()
            notifier.forget("drift")
            rebuildModels()
            let calibrated = displays.filter { d in !uncalibrated.contains(d) }
            guard let accuracy = await overlay.validate(calibrated, classifier: classifier) else { return "Calibration cancelled." }
            overlay.hide()

            // SPEC: FR-CAL-05 says "at least 90% correct". Applied per display, not pooled, so
            // one weak display can't hide behind two strong ones.
            let failing = outcome.failed + calibrated.filter { (accuracy[$0.key] ?? 0) < 0.9 }
            let pairs = calibrated.compactMap { d in store.model(d.key).map { (display: d, model: $0) } }
            let orderOK = CalibrationStore.yawOrderConsistent(pairs)
            var summary = calibrated.map { "\($0.name) \(Int(((accuracy[$0.key] ?? 0) * 100).rounded()))%" }.joined(separator: ", ")
            // FR-P2-01: how closely the gaze map hits the dots, as a share of the screen.
            let aims = calibrated.compactMap { store.model($0.key)?.gaze.map { $0.eyesError ?? $0.headError } }
            if let worst = aims.max() { summary += ". Window aim within about \(max(1, Int((worst * 100).rounded())))% of the screen" }
            log.info("validation \(summary, privacy: .public) order=\(orderOK)")
            if failing.isEmpty && orderOK { return "Calibrated. Validation: \(summary)." }

            let alert = NSAlert()
            alert.messageText = "Calibration needs another try"
            var lines = ["Validation: \(summary). Each display needs at least 90%."]
            if !outcome.failed.isEmpty {
                lines.append("Your face wasn't seen clearly on \(outcome.failed.map(\.name).joined(separator: ", ")). Check the lighting and that the camera can see you.")
            }
            if !orderOK {
                lines.append("Head angles don't line up with the display arrangement in System Settings. Check the arrangement, then calibrate all displays.")
            }
            alert.informativeText = lines.joined(separator: "\n\n")
            let redo = failing.isEmpty ? displays : failing
            alert.addButton(withTitle: failing.isEmpty ? "Redo All" : "Redo \(redo.map(\.name).joined(separator: ", "))")
            alert.addButton(withTitle: "Keep Anyway")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return "Calibrated. Validation: \(summary)." }
            targets = redo
        }
    }

    private func waitForCamera() async -> Bool {
        for _ in 0..<50 {
            if case .running = cameraState { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: Windows

    func showOnboarding() {
        if onboardingWindow == nil {
            let w = Self.window("Set Up Glanzow", OnboardingView(model: self))
            // The night stage runs under a transparent title bar; the traffic lights sit on it.
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            onboardingWindow = w
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onboardingWindow = nil } // free its views (NFR-05)
            })
        }
        Self.present(onboardingWindow!)
    }

    /// `debug` adds the hidden debug pane (Option-click the menu item); debug builds always show it.
    func showSettings(debug: Bool = false) {
        #if DEBUG
        let debug = true
        #endif
        if settingsWindow == nil || debug != settingsShowsDebug {
            settingsWindow?.close()
            settingsShowsDebug = debug
            let w = Self.window("Glanzow Settings", SettingsView(model: self, showDebug: debug))
            settingsWindow = w
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsWindow = nil }
            })
        }
        Self.present(settingsWindow!)
    }

    private static func window(_ title: String, _ view: some View) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    private static func present(_ w: NSWindow) {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
