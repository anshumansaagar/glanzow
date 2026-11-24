import AppKit
import GlanzowKit

/// FR-UI-03 flash on switch and FR-UI-05 persistent border on the focused window. Both use the
/// gleam: the flash is the light arriving, the border is it resting on the window.
/// The flash is bolder than FR-UI-03's 2 px / 400 ms at the user's request: gold alone vanished
/// on white windows. It is a 3 pt gold line on a dark edge (reads on light and dark windows),
/// inside a soft warm glow band, held for 250 ms before a 450 ms fade.
@MainActor final class FocusFeedback {
    /// One ring hugging the window from outside: `width` points wide, drawn lowest first.
    private struct Ring {
        var width: CGFloat
        var color: NSColor
        var glow: CGFloat = 0
    }

    private static let flashRings = [
        Ring(width: 12, color: Palette.gleam.withAlphaComponent(0.18), glow: 14), // warm band
        Ring(width: 4, color: Palette.night.withAlphaComponent(0.7)),              // dark edge
        Ring(width: 3, color: Palette.gleam),                                       // the line
    ]
    private static let activeRings = [
        Ring(width: 6, color: Palette.gleam.withAlphaComponent(0.12)),
        Ring(width: 2.5, color: Palette.night.withAlphaComponent(0.55)),
        Ring(width: 2, color: Palette.gleam),
    ]
    /// Room around the window for the glow to spread without clipping.
    private static let margin: CGFloat = 32

    private let flashPanel = FocusFeedback.panel(level: .screenSaver, rings: flashRings)
    private let activePanel = FocusFeedback.panel(level: .floating, rings: activeRings)
    private var flashGeneration = 0
    private var washPanel: NSPanel?
    private var washGeneration = 0
    /// The wash lies over what you are about to read, so it stays light: 60% was too strong.
    private static let washStrength: CGFloat = 0.35

