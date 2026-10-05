import AppKit

/// The menu bar mark: a four-point gleam. Filled while following you, outlined while holding,
/// faint when it can't see you, with a small badge when it needs something from you.
enum Glyph {
    enum Style { case following, holding, faint, attention, learning }

    static func image(_ style: Style, description: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let star = sparkle(center: CGPoint(x: 9, y: 9), radius: 7.4, waist: 1.6)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch style {
            case .following:
                star.fill()
            case .holding:
                star.lineWidth = 1.25
                star.stroke()
            case .faint:
                NSColor.black.withAlphaComponent(0.4).setFill()
                star.fill()
            case .attention:
                star.fill()
                // Punch a ring out of the lower right, then set a dot in it.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: CGRect(x: 10.6, y: 0.6, width: 7.2, height: 7.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: CGRect(x: 12.1, y: 2.1, width: 4.2, height: 4.2)).fill()
            case .learning:
                star.lineWidth = 1.25
                star.stroke()
                NSBezierPath(ovalIn: CGRect(x: 7.5, y: 7.5, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// Four points on the axes, joined by curves pulled in toward the centre.
    static func sparkle(center c: CGPoint, radius r: CGFloat, waist w: CGFloat) -> NSBezierPath {
        let tips = [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - r, y: c.y)]
        let pull = [CGPoint(x: c.x + w, y: c.y + w), CGPoint(x: c.x + w, y: c.y - w), CGPoint(x: c.x - w, y: c.y - w), CGPoint(x: c.x - w, y: c.y + w)]
        let path = NSBezierPath()
        path.move(to: tips[0])
        for i in 0..<4 { path.curve(to: tips[(i + 1) % 4], controlPoint1: pull[i], controlPoint2: pull[i]) }
        path.close()
        return path
    }
}
