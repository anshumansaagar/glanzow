import AppKit

/// The menu bar mark: the app icon's three panes, the one you look at lit. Lit while following
/// you, all unlit while holding, faint when it can't see you, with a small badge when it needs
/// something from you, and the calibration gleam while it learns.
enum Glyph {
    enum Style { case following, holding, faint, attention, learning }

    /// The panes on whole points, so 1-point lines stay crisp on 1× displays: a tall pane on the
    /// left, two stacked on the right, the top right one lit. Corners near the edge are rounder.
    private static let left = CGRect(x: 1, y: 1, width: 6, height: 16)
    private static let lit = CGRect(x: 9, y: 10, width: 8, height: 7)
    private static let low = CGRect(x: 9, y: 1, width: 8, height: 7)

    static func image(_ style: Style, description: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = NSColor.black.withAlphaComponent(style == .faint ? 0.4 : 1)
            ink.setFill()
            ink.setStroke()
            let unlit: [(CGRect, (CGFloat, CGFloat, CGFloat, CGFloat))] = [(left, (2.5, 1.5, 1.5, 2.5)), (low, (1.5, 3, 1.5, 1.5))]
            for (rect, corners) in unlit {
                outline(pane(rect.insetBy(dx: 0.5, dy: 0.5), corners))
            }
            let litPane = pane(lit, (1.5, 1.5, 3.0, 1.5))
            switch style {
            case .following, .faint, .attention:
                litPane.fill()
            case .holding:
                outline(pane(lit.insetBy(dx: 0.5, dy: 0.5), (1.5, 1.5, 3.0, 1.5)))
            case .learning:
                outline(pane(lit.insetBy(dx: 0.5, dy: 0.5), (1.5, 1.5, 3.0, 1.5)))
                NSBezierPath(ovalIn: CGRect(x: lit.midX - 1.75, y: lit.midY - 1.75, width: 3.5, height: 3.5)).fill()
            }
            if style == .attention { // punch a ring out of the lower right, then set a dot in it
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: CGRect(x: 10.5, y: -0.5, width: 8, height: 8)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: CGRect(x: 12.25, y: 1.25, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private static func outline(_ path: NSBezierPath) {
        path.lineWidth = 1
        path.stroke()
    }

    /// A rounded rectangle with its own radius per corner: bottom-left, bottom-right, top-right,
    /// top-left (y up).
    private static func pane(_ r: CGRect, _ c: (CGFloat, CGFloat, CGFloat, CGFloat)) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: r.minX + c.0, y: r.minY))
        p.appendArc(from: CGPoint(x: r.maxX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY), radius: c.1)
        p.appendArc(from: CGPoint(x: r.maxX, y: r.maxY), to: CGPoint(x: r.minX, y: r.maxY), radius: c.2)
        p.appendArc(from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.minX, y: r.minY), radius: c.3)
        p.appendArc(from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.minY), radius: c.0)
        p.close()
        return p
    }
}
