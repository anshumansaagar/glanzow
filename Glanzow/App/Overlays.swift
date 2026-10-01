import AppKit
import GlanzowKit

/// FR-UI-03 flash on switch and FR-UI-05 persistent border on the focused window. Both use the
/// gleam: the flash is the light arriving, the border is it resting on the window.
@MainActor final class FocusFeedback {
    private let flashPanel = FocusFeedback.borderPanel(level: .screenSaver, glow: 0.9)
    private let activePanel = FocusFeedback.borderPanel(level: .floating, glow: 0.35)
    /// Room around the window for the glow to spread without clipping.
    private static let margin: CGFloat = 12

    /// 2 px gleam border around `rect` (global coordinates) that glows and fades over 400 ms.
    func flash(_ rect: CGRect) {
        place(flashPanel, around: rect)
        flashPanel.alphaValue = 1
        flashPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            flashPanel.animator().alphaValue = 0
        } completionHandler: { [flashPanel] in
            MainActor.assumeIsolated { flashPanel.orderOut(nil) }
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
        guard let ring = panel.contentView?.layer?.sublayers?.first else { return }
        let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = CGRect(origin: .zero, size: frame.size).insetBy(dx: Self.margin - 1, dy: Self.margin - 1)
        ring.borderWidth = 2 / scale // 2 physical pixels
        CATransaction.commit()
    }

    private static func borderPanel(level: NSWindow.Level, glow: Float) -> NSPanel {
        let p = DebugOverlay.clickThroughPanel()
        p.level = level
        p.backgroundColor = .clear
        let v = NSView()
        v.wantsLayer = true
        let ring = CALayer()
        ring.borderColor = Palette.gleam.cgColor
        ring.cornerRadius = 11 // close to macOS window corners
        ring.shadowColor = Palette.gleam.cgColor
        ring.shadowOpacity = glow
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        v.layer?.addSublayer(ring)
        p.contentView = v
        return p
    }
}
