import AppKit
import ApplicationServices
import Carbon
import os

public enum FocusOutcome: Sendable, Equatable {
    case focusedWindow
    /// A split pane took focus; the string says how (accessibility, shortcut, click, already).
    case focusedPane(String)
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
    static let paneApps: Set<String> = Set([
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
    ]).union(electronApps)
    /// Electron editors build their accessibility tree only once an assistive app asks for it.
    static let electronApps: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.vscodium"]

    static func bundle(_ pid: pid_t) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    static func hasPanes(_ pid: pid_t) -> Bool {
        guard let b = bundle(pid) else { return false }
        return paneApps.contains(b) || b.hasPrefix("com.jetbrains.")
    }

    private var paneCache: [CGWindowID: (bounds: CGRect, at: TimeInterval, panes: [(frame: CGRect, element: AXUIElement)])] = [:]
    private var electronAsked: Set<pid_t> = []
    private var reachableCache: [CGWindowID: (ok: Bool, at: TimeInterval)] = [:]

    /// The windows on display `key`, front to back, with the split panes of terminal and editor
    /// windows, and which of them has focus now.
    public func layout(for key: DisplayKey, panes includePanes: Bool) -> ScreenLayout? {
        let started = PerfMeter.clock()
        defer { PerfMeter.shared.layout(PerfMeter.clock() - started) }
        guard let d = displays.display(key) else { return nil }
        let wins = onScreenWindows().filter { isNormalWindow($0, on: d) && isReachable($0) }.prefix(8)
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
                    if w.id == focusedWindow, let i = Self.focusedPane(of: AXUIElement.application(w.pid), among: panes) {
                        focused = "\(id)p\(i)"
                    }
                }
            }
            regions.append(Region(id: id, windowID: w.id, pid: w.pid, frame: w.bounds.intersection(d.bounds), isPane: false))
            if w.id == focusedWindow, focused == nil { focused = id }
        }
        paneCache = paneCache.filter { now() - $0.value.at < 30 }
        if reachableCache.count > 300 { reachableCache = reachableCache.filter { now() - $0.value.at < 600 } }
        return ScreenLayout(display: key, bounds: d.bounds, regions: regions, focused: focused)
    }

    /// Some layer-0 windows have no Accessibility counterpart (iTerm2 lays one over its tab bar;
    /// helper overlays), so they can't take focus and must not be regions. Answered per app in one
    /// read and remembered; a "no" is checked again after 5 s, since a brand-new window can be
    /// listed before its app reports it.
    private func isReachable(_ w: WindowInfo) -> Bool {
        if let known = reachableCache[w.id], known.ok || now() - known.at < 5 { return known.ok }
        let (list, error) = AXUIElement.application(w.pid).raw(kAXWindowsAttribute)
        guard error == .success else { return true } // a busy app: let the switch itself find out
        let t = now()
        for id in (list as? [AXUIElement] ?? []).compactMap(\.windowID) { reachableCache[id] = (true, t) }
        if reachableCache[w.id]?.ok != true { reachableCache[w.id] = (false, t) }
        return reachableCache[w.id]!.ok
    }

    /// Which pane holds the app's keyboard focus. Terminals focus the pane's text view itself,
    /// editors something inside the pane, so the focused element and its ancestors are compared
    /// by identity. Geometry is only the fallback: a terminal pane reports its whole scrollback as
    /// its frame, so the focused element's centre can sit far above the screen.
    static func focusedPane(of app: AXUIElement, among panes: [(frame: CGRect, element: AXUIElement)]) -> Int? {
        guard let focused = app.element(kAXFocusedUIElementAttribute) else { return nil }
        var el: AXUIElement? = focused
        for _ in 0..<12 {
            guard let e = el else { break }
            if let i = panes.firstIndex(where: { CFEqual($0.element, e) }) { return i }
            el = e.element(kAXParentAttribute)
        }
        guard let f = focused.frame else { return nil }
        return panes.firstIndex { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) }
    }

    /// The panes of one window, cached for 10 s or until it moves or resizes, since each read is IPC.
    private func panes(of w: WindowInfo) -> [(frame: CGRect, element: AXUIElement)] {
        if let c = paneCache[w.id], c.bounds == w.bounds, now() - c.at < 10 { return c.panes }
        let app = AXUIElement.application(w.pid)
        guard let window = (app.raw(kAXWindowsAttribute).value as? [AXUIElement])?.first(where: { $0.windowID == w.id }) else { return [] }
        let minArea = w.bounds.width * w.bounds.height * 0.08
        var found: [(frame: CGRect, element: AXUIElement)]
        if let b = Self.bundle(w.pid), Self.electronApps.contains(b) {
            if electronAsked.insert(w.pid).inserted {
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            found = Self.editorGroups(in: window, minArea: minArea)
        } else {
            found = Self.textAreas(in: window, minArea: minArea)
        }
        // Reading order, so a pane keeps its index (and region id) between refreshes.
        found.sort { ($0.frame.minY.rounded(), $0.frame.minX) < ($1.frame.minY.rounded(), $1.frame.minX) }
        paneCache[w.id] = (w.bounds, now(), found)
        return found
    }

    /// Terminals and native editors: one large text area per session or split. A terminal's text
    /// area is as tall as its whole scrollback, so each is cut to its scroll area: what's on screen.
    // ponytail: breadth-first, at most 250 elements and 8 levels deep. Per-app known paths would
    // be faster if an app's tree turns out deep.
    static func textAreas(in root: AXUIElement, minArea: CGFloat) -> [(frame: CGRect, element: AXUIElement)] {
        var found: [(frame: CGRect, element: AXUIElement)] = []
        var queue: [(element: AXUIElement, depth: Int, visible: CGRect)] = [(root, 0, root.frame ?? .infinite)]
        var next = 0
        while next < queue.count, next < 250 {
            let (el, depth, visible) = queue[next]
            next += 1
            let role = el.string(kAXRoleAttribute)
            if role == kAXTextAreaRole, let f = el.frame?.intersection(visible), !f.isNull, f.width * f.height >= minArea {
                found.append((f, el))
                continue
            }
            let inner = role == kAXScrollAreaRole ? el.frame.map { $0.intersection(visible) } ?? visible : visible
            if depth < 8 { queue += el.elements(kAXChildrenAttribute).map { ($0, depth + 1, inner) } }
        }
        return found
    }

    /// VS Code and its forks: every editor group holds a `monaco-editor` element, visible through
    /// Chromium's DOM class attribute. Workbench parts that can't hold editors (side bar, panel,
    /// status bar, lists) are skipped so the walk stays short in these very large trees.
    static func editorGroups(in root: AXUIElement, minArea: CGFloat) -> [(frame: CGRect, element: AXUIElement)] {
        let skipParts: Set<String> = ["sidebar", "activitybar", "statusbar", "titlebar", "auxiliarybar", "panel", "banner"]
        var found: [(frame: CGRect, element: AXUIElement)] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var next = 0
        while next < queue.count, next < 600 {
            let (el, depth) = queue[next]
            next += 1
            let classes = Set(el.raw("AXDOMClassList").value as? [String] ?? [])
            if classes.contains("monaco-editor"), let f = el.frame, f.width * f.height >= minArea {
                found.append((f, el))
                continue
            }
            if classes.contains("part") && !classes.isDisjoint(with: skipParts) { continue }
            if classes.contains("monaco-list") || classes.contains("minimap") { continue }
            if depth < 40 { queue += el.elements(kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        return found
    }

    /// FR-P2-01, 02: raise the region's window if it isn't focused, then move focus to the pane.
    public func focus(region r: Region) -> FocusOutcome {
        let options = FocusOptions(.standard)
        let bundle = Self.bundle(r.pid) ?? "pid \(r.pid)"
        if options.excludedApps.contains(bundle) { return .skipped("excluded app") }
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
        var outcome = FocusOutcome.focusedWindow
        if r.isPane, let index = Int(r.id.split(separator: "p").last ?? ""), let panes = paneCache[r.windowID]?.panes, panes.indices.contains(index) {
            if !(windows.focused?.id == r.windowID) { usleep(60_000) } // a just-raised window needs a moment to take key focus
            let (method, trail) = focusPane(index, of: panes, region: r, app: app, options: options)
            guard let method else { return skip("\(bundle) didn't move focus to the pane (\(trail))", info) }
            outcome = .focusedPane(method)
        }
        if options.movePointer {
            let last = displays.display(containing: r.frame).flatMap { input.lastPointer(on: $0.key) }.flatMap { r.frame.contains($0) ? $0 : nil }
            warp(to: last ?? CGPoint(x: r.frame.midX, y: r.frame.midY))
        }
        onFocused?(r.frame)
        return outcome
    }

    /// Moves focus into pane `index`, and says how: first the plain Accessibility request; if the
    /// app ignores it, the app's own "focus the pane to the left/right/above/below" shortcut, aimed
    /// from the pane that has focus now; last, the opt-in click. Each step is checked against which
    /// pane the app says has focus, so a remapped shortcut or a refusal fails safely. The trail of
    /// what was tried goes into the switch log when nothing worked.
    private func focusPane(_ index: Int, of panes: [(frame: CGRect, element: AXUIElement)], region r: Region,
                           app: AXUIElement, options: FocusOptions) -> (method: String?, trail: String) {
        func current() -> Int? { Self.focusedPane(of: app, among: panes) }
        var trail: [String] = []
        if current() == index { return ("already", "") }
        let set = AXUIElementSetAttributeValue(panes[index].element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if set == .success {
            usleep(40_000)
            if current() == index { return ("accessibility", "") }
            trail.append("accessibility ignored")
        } else {
            trail.append("accessibility refused (\(set.rawValue))")
        }
        let target = CGPoint(x: r.frame.midX, y: r.frame.midY)
        if let keys = PaneKeys(bundle: Self.bundle(r.pid)) {
            for _ in 0..<3 { // up to three hops across a grid of panes
                // Keystrokes go to this app's process only, and only while it is the one in front.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == r.pid else { trail.append("app not in front"); break }
                guard let from = current().map({ panes[$0].frame }) else { trail.append("focus outside the panes"); break }
                let arrow = keys.move(toward: target, from: CGPoint(x: from.midX, y: from.midY), pid: r.pid)
                trail.append("key \(PaneKeys.name(arrow))")
                usleep(90_000)
                if current() == index { return ("shortcut", "") }
            }
        }
        if options.paneClick, Self.point(target, isInside: r.frame, of: r.pid) {
            click(at: target)
            return ("click", "")
        }
        trail.append("focus on \(current().map { "pane \($0)" } ?? "no pane")")
        return (nil, trail.joined(separator: ", "))
    }

    /// The click fallback fires only if the element under the point belongs to the target app and
    /// lies inside the pane — never on whatever window happens to be on top there now.
    static func point(_ p: CGPoint, isInside frame: CGRect, of pid: pid_t) -> Bool {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &element) == .success,
              let element, element.pid == pid, let f = element.frame else { return false }
        return frame.insetBy(dx: -2, dy: -2).contains(f)
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
        }
        // A sheet holds the app's keyboard focus: ask the focused element for its top-level
        // container instead of listing every child of the window (slow in big apps).
        if let pid = front?.processIdentifier, pid != ownPID,
           let top = AXUIElement.application(pid).element(kAXFocusedUIElementAttribute)?.element(kAXTopLevelUIElementAttribute),
           top.string(kAXRoleAttribute) == kAXSheetRole {
            return "sheet"
        }
        return nil
    }
}
