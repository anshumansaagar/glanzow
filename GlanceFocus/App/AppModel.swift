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

    let defaults = UserDefaults.standard
    let registry = DisplayRegistry.shared
    private let log = logger("app")
    private var menu: MenuBarController?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var axPoll: Timer?

    init() { Pref.register() }

    func start() {
        registry.start()
        displays = registry.displays
        registry.onChange = { [weak self] list in self?.displaysChanged(list) }
        menu = MenuBarController(model: self)
        refreshPermissions()
        if !defaults.bool(forKey: Pref.onboardingDone) { showOnboarding() }
        reconcile()
    }

    func shutdown() {}

    // MARK: State

    private func reconcile() {
        status = computeStatus()
    }

    private func computeStatus() -> Status {
        if !cameraAuthorized || !permissionsGranted { return .needsPermission }
        if userPaused { return .paused }
        return .active
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

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.window("GlanceFocus Settings", SettingsView(model: self))
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
