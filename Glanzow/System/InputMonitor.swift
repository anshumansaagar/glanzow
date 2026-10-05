import AppKit
import CoreGraphics
import os

/// When the user last typed and last used the mouse, for the guards in SwitchController.
public protocol InputMonitor: AnyObject, Sendable {
    var lastKeystroke: TimeInterval { get }
    var lastMouseActivity: TimeInterval { get }
}

/// Listen-only CGEventTap (§9). Records timestamps only — never key codes or characters — plus
/// pointer positions (for FR-FOC-06) and click locations (for FR-LRN-01).
public final class EventTapInputMonitor: InputMonitor, @unchecked Sendable {
    public struct Click: Sendable {
        public var time: TimeInterval
        public var location: CGPoint
    }

    private struct State {
        var key = -Double.infinity
        var mouse = -Double.infinity
        var warp: (t: TimeInterval, p: CGPoint)?
        var fnDown = false
        var lastFnPress = -Double.infinity
        var pointer: [DisplayKey: CGPoint] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)
    private let displays: DisplayRegistry

    /// Set before `start()`; called on the main thread.
    public var onClick: ((Click) -> Void)?
    /// FR-SAF-08: the confirm key (`confirmFlag`, Fn by default) pressed twice within 0.4 s.
    public var onConfirm: ((TimeInterval) -> Void)?
    public var confirmFlag: CGEventFlags = .maskSecondaryFn

    public static func confirmFlag(named name: String) -> CGEventFlags {
        switch name {
        case "control": .maskControl
        case "option": .maskAlternate
        case "command": .maskCommand
        default: .maskSecondaryFn
        }
    }
    /// Debug recorder hook: `.key` / `.mouse` activity timestamps.
    public var onActivity: ((RecordedEvent.Kind, TimeInterval) -> Void)?

    public init(displays: DisplayRegistry = .shared) { self.displays = displays }

    public var lastKeystroke: TimeInterval { state.withLock { $0.key } }
    public var lastMouseActivity: TimeInterval { state.withLock { $0.mouse } }
    public var isRunning: Bool { tap != nil }

    /// False when the tap cannot be created: the app needs Input Monitoring (or Accessibility).
    @MainActor public func start() -> Bool {
        guard tap == nil else { return true }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                    .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel]
        for t in types { mask |= 1 << t.rawValue }
        for gesture: UInt64 in [29, 30, 31] { mask |= 1 << gesture } // trackpad gesture, magnify, swipe
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon { Unmanaged<EventTapInputMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    /// FR-SAF-03: our own pointer warp must not look like the user moving the mouse.
    public func noteWarp(to p: CGPoint) { state.withLock { $0.warp = (now(), p) } }

    public func lastPointer(on key: DisplayKey) -> CGPoint? { state.withLock { $0.pointer[key] } }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // FR-SAF-03: ignore anything this process posted.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == ownPID { return }
        let t = now()
        switch type {
        case .keyDown:
            state.withLock { $0.key = t } // timestamp only
            onActivity?(.key, t)
        case .flagsChanged:
            let fn = event.flags.contains(confirmFlag)
            let confirmed = state.withLock { s -> Bool in
                defer { s.fnDown = fn }
                guard fn, !s.fnDown else { return false } // press edge only
                defer { s.lastFnPress = t }
                return t - s.lastFnPress < 0.4
            }
            if confirmed { onConfirm?(t) }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let p = event.location
            let own = state.withLock { s in s.warp.map { t - $0.t < 0.15 && hypot(p.x - $0.p.x, p.y - $0.p.y) < 2 } ?? false }
            guard !own else { return }
            PerfMeter.shared.mouseEvent()
            let key = displays.display(at: p)?.key
            state.withLock { s in
                s.mouse = t
                if let key { s.pointer[key] = p }
            }
            onActivity?(.mouse, t)
        case .leftMouseDown, .rightMouseDown:
            state.withLock { $0.mouse = t }
            onActivity?(.mouse, t)
            onClick?(Click(time: t, location: event.location))
        default: // other buttons, scrolls, trackpad gestures
            state.withLock { $0.mouse = t }
            onActivity?(.mouse, t)
        }
    }
}