    /// "Wash": for a moment the gleam washes over `area` (the whole screen after a move between
    /// screens, or just the window or pane that took focus within one) and the gold border marks
    /// `rect`, what took focus. Warm light reads on a white page and a dark editor alike.
    func wash(_ rect: CGRect, over area: CGRect, on display: CGRect) {
        let panel = washPanel ?? {
            let p = DebugOverlay.clickThroughPanel()
            p.level = .screenSaver
            p.backgroundColor = .clear
            let v = NSView()
            v.wantsLayer = true
            v.layer?.addSublayer(CAShapeLayer())
            for r in Self.activeRings { v.layer?.addSublayer(Self.layer(r)) }
            p.contentView = v
            washPanel = p
            return p
        }()
        let frame = cocoaRect(display)
        panel.setFrame(frame, display: false)
        let bounds = CGRect(origin: .zero, size: frame.size)
        func local(_ r: CGRect) -> CGRect { // flip into the view
            CGRect(x: r.minX - display.minX, y: display.maxY - r.maxY, width: r.width, height: r.height).intersection(bounds)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layers = panel.contentView?.layer?.sublayers, let shade = layers.first as? CAShapeLayer {
            shade.frame = bounds
            shade.path = Self.washPath(local(area), in: bounds)
            shade.fillColor = Palette.gleam.withAlphaComponent(Self.washStrength).cgColor
            Self.layout(Array(layers.dropFirst()), around: local(rect))
        }
        CATransaction.commit()
        washGeneration += 1
        let generation = washGeneration
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.08; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.washGeneration else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.4
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated { if generation == self.washGeneration { panel.orderOut(nil) } }
                }
            }
        }
    }

    /// A whole screen gets square edges; a window or pane gets the window's rounded corners.
    private static func washPath(_ area: CGRect, in bounds: CGRect) -> CGPath {
        if area.isEmpty { return CGMutablePath() }
        if area == bounds { return CGPath(rect: area, transform: nil) }
        let r = min(11, area.width / 2, area.height / 2) // CGPath rejects corners wider than half the rect
        return CGPath(roundedRect: area, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    func flash(_ rect: CGRect) {
        place(flashPanel, around: rect)
        flashGeneration += 1
        let generation = flashGeneration
        flashPanel.alphaValue = 1
        flashPanel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.flashGeneration else { return } // a newer flash took over
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.45
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.flashPanel.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, generation == self.flashGeneration else { return }
                        self.flashPanel.orderOut(nil)
                    }
                }
            }
        }
    }

    /// Persistent border like JankyBorders; nil hides it.
    func showActive(_ rect: CGRect?) {
        guard let rect else { activePanel.orderOut(nil); return }
        place(activePanel, around: rect)
        activePanel.orderFrontRegardless()
    }

    private func place(_ panel: NSPanel, around rect: CGRect) {
        let frame = cocoaRect(rect.insetBy(dx: -Self.margin, dy: -Self.margin))
        panel.setFrame(frame, display: false)
        let window = CGRect(origin: .zero, size: frame.size).insetBy(dx: Self.margin, dy: Self.margin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.layout(panel.contentView?.layer?.sublayers ?? [], around: window)
        CATransaction.commit()
    }

    /// Each ring's border is drawn inside its layer, so a ring `w` wide hugging the window from
    /// outside is a layer `w` larger on every side.
    private static func layout(_ rings: [CALayer], around window: CGRect) {
        for ring in rings {
            let w = ring.borderWidth
            ring.frame = window.insetBy(dx: -w, dy: -w)
            ring.cornerRadius = 11 + w // follows the macOS window corner outward
        }
    }

    private static func panel(level: NSWindow.Level, rings: [Ring]) -> NSPanel {
        let p = DebugOverlay.clickThroughPanel()
        p.level = level
        p.backgroundColor = .clear
        let v = NSView()
        v.wantsLayer = true
        for r in rings { v.layer?.addSublayer(layer(r)) }
        p.contentView = v
        return p
    }

    private static func layer(_ r: Ring) -> CALayer {
        let ring = CALayer()
        ring.borderWidth = r.width
        ring.borderColor = r.color.cgColor
        if r.glow > 0 {
            ring.shadowColor = Palette.gleam.cgColor
            ring.shadowOpacity = 0.9
            ring.shadowRadius = r.glow
            ring.shadowOffset = .zero
        }
        return ring
    }

    #if DEBUG
    /// The wash on a mock desktop: a white page focused beside a dark editor. `wholeScreen`: focus
    /// arrived from another screen; otherwise it moved between the two windows on this one.
    static func washPreview(wholeScreen: Bool) -> NSView {
        let size = CGSize(width: 960, height: 600)
        let v = NSView(frame: CGRect(origin: .zero, size: size))
        v.wantsLayer = true
        let desk = CAGradientLayer()
        desk.frame = v.bounds
        desk.colors = [NSColor(srgbRed: 0.42, green: 0.47, blue: 0.58, alpha: 1).cgColor, NSColor(srgbRed: 0.62, green: 0.55, blue: 0.62, alpha: 1).cgColor]
        v.layer?.addSublayer(desk)
        let editor = CALayer(); editor.frame = CGRect(x: 30, y: 40, width: 430, height: 520)
        editor.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor; editor.cornerRadius = 11
        let page = CALayer(); page.frame = CGRect(x: 490, y: 40, width: 440, height: 520)
        page.backgroundColor = NSColor.white.cgColor; page.cornerRadius = 11
        for l in [editor, page] { v.layer?.addSublayer(l) }
        for i in 0..<9 { // a few lines of "text" on each
            let a = CALayer(); a.frame = CGRect(x: 60, y: 500 - CGFloat(i) * 34, width: CGFloat(200 + (i * 37) % 160), height: 8)
            a.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor; a.cornerRadius = 4; v.layer?.addSublayer(a)
            let b = CALayer(); b.frame = CGRect(x: 520, y: 500 - CGFloat(i) * 34, width: CGFloat(220 + (i * 53) % 150), height: 8)
            b.backgroundColor = NSColor(white: 0.82, alpha: 1).cgColor; b.cornerRadius = 4; v.layer?.addSublayer(b)
        }
        let shade = CAShapeLayer()
        shade.path = washPath(wholeScreen ? v.bounds : page.frame, in: v.bounds)
        shade.fillColor = Palette.gleam.withAlphaComponent(washStrength).cgColor
        v.layer?.addSublayer(shade)
        let rings = activeRings.map(layer)
        rings.forEach { v.layer?.addSublayer($0) }
        layout(rings, around: page.frame)
        return v
    }

    /// The flash over a white and a dark window, for design snapshots.
    static func preview() -> NSView {
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 360))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.55, alpha: 1).cgColor
        for (i, fill) in [NSColor.white, NSColor(white: 0.12, alpha: 1)].enumerated() {
            let frame = CGRect(x: 60 + CGFloat(i) * 420, y: 60, width: 360, height: 240)
            let rings = flashRings.map(layer)
            rings.forEach { v.layer?.addSublayer($0) }
            layout(rings, around: frame)
            let window = CALayer()
            window.frame = frame
            window.backgroundColor = fill.cgColor
            window.cornerRadius = 11
            v.layer?.addSublayer(window)
        }
        return v
    }
    #endif
}
