import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement
import SwiftUI
import GlanzowKit

/// Owns every module, wires the pipeline together, and turns permission, pause, camera and
/// calibration state into one menu bar status.
@MainActor final class AppModel: ObservableObject {
    enum Status: Equatable {
        case active, paused, pausedBySystem, noFace, needsPermission, needsCalibration, noCamera, cameraBusy, calibrating

        var title: String {
            switch self {
            case .active: "Active — focus follows the screen you face"
            case .paused: "Paused"
            case .pausedBySystem: "Paused while the screen is locked or asleep"
            case .noFace: "No face in view"
            case .needsPermission: "Needs permission"
            case .needsCalibration: "Needs calibration"
            case .noCamera: "No camera"
            case .cameraBusy: "Camera unavailable — retrying"
            case .calibrating: "Calibrating"
            }
        }

        var symbol: String {
            switch self {
            case .active: "eye"
            case .paused, .pausedBySystem: "pause.circle"
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
    private var hotkeySetting: (code: Int, modifiers: Int)?
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
    private var learning = LearningEngine()
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

    init() { Pref.register() }

    #if DEBUG
    func preview(displays list: [DisplayInfo]) { displays = list }
    #endif

    func start() {
        registry.start()
        displays = registry.displays
        registry.onChange = { [weak self] list in self?.displaysChanged(list) }
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
        observeSystem()
        hotkey = Hotkey { [weak self] in self?.userPaused.toggle() }
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
                onFocused: { [weak self] rect in Task { @MainActor in self?.focused(rect) } },
                onAXDisabled: { [weak self] in Task { @MainActor in self?.accessibilityLost() } })
            await windows.setCallbacks(
                onFocus: { [weak self] key, ref in
                    // A window-less app keeps the last display as current (switch less).
                    if let key { Task { await controller.setCurrent(key) } }
                    let frame = ref?.frame
                    Task { @MainActor in self?.focusChanged(key, frame) }
                },
                onAXDisabled: { [weak self] in Task { @MainActor in self?.accessibilityLost() } })
        }
        input.onClick = { [weak self] click in self?.clicked(click) }
        input.onConfirm = { t in Task { await controller.confirm(at: t) } }
        input.onActivity = { [recorder] kind, t in recorder.record(kind, at: t) }
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
        let wantSwitching = cameraWanted && running && permissionsGranted && !calibrating && uncalibrated.isEmpty
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
        tracker.configure(smoothing: SmoothingParams(defaults), trackPupils: defaults.bool(forKey: Pref.trackPupils))
        let tuning = Tuning(defaults)
        Task { await controller.update(tuning: tuning) }
        if tuning.rejectThreshold != classifier.rejectThreshold || tuning.hysteresisFactor != classifier.hysteresisFactor {
            rebuildModels()
        }
        if !defaults.bool(forKey: Pref.showActiveBorder) { feedback.showActive(nil) }
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
        if let fps = governor.update(e) { // FR-TRK-08
            log.info("frame rate \(fps) fps")
            camera.setFrameRate(fps)
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
            let gaze = lastSample.flatMap { s -> CGPoint? in
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
        reconcile()
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
        var fields: [String: Any] = ["to": r.to, "from": r.from ?? "", "settleToFocusMs": Int((t - r.pendingSince) * 1000),
                                     "frameToFocusMs": Int((t - r.time) * 1000), "focusMs": Int(r.focusDuration * 1000)]
        switch r.outcome {
        case .focusedWindow: fields["outcome"] = "window"
        case .pointerOnly: fields["outcome"] = "pointer"
        case .skipped(let why): fields["outcome"] = "skipped"; fields["reason"] = why
        }
        eventLog.append("switch", fields) // NFR-01 latency, NFR-03 review
        if case .skipped = r.outcome { return }
        lastSwitchAt = r.time
        learning.noteSwitch(at: r.time)
        log.info("switch → \(r.to, privacy: .public) settle-to-focus \(Int((t - r.pendingSince) * 1000)) ms")
    }

    private func focused(_ rect: CGRect) {
        if defaults.bool(forKey: Pref.flashOnSwitch) { feedback.flash(rect) } // FR-UI-03
    }

    private func focusChanged(_ key: DisplayKey?, _ frame: CGRect?) {
        if defaults.bool(forKey: Pref.showActiveBorder) { feedback.showActive(frame) } // FR-UI-05
        // Replays should see the user's focus changes, not echoes of our own switches.
        if let key, now() - lastSwitchAt > 0.5 { recorder.record(.focus, at: now(), display: key) }
    }

    /// FR-LRN-01…04: learn from clicks while switching is live.
    private func clicked(_ click: EventTapInputMonitor.Click) {
        guard let key = registry.display(at: click.location)?.key else { return }
        recorder.record(.click, at: click.time, display: key)
        guard switchingEnabled, defaults.bool(forKey: Pref.learnFromClicks) else { return }
        let update = learning.click(at: click.time, on: key, classifier: classifier, model: store.model(key))
        if let m = update.model {
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
        log.info("system pause \(reason, privacy: .public) \(on)")
        if on { systemPauses.insert(reason) } else { systemPauses.remove(reason) }
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
        reconcile() // starts the camera, pauses switching
        defer {
            calibrating = false
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
            let summary = calibrated.map { "\($0.name) \(Int(((accuracy[$0.key] ?? 0) * 100).rounded()))%" }.joined(separator: ", ")
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
            let w = Self.window("Welcome to Glanzow", OnboardingView(model: self))
            // The night stage runs under a transparent title bar; the traffic lights sit on it.
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            onboardingWindow = w
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
            settingsWindow = Self.window("Glanzow Settings", SettingsView(model: self, showDebug: debug))
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
