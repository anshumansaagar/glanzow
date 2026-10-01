import AppKit
import ApplicationServices
import Carbon
import os

public enum FocusOutcome: Sendable, Equatable {
    case focusedWindow
    /// The display had no windows; only the pointer moved (FR-FOC-05).
    case pointerOnly
    case skipped(String)
}

public protocol FocusPerformer: Sendable {
    func focus(display: DisplayKey) async -> FocusOutcome
    /// FR-P2-01, 02: a window or pane on the current display.
    func focus(region: Region) async -> FocusOutcome
}

public struct FocusOptions: Sendable {
    public var movePointer = true
    public var excludedApps: Set<String> = []
    public var paneClick = false

    public init(_ d: UserDefaults) {
        movePointer = d.bool(forKey: Pref.movePointer)
        excludedApps = Set(d.stringArray(forKey: Pref.excludedApps) ?? [])
        paneClick = d.bool(forKey: Pref.paneClickFallback)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Raises and activates the right window on a display, and warps the pointer (FR-FOC-01…08).
/// Also answers "is something on screen that we must not steal focus from?" (FR-SAF-06, 07).
@AXActor public final class FocusManager: FocusPerformer {
    private let windows: WindowTracker
    private let displays: DisplayRegistry
    private let input: EventTapInputMonitor
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let log = logger("focus")
    /// Frame (global coordinates) of what was just focused, for the flash border.
    private var onFocused: (@Sendable (CGRect) -> Void)?
    private var onAXDisabled: (@Sendable () -> Void)?

    nonisolated public init(windows: WindowTracker, displays: DisplayRegistry, input: EventTapInputMonitor) {
        self.windows = windows
        self.displays = displays
        self.input = input
    }

    public func setCallbacks(onFocused: @escaping @Sendable (CGRect) -> Void, onAXDisabled: @escaping @Sendable () -> Void) {
        self.onFocused = onFocused
        self.onAXDisabled = onAXDisabled
    }

    public func focus(display key: DisplayKey) -> FocusOutcome {
        guard let d = displays.display(key) else { return .skipped("display gone") }
        let options = FocusOptions(.standard)
        let candidates = onScreenWindows().filter { isNormalWindow($0, on: d) }

        // FR-FOC-01: the window last focused on this display, if it is still open and on this
        // display's visible Space (FR-FOC-08). Otherwise FR-FOC-03: the frontmost window mostly here.
        let remembered = windows.lastFocused[key].flatMap { r in candidates.first { $0.id == r.id }.map { (r, $0) } }
        let ordered = (remembered.map { [$0.1] } ?? []) + candidates.filter { $0.id != remembered?.1.id }
        guard !ordered.isEmpty else {
            // FR-FOC-05: an empty display gets the pointer only, so new windows and Spaces follow.
            guard options.movePointer else { return .skipped("no window") }
            warp(to: input.lastPointer(on: key) ?? CGPoint(x: d.bounds.midX, y: d.bounds.midY))
            onFocused?(d.bounds)
            return .pointerOnly
        }
        // Some layer-0 windows have no AX counterpart (invisible helpers, some Electron shells);
        // they are not windows the user works in, so move on to the next. Bounded: each try is IPC.
        var found: (info: WindowInfo, element: AXUIElement, app: AXUIElement)?
        for info in ordered.prefix(5) {
            // SPEC: FR-SAF-07 says never switch into an excluded app. Raising the next window behind
            // it instead would cover the call or game, so the switch does nothing at all.
            if let bundle = NSRunningApplication(processIdentifier: info.pid)?.bundleIdentifier, options.excludedApps.contains(bundle) {
                return .skipped("excluded app")
            }
            let app = AXUIElement.application(info.pid)
            if info.id == remembered?.1.id, let element = remembered?.0.element {
                found = (info, element, app)
                break
            }
            let (windowList, listError) = app.raw(kAXWindowsAttribute)
            if listError == .apiDisabled { onAXDisabled?(); return .skipped("Accessibility revoked") }
            if listError == .cannotComplete { return skip("app not responding", info) } // §7 AX timeout
            if let element = (windowList as? [AXUIElement])?.first(where: { $0.windowID == info.id }) {
                found = (info, element, app)
                break
            }
        }
        guard let (info, element, app) = found else { return .skipped("no window reachable through Accessibility") }
        if let failure = raise(info, element, app) { return failure }
        windows.remember(WindowRef(pid: info.pid, id: info.id, element: element, frame: info.bounds), on: key)

        // FR-FOC-06, 07: pointer to where it last was on this display if that is inside the
        // window, else to the centre of the window's visible part on this display.
        if options.movePointer {
            let visible = info.bounds.intersection(d.bounds)
            let last = input.lastPointer(on: key).flatMap { visible.contains($0) ? $0 : nil }
            warp(to: last ?? CGPoint(x: visible.midX, y: visible.midY))
        }
        onFocused?(info.bounds)
        return .focusedWindow
    }

    /// FR-FOC-04: raise and activate. Nil on success. Never a synthetic click for windows.
    private func raise(_ info: WindowInfo, _ element: AXUIElement, _ app: AXUIElement) -> FocusOutcome? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        switch AXUIElementPerformAction(element, kAXRaiseAction as CFString) {
        case .success, .actionUnsupported: break
        case .apiDisabled: onAXDisabled?(); return .skipped("Accessibility revoked")
        case .cannotComplete: return skip("app not responding", info)
        case let e: return skip("raise failed (\(e.rawValue))", info)
        }
        if let running = NSRunningApplication(processIdentifier: info.pid) {
            DispatchQueue.main.async { _ = running.activate(options: []) }
        }
        return nil
    }

    // MARK: Within a screen (Phase 2)

    /// FR-P2-02: apps whose split panes get focus individually. Everything else — browsers,
    /// chat, documents — switches whole windows only (FR-P2-03), so page regions never steal focus.
    static let paneApps: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "com.vscodium", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
    ]

