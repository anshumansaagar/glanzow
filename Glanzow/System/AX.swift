import AppKit
import ApplicationServices

/// §9: every Accessibility call runs on this one background actor, backed by its own serial
/// queue so a slow app never blocks the main thread or the Swift cooperative pool.
@globalActor public actor AXActor {
    public static let shared = AXActor()
    private let queue = DispatchSerialQueue(label: "dev.glanzow.ax", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
}

/// §7: an unresponsive app gets 0.25 s, then we skip it.
let axTimeout: Float = 0.25

/// Private but stable for over a decade (yabai, AltTab and Hammerspoon rely on it): the
/// CGWindowID behind an AX window. Public APIs offer only fuzzy frame matching.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        return app
    }

    func raw(_ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(self, attribute as CFString, &v)
        return (v, e)
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = raw(attribute).value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] { raw(attribute).value as? [AXUIElement] ?? [] }
    func string(_ attribute: String) -> String? { raw(attribute).value as? String }
    func bool(_ attribute: String) -> Bool? { (raw(attribute).value as? NSNumber)?.boolValue }

    /// Frame in global display coordinates (top-left origin).
    var frame: CGRect? {
        guard let p = raw(kAXPositionAttribute).value, let s = raw(kAXSizeAttribute).value,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(self, &p)
        return p
    }
}

/// One entry of CGWindowListCopyWindowInfo.
public struct WindowInfo: Sendable, Equatable {
    public var id: CGWindowID
    public var pid: pid_t
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double
    public var owner: String
}

/// On-screen windows front to back. Only windows on each display's active Space are on screen,
/// which is what FR-FOC-08 needs. Bounds and owners need no Screen Recording permission.
public func onScreenWindows() -> [WindowInfo] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return WindowInfo(id: id, pid: pid, layer: w[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                          alpha: w[kCGWindowAlpha as String] as? Double ?? 1, owner: w[kCGWindowOwnerName as String] as? String ?? "")
    }
}

/// A window someone focused: enough to find and raise it again.
public struct WindowRef: @unchecked Sendable { // AXUIElement is an immutable CF handle
    public var pid: pid_t
    public var id: CGWindowID
    public var element: AXUIElement
    public var frame: CGRect
}
