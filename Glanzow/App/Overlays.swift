import AppKit
import GlanzowKit

/// FR-UI-03 flash on switch and FR-UI-05 persistent border on the focused window.
@MainActor final class FocusFeedback {
    private let flashPanel = FocusFeedback.borderPanel(level: .screenSaver)
    private let activePanel = FocusFeedback.borderPanel(level: .floating)

    /// 2 px border around `rect` (global coordinates), fading out over 400 ms.
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
        let frame = cocoaRect(rect.insetBy(dx: -2, dy: -2))
        panel.setFrame(frame, display: false)
        let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
        panel.contentView?.layer?.borderWidth = 2 / scale // 2 physical pixels
        panel.contentView?.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    private static func borderPanel(level: NSWindow.Level) -> NSPanel {
        let p = DebugOverlay.clickThroughPanel()
        p.level = level
        p.backgroundColor = .clear
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        p.contentView = v
        return p
    }
}
