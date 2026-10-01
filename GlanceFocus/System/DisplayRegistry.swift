import AppKit
import CoreGraphics
import os

public typealias DisplayKey = String

/// A connected display. `bounds` is in global display coordinates (points, top-left origin), the
/// same space as CGWindowList bounds, AX window frames and CGWarpMouseCursorPosition.
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public var id: CGDirectDisplayID
    public var key: DisplayKey
    public var name: String
    public var bounds: CGRect
    public var isBuiltin: Bool
    /// True when an identical monitor without a distinct serial forced keying by position.
    public var ambiguous: Bool

    public init(id: CGDirectDisplayID, key: DisplayKey, name: String, bounds: CGRect, isBuiltin: Bool, ambiguous: Bool = false) {
        self.id = id; self.key = key; self.name = name; self.bounds = bounds; self.isBuiltin = isBuiltin; self.ambiguous = ambiguous
    }
}

/// What CoreGraphics reports for one display, before we derive its stable key.
public struct RawDisplay: Sendable {
    public var id: CGDirectDisplayID
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var bounds: CGRect
    public var name: String
    public var isBuiltin: Bool

    public init(id: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32, bounds: CGRect, name: String, isBuiltin: Bool) {
        self.id = id; self.vendor = vendor; self.model = model; self.serial = serial; self.bounds = bounds; self.name = name; self.isBuiltin = isBuiltin
    }
}

public enum DisplayIdentity {
    /// FR-CAL-04: key by vendor, model and serial, never by CGDirectDisplayID or list index, so a
    /// re-plugged or rearranged monitor finds its calibration again. Only when two displays share
    /// all three (identical models with a missing or duplicated serial) does arrangement position
    /// break the tie, and those displays are flagged so the app can warn (§7).
    public static func assignKeys(_ raws: [RawDisplay]) -> [DisplayInfo] {
        let base = { (r: RawDisplay) in "\(r.vendor)-\(r.model)-\(r.serial)" }
        let groups = Dictionary(grouping: raws, by: base)
        return raws.map { r in
            let group = groups[base(r)]!
            guard group.count > 1 else {
                return DisplayInfo(id: r.id, key: base(r), name: r.name, bounds: r.bounds, isBuiltin: r.isBuiltin)
            }
            let ordered = group.sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
            let index = ordered.firstIndex { $0.id == r.id }!
            return DisplayInfo(id: r.id, key: "\(base(r))-p\(index)", name: "\(r.name) (\(index + 1))",
                               bounds: r.bounds, isBuiltin: r.isBuiltin, ambiguous: true)
        }
    }
}

public func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    return i.isNull ? 0 : i.width * i.height
}

/// Connected displays, their identity and geometry, and reconfiguration events (FR-CAL-07).
public final class DisplayRegistry: @unchecked Sendable {
    public static let shared = DisplayRegistry()
    private let state = OSAllocatedUnfairLock(initialState: [DisplayInfo]())
    private let log = logger("displays")
    private var pending: DispatchWorkItem?
    /// Called on the main thread after the display set or arrangement settles.
    public var onChange: (@MainActor ([DisplayInfo]) -> Void)?

    public var displays: [DisplayInfo] { state.withLock { $0 } }

    @MainActor public func start() {
        refresh()
        CGDisplayRegisterReconfigurationCallback({ _, flags, info in
            guard !flags.contains(.beginConfigurationFlag), let info else { return }
            let me = Unmanaged<DisplayRegistry>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { me.scheduleRefresh() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// One callback fires per display per change; wait for the burst to finish.
    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.onChange?(self.displays)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @MainActor public func refresh() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, s.localizedName)
        }, uniquingKeysWith: { a, _ in a })
        // Mirrored displays share one picture; only the mirror-set primary counts.
        let raws = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map { id in
            RawDisplay(id: id, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                       serial: CGDisplaySerialNumber(id), bounds: CGDisplayBounds(id),
                       name: names[id] ?? "Display \(id)", isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
        let list = DisplayIdentity.assignKeys(raws)
        state.withLock { $0 = list }
        for d in list { log.info("display \(d.name, privacy: .public) key=\(d.key, privacy: .public) bounds=\(d.bounds.debugDescription, privacy: .public)") }
    }

    public func display(_ key: DisplayKey) -> DisplayInfo? { displays.first { $0.key == key } }

    /// The display holding most of `rect`, or nil if it is on none of them.
    public func display(containing rect: CGRect) -> DisplayInfo? {
        let best = displays.map { ($0, overlapArea($0.bounds, rect)) }.max { $0.1 < $1.1 }
        return (best?.1 ?? 0) > 0 ? best?.0 : nil
    }

    public func display(at point: CGPoint) -> DisplayInfo? { displays.first { $0.bounds.contains(point) } }
}

/// Global display coordinates (top-left origin) → AppKit screen coordinates (bottom-left origin
/// of the primary display), for placing overlay windows.
@MainActor public func cocoaRect(_ r: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}
