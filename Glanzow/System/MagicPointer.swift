import CoreGraphics

/// MAGIC pointing (Zhai, Morimoto & Ihde, "Manual and gaze input cascaded pointing", CHI 1999):
/// gaze is too coarse to point with but good enough to get close, so when the hand starts to
/// move the mouse, the pointer jumps to near where the eyes are and the hand does the rest.
public enum MagicPointer {
    /// Where the pointer should jump as the mouse starts moving, or nil to leave it alone.
    /// - gaze: the estimated gaze point on the faced display, if within-screen gaze is known.
    /// - lastOnFaced: where the pointer last was on the faced display.
    public static func target(pointer p: CGPoint, gaze: CGPoint?, faced: DisplayInfo?, pointerDisplay: DisplayInfo?,
                              lastOnFaced: CGPoint?) -> CGPoint? {
        guard let faced else { return nil }
        // The gaze map may land a little past the screen's edge; the screen itself is known.
        let inner = faced.bounds.insetBy(dx: 20, dy: 20)
        if let raw = gaze {
            let g = CGPoint(x: min(max(raw.x, inner.minX), inner.maxX), y: min(max(raw.y, inner.minY), inner.maxY))
            // Only worth it when the pointer is far from where the user looks.
            return hypot(g.x - p.x, g.y - p.y) > max(260, faced.bounds.width * 0.2) ? g : nil
        }
        // Without a gaze point, at least bring the pointer to the screen being looked at.
        guard faced.key != pointerDisplay?.key else { return nil }
        if let last = lastOnFaced, faced.bounds.contains(last) { return last }
        return CGPoint(x: faced.bounds.midX, y: faced.bounds.midY)
    }
}
