import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement
import SwiftUI
import GlanceFocusKit

/// Owns every module, wires the pipeline together, and turns permission, pause, camera and
/// calibration state into one menu bar status.
@MainActor final class AppModel: ObservableObject {
    enum Status: Equatable {
        case active, paused, noFace, needsPermission, needsCalibration, noCamera, calibrating

        var title: String {
            switch self {
            case .active: "Active — focus follows the screen you face"
            case .paused: "Paused"
            case .noFace: "No face in view"
            case .needsPermission: "Needs permission"
            case .needsCalibration: "Needs calibration"
            case .noCamera: "No camera"
            case .calibrating: "Calibrating"
            }
        }

        var symbol: String {
            switch self {
            case .active: "eye"
            case .paused: "pause.circle"
            case .noFace: "eye.slash"
            case .needsPermission: "exclamationmark.triangle"
            case .needsCalibration, .calibrating: "scope"
            case .noCamera: "video.slash"
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

    let defaults = UserDefaults.standard
    let registry = DisplayRegistry.shared
    let tracker = PoseTracker()
    lazy var camera = CameraCapture(tracker: tracker)
    private let recorder = PoseRecorder()
    private let log = logger("app")
    private var menu: MenuBarController?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsShowsDebug = false
    private var debugOverlay: DebugOverlay?
    private var axPoll: Timer?
    private var cameraWanted = false
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

    func start() {
        registry.start()
        displays = registry.displays
        registry.onChange = { [weak self] list in self?.displaysChanged(list) }
        menu = MenuBarController(model: self)
        camera.onState = { [weak self] s in self?.cameraChanged(s) }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        let poses = tracker.events()
        tasks.append(Task { [weak self] in
            for await e in poses { self?.handlePose(e) }
        })
        applySettings()
        refreshPermissions()
        if !defaults.bool(forKey: Pref.onboardingDone) { showOnboarding() }
        reconcile()
    }

    func shutdown() {
        camera.stop()
        tasks.forEach { $0.cancel() }
    }

    // MARK: State

    /// Brings the camera and status in line with permissions, pauses and calibration.
    private func reconcile() {
        let wantCamera = cameraAuthorized && !userPaused && defaults.bool(forKey: Pref.onboardingDone)
        if wantCamera != cameraWanted {
            cameraWanted = wantCamera
            if wantCamera { camera.start(preferredID: preferredCamera) } else { camera.stop() }
        }
        status = computeStatus()
    }

    private func computeStatus() -> Status {
        if !cameraAuthorized || !permissionsGranted { return .needsPermission }
        if userPaused { return .paused }
        if cameraState == .noCamera || cameraState == .busy { return .noCamera }
        if !faceVisible { return .noFace }
        return .active
    }

    private func cameraChanged(_ s: CameraCapture.State) {
        log.info("camera state \(String(describing: s), privacy: .public)")
        cameraState = s
        if case .running = s {} else { setFaceVisible(false) }
        reconcile()
    }

    /// Re-reads settings after any UserDefaults change; cheap and idempotent.
    private func applySettings() {
        tracker.configure(smoothing: SmoothingParams(defaults), trackPupils: defaults.bool(forKey: Pref.trackPupils))
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
        switch e {
        case .pose(let s):
            lastSample = s
            lastFaceTime = s.timestamp
            setFaceVisible(true)
        case .noFace(let t):
            if t - lastFaceTime >= 1 { setFaceVisible(false) } // FR-TRK-06
        }
        if let debugOverlay { debugOverlay.update(debugText(), gaze: nil) }
    }

    private func setFaceVisible(_ v: Bool) {
        guard v != faceVisible else { return }
        faceVisible = v
        reconcile()
    }

    private func debugText() -> String {
        func f(_ x: Double) -> String { String(format: "%+6.1f", x) }
        var lines = ["GlanceFocus debug — \(status.title)"]
        if let s = lastSample, faceVisible {
            lines.append("yaw \(f(s.yaw))°  pitch \(f(s.pitch))°  roll \(f(s.roll))°")
            lines.append(String(format: "face scale %.3f  confidence %.2f", s.faceScale, s.confidence))
            if let p = s.pupilOffset { lines.append(String(format: "pupils %+.3f %+.3f", p.x, p.y)) }
        } else {
            lines.append("no face")
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
            recorder.start(cameraID: cameraID, models: [])
            tracker.setRawTap { [recorder] e in recorder.record(e) }
        }
        isRecording = recorder.isRecording
    }

    private func displaysChanged(_ list: [DisplayInfo]) {
        displays = list
        reconcile()
    }

    // MARK: Permissions (FR-ONB-02, FR-ONB-03)

    func refreshPermissions() {
        let cam = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorized = cam == .authorized
        cameraDenied = cam == .denied || cam == .restricted
        axTrusted = AXIsProcessTrusted()
        if !axTrusted { startAXPolling() }
        reconcile()
    }

    func requestCamera() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refreshPermissions()
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        startAXPolling()
    }

    /// Polls every second until Accessibility is granted, then advances on its own.
    private func startAXPolling() {
        guard axPoll == nil else { return }
        axPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.axPoll?.invalidate()
                self.axPoll = nil
                self.refreshPermissions()
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
        onboardingWindow?.close()
        reconcile()
    }

    // MARK: Calibration

    /// Returns a short result line for the onboarding window.
    @discardableResult
    func calibrate(_ keys: [DisplayKey]?) async -> String? { nil }

    // MARK: Windows

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = Self.window("Welcome to GlanceFocus", OnboardingView(model: self))
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
            settingsWindow = Self.window("GlanceFocus Settings", SettingsView(model: self, showDebug: debug))
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
