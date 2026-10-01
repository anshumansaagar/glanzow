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
}

public struct FocusOptions: Sendable {
    public var movePointer = true
    public var excludedApps: Set<String> = []

    public init(_ d: UserDefaults) {
        movePointer = d.bool(forKey: Pref.movePointer)
        excludedApps = Set(d.stringArray(forKey: Pref.excludedApps) ?? [])
    }
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
        guard let info = remembered?.1 ?? candidates.first else {
            // FR-FOC-05: an empty display gets the pointer only, so new windows and Spaces follow.
            guard options.movePointer else { return .skipped("no window") }
            warp(to: input.lastPointer(on: key) ?? CGPoint(x: d.bounds.midX, y: d.bounds.midY))
            onFocused?(d.bounds)
            return .pointerOnly
        }
        // SPEC: FR-SAF-07 says never switch into an excluded app. Raising the next window behind
        // it instead would cover the call or game, so the switch does nothing at all.
        if let bundle = NSRunningApplication(processIdentifier: info.pid)?.bundleIdentifier, options.excludedApps.contains(bundle) {
            return .skipped("excluded app")
        }
        let app = AXUIElement.application(info.pid)
        let (windowList, listError) = app.raw(kAXWindowsAttribute)
        if listError == .apiDisabled { onAXDisabled?(); return .skipped("Accessibility revoked") }
        if listError == .cannotComplete { return skip("app not responding", info) } // §7 AX timeout
        guard let element = remembered?.0.element ?? (windowList as? [AXUIElement])?.first(where: { $0.windowID == info.id }) else {
            return skip("window not reachable through Accessibility", info)
        }
        AXUIElementSetMessagingTimeout(element, axTimeout)

        // FR-FOC-04: raise and activate. Never a synthetic click in V1.
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
        // ponytail: Mission Control shows as Dock-owned windows covering a whole display; a
        // private CGS query would be exact if this heuristic ever misfires.
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        if wins.contains(where: { w in
            w.owner == "Dock" && w.layer >= dockLevel && w.alpha > 0
                && displays.displays.contains { overlapArea(w.bounds, $0.bounds) >= 0.9 * $0.bounds.width * $0.bounds.height }
        }) { return "Mission Control" }
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