    static func hasPanes(_ pid: pid_t) -> Bool {
        guard let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return paneApps.contains(b) || b.hasPrefix("com.jetbrains.")
    }

    private var paneCache: [CGWindowID: (bounds: CGRect, at: TimeInterval, panes: [(frame: CGRect, element: AXUIElement)])] = [:]

    /// The windows on display `key`, front to back, with the split panes of terminal and editor
    /// windows, and which of them has focus now.
    public func layout(for key: DisplayKey, panes includePanes: Bool) -> ScreenLayout? {
        guard let d = displays.display(key) else { return nil }
        let wins = onScreenWindows().filter { isNormalWindow($0, on: d) }.prefix(8)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedWindow = windows.focused.flatMap { $0.pid == front ? $0.id : nil }
        var regions: [Region] = []
        var focused: String?
        for w in wins {
            let id = "w\(w.id)"
            if includePanes, Self.hasPanes(w.pid) {
                let panes = self.panes(of: w)
                if panes.count >= 2 {
                    for (i, p) in panes.enumerated() {
                        regions.append(Region(id: "\(id)p\(i)", windowID: w.id, pid: w.pid, frame: p.frame.intersection(d.bounds), isPane: true))
                    }
                    if w.id == focusedWindow, let f = AXUIElement.application(w.pid).element(kAXFocusedUIElementAttribute)?.frame,
                       let i = panes.firstIndex(where: { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) }) {
                        focused = "\(id)p\(i)"
                    }
                }
            }
            regions.append(Region(id: id, windowID: w.id, pid: w.pid, frame: w.bounds.intersection(d.bounds), isPane: false))
            if w.id == focusedWindow, focused == nil { focused = id }
        }
        paneCache = paneCache.filter { now() - $0.value.at < 30 }
        return ScreenLayout(display: key, bounds: d.bounds, regions: regions, focused: focused)
    }

    /// Text areas covering at least 8% of the window: one per terminal session or editor split.
    /// Cached for 5 s per window, or until it moves or resizes, since each read is IPC.
    private func panes(of w: WindowInfo) -> [(frame: CGRect, element: AXUIElement)] {
        if let c = paneCache[w.id], c.bounds == w.bounds, now() - c.at < 5 { return c.panes }
        let app = AXUIElement.application(w.pid)
        guard let window = (app.raw(kAXWindowsAttribute).value as? [AXUIElement])?.first(where: { $0.windowID == w.id }) else { return [] }
        let minArea = w.bounds.width * w.bounds.height * 0.08
        var found: [(frame: CGRect, element: AXUIElement)] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var next = 0
        // ponytail: breadth-first, at most 250 elements and 8 levels deep; Electron editors have
        // huge trees. Per-app known paths would be faster if an app needs it.
        while next < queue.count, next < 250 {
            let (el, depth) = queue[next]
            next += 1
            if el.string(kAXRoleAttribute) == kAXTextAreaRole, let f = el.frame, f.width * f.height >= minArea {
                found.append((f, el))
                continue
            }
            if depth < 8 { queue += el.elements(kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        // Reading order, so a pane keeps its index (and region id) between refreshes.
        found.sort { ($0.frame.minY.rounded(), $0.frame.minX) < ($1.frame.minY.rounded(), $1.frame.minX) }
        paneCache[w.id] = (w.bounds, now(), found)
        return found
    }

    /// FR-P2-01, 02: raise the region's window if it isn't focused, then focus the pane through
    /// AX. If the app ignores that, an opt-in click at the pane's centre does it (FR-P2-02).
    public func focus(region r: Region) -> FocusOutcome {
        let options = FocusOptions(.standard)
        if let bundle = NSRunningApplication(processIdentifier: r.pid)?.bundleIdentifier, options.excludedApps.contains(bundle) {
            return .skipped("excluded app")
        }
        let app = AXUIElement.application(r.pid)
        let info = WindowInfo(id: r.windowID, pid: r.pid, layer: 0, bounds: r.frame, alpha: 1, owner: "")
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if windows.focused?.id != r.windowID || front != r.pid {
            let (list, error) = app.raw(kAXWindowsAttribute)
            if error == .apiDisabled { onAXDisabled?(); return .skipped("Accessibility revoked") }
            if error == .cannotComplete { return skip("app not responding", info) }
            guard let element = (list as? [AXUIElement])?.first(where: { $0.windowID == r.windowID }) else {
                return .skipped("window not reachable through Accessibility")
            }
            if let failure = raise(info, element, app) { return failure }
            if let key = displays.display(containing: r.frame)?.key {
                windows.remember(WindowRef(pid: r.pid, id: r.windowID, element: element, frame: element.frame ?? r.frame), on: key)
            }
        }
        let centre = CGPoint(x: r.frame.midX, y: r.frame.midY)
        if r.isPane, let index = Int(r.id.split(separator: "p").last ?? ""), let pane = paneCache[r.windowID]?.panes[safe: index] {
            AXUIElementSetAttributeValue(pane.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(40_000) // let the app move its focus before checking
            let now = app.element(kAXFocusedUIElementAttribute)?.frame
            if !(now.map { r.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false) {
                guard options.paneClick else { return skip("app ignored pane focus (click fallback is off)", info) }
                click(at: centre)
            }
        }
        if options.movePointer {
            let last = displays.display(containing: r.frame).flatMap { input.lastPointer(on: $0.key) }.flatMap { r.frame.contains($0) ? $0 : nil }
            warp(to: last ?? centre)
        }
        onFocused?(r.frame)
        return .focusedWindow
    }

    /// The FR-P2-02 opt-in fallback: one left click. Our own events are ignored by the input
    /// monitor (FR-SAF-03), so it doesn't trip the mouse guard.
    private func click(at p: CGPoint) {
        input.noteWarp(to: p)
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    private func skip(_ reason: String, _ w: WindowInfo) -> FocusOutcome {
        log.info("skip window \(w.id) pid \(w.pid): \(reason, privacy: .public)")
        return .skipped(reason)
    }

    /// A normal app window (layer 0, visible, not tiny, not ours) with most of its area on `d`.
    private func isNormalWindow(_ w: WindowInfo, on d: DisplayInfo) -> Bool {
        w.layer == 0 && w.alpha > 0 && w.pid != ownPID && w.bounds.width >= 40 && w.bounds.height >= 40
            && overlapArea(w.bounds, d.bounds) >= 0.5 * w.bounds.width * w.bounds.height
    }

    private func warp(to p: CGPoint) {
        input.noteWarp(to: p) // before the warp, so any event it causes is recognised (FR-SAF-03)
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Why focus must stay where it is right now, or nil. Checked only at the moment a switch
    /// would happen, so its cost (one window list, a few AX reads) is off the per-frame path.
    public func blockingReason() -> String? {
        // §7: a password field is focused. Event taps see no keys then, so the typing guard is blind.
        if IsSecureEventInputEnabled() { return "secure input" }
        let front = NSWorkspace.shared.frontmostApplication
        if let b = front?.bundleIdentifier, FocusOptions(.standard).excludedApps.contains(b) { return "excluded app in front" } // FR-SAF-07
        // FR-SAF-06 by window layer and owner.
        let wins = onScreenWindows()
        if wins.contains(where: { $0.owner == "screencaptureui" }) { return "screenshot tool" }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        if wins.contains(where: { $0.layer == menuLevel && $0.alpha > 0 }) { return "menu open" }
        if windows.missionControlActive { return "Mission Control" }
        // FR-SAF-06 by AX role: modal dialogs and sheets in the frontmost app.
        if let pid = front?.processIdentifier, pid != ownPID,
           let win = AXUIElement.application(pid).element(kAXFocusedWindowAttribute) {
            if let sub = win.string(kAXSubroleAttribute), sub == kAXDialogSubrole || sub == kAXSystemDialogSubrole { return "dialog" }
            if win.bool(kAXModalAttribute) == true { return "modal window" }
            if win.elements(kAXChildrenAttribute).contains(where: { $0.string(kAXRoleAttribute) == kAXSheetRole }) { return "sheet" }
        }
        return nil
    }
}
