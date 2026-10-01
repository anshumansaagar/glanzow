import CoreGraphics

/// Something on a display that can take keyboard focus: a window, or a split pane inside a
/// terminal or editor window (FR-P2-01, 02).
public struct Region: Sendable, Equatable {
    /// "w<window id>" for a window, "w<window id>p<index>" for one of its panes.
    public var id: String
    public var windowID: CGWindowID
    public var pid: pid_t
    /// Global display coordinates, clipped to the display.
    public var frame: CGRect
    public var isPane: Bool

    public init(id: String, windowID: CGWindowID, pid: pid_t, frame: CGRect, isPane: Bool) {
        self.id = id; self.windowID = windowID; self.pid = pid; self.frame = frame; self.isPane = isPane
    }
}

/// The focusable regions of the current display, refreshed by the app a few times a second.
public struct ScreenLayout: Sendable, Equatable {
    public var display: DisplayKey
    public var bounds: CGRect
    /// Front to back; a window's panes come right before the window itself.
    public var regions: [Region]
    /// The region holding keyboard focus now, if known.
    public var focused: String?

    public init(display: DisplayKey, bounds: CGRect, regions: [Region], focused: String?) {
        self.display = display; self.bounds = bounds; self.regions = regions; self.focused = focused
    }

    /// The frontmost region under `p`, but only if `p` is at least `inset` inside it: near a
    /// border between two regions the gaze estimate can't be trusted, so the answer is nil.
    public func region(at p: CGPoint, inset: CGFloat) -> Region? {
        guard let r = regions.first(where: { $0.frame.contains(p) }) else { return nil }
        let i = min(inset, r.frame.width / 4, r.frame.height / 4)
        return r.frame.insetBy(dx: i, dy: i).contains(p) ? r : nil
    }

    public var focusedRegion: Region? { focused.flatMap { id in regions.first { $0.id == id } } }
}
