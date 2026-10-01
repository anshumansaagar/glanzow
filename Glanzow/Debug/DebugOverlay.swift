import AppKit

/// FR-UI-04: a click-through HUD with live pose, classification and guard state, plus a dot on
/// the display the classifier currently picks.
@MainActor public final class DebugOverlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot: NSPanel

    public init() {
        panel = Self.clickThroughPanel()
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.frame.origin = CGPoint(x: 10, y: 8)
        panel.contentView?.addSubview(label)

        dot = Self.clickThroughPanel()
        dot.setContentSize(CGSize(width: 18, height: 18))
        dot.backgroundColor = .clear
        let circle = NSView(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 9
        circle.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
        dot.contentView = circle
    }

    public static func clickThroughPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }

    public var isVisible: Bool { panel.isVisible }

    public func hide() {
        panel.orderOut(nil)
        dot.orderOut(nil)
    }

    /// `gaze` is in global display coordinates; nil hides the dot.
    public func update(_ text: String, gaze: CGPoint?) {
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 20, height: label.frame.height + 16)
        if let screen = NSScreen.screens.first {
            let v = screen.visibleFrame
            panel.setFrame(CGRect(x: v.maxX - size.width - 12, y: v.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        if let gaze {
            let r = cocoaRect(CGRect(x: gaze.x - 9, y: gaze.y - 9, width: 18, height: 18))
            dot.setFrame(r, display: true)
            dot.orderFrontRegardless()
        } else {
            dot.orderOut(nil)
        }
    }
}
