import AppKit
import ApplicationServices
import os

/// FR-FOC-02: remembers the window the user last focused on each display, by watching app
/// activation (NSWorkspace) and focused-window changes (AXObserver).
// ponytail: one memory per display, not per (display, Space); there is no public Space ID API.
// A remembered window on a hidden Space falls back to FR-FOC-03, as §7 asks. Per-Space memory
// would need the private CGS Space calls.
@AXActor public final class WindowTracker {
    public private(set) var lastFocused: [DisplayKey: WindowRef] = [:]
    public private(set) var focused: WindowRef?
    /// Display of the newly focused window (nil if off every display) and the window itself.
    public var onFocus: (@Sendable (DisplayKey?, WindowRef?) -> Void)?
    /// An AX call reported the API disabled: Accessibility was revoked (§7).
    public var onAXDisabled: (@Sendable () -> Void)?

    /// FR-SAF-06: Mission Control is open (from the Dock's own Exposé notifications).
    public var missionControlActive: Bool { missionControlSince.map { now() - $0 < 60 } ?? false }
    private var missionControlSince: TimeInterval?
    private var dockObserver: (pid: pid_t, observer: AXObserver)?

    private let displays: DisplayRegistry
    private var observers: [pid_t: AXObserver] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let log = logger("windows")

    nonisolated public init(displays: DisplayRegistry) { self.displays = displays }

    public func setCallbacks(onFocus: @escaping @Sendable (DisplayKey?, WindowRef?) -> Void, onAXDisabled: @escaping @Sendable () -> Void) {
        self.onFocus = onFocus
        self.onAXDisabled = onAXDisabled
    }

    /// Call once Accessibility is granted.
    nonisolated public func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @AXActor in self?.activated(pid) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { @AXActor in self?.terminated(pid) }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @AXActor in self?.refreshFrontmost() }
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.dock" else { return }
            Task { @AXActor in self?.observeDock() } // the Dock was restarted
        }
        Task { @AXActor in
            self.observeDock()
            self.refreshFrontmost()
        }
    }

    func refreshFrontmost() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        activated(pid)
    }

    private func activated(_ pid: pid_t) {
        missionControlSince = nil // picking a window in Mission Control activates its app
        guard pid != ownPID else { return }
        observe(pid)
        refresh(pid)
    }

    private func terminated(_ pid: pid_t) {
        if dockObserver?.pid == pid {
            dockObserver = nil
            missionControlSince = nil
        }
        if let o = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        }
        lastFocused = lastFocused.filter { $0.value.pid != pid }
        if focused?.pid == pid { focused = nil }
    }

    private func observe(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
        let app = AXUIElement.application(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // A just-launched app often can't answer yet; without the focus notification there is
        // nothing to keep, so try again on its next activation.
        guard AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon) == .success else { return }
        // Focused-element changes catch a click into another split pane (FR-P2-02).
        for n in [kAXMainWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                  kAXWindowMiniaturizedNotification, kAXFocusedUIElementChangedNotification] {
            AXObserverAddNotification(observer, app, n as CFString, refcon)
        }
        // Callbacks need a run loop; the main one is always there. Common modes keep them
        // flowing while a menu or alert is open. They only hop back to this actor.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    /// The Dock posts these when Mission Control, App Exposé or Show Desktop open and close
    /// (the same signal yabai uses). Window geometry can't tell: on recent macOS the Dock keeps a
    /// full-screen window at the Dock level even when nothing is showing.
    func observeDock() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dockObserver?.pid != dock.processIdentifier else { return }
        var observer: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, dockCallback, &observer) == .success, let observer else { return }
        let app = AXUIElement.application(dock.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", "AXExposeExit"] {
            AXObserverAddNotification(observer, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        dockObserver = (dock.processIdentifier, observer)
    }

    fileprivate func exposeChanged(_ name: String) {
        // A missed exit can't block switching for ever: the flag also expires after 60 s.
        missionControlSince = name == "AXExposeExit" ? nil : now()
    }

    fileprivate func notified(_ pid: pid_t) {
        PerfMeter.shared.axEvent()
        // Only the frontmost app's focus is the user's focus; background apps shuffling their
        // own windows must not overwrite what the user last chose.
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        refresh(pid)
    }

    /// Reads the app's focused window and records it against the display holding most of it.
    private func refresh(_ pid: pid_t) {
        let app = AXUIElement.application(pid)
        let (value, error) = app.raw(kAXFocusedWindowAttribute)
        if error == .apiDisabled { onAXDisabled?(); return }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            focused = nil
            onFocus?(nil, nil)
            return
        }
        let window = value as! AXUIElement
        guard let frame = window.frame, let id = window.windowID else { return }
        let ref = WindowRef(pid: pid, id: id, element: window, frame: frame)
        focused = ref
        let display = displays.display(containing: frame)
        if let display { lastFocused[display.key] = ref }
        onFocus?(display?.key, ref)
    }

    /// FocusManager records its own switches too, so the memory is right even before AX reports back.
    func remember(_ ref: WindowRef, on key: DisplayKey) {
        lastFocused[key] = ref
        focused = ref
    }
}

private let dockCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    Task { @AXActor in tracker.exposeChanged(name) }
}

private let axCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    let pid = element.pid
    Task { @AXActor in tracker.notified(pid) }
}
