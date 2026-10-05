import AppKit
import SwiftUI
import GlanzowKit

/// Eye breaks: a small pill at the top of the screen. Its ring fills while the user looks
/// away, and it finishes on its own. Never takes focus; only "Later" is clickable.
@MainActor final class EyeBreakPill {
    private var panel: NSPanel?
    private var host: FirstClickHostingView<PillView>?
    var onLater: (() -> Void)?

    func show(progress: Double) {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let h = FirstClickHostingView(rootView: PillView(progress: progress, done: false, later: { [weak self] in self?.onLater?() }))
            p.contentView = h
            panel = p
            host = h
            let size = h.fittingSize
            if let screen = NSScreen.main {
                let v = screen.visibleFrame
                p.setFrame(CGRect(x: v.midX - size.width / 2, y: v.maxY - size.height - 10, width: size.width, height: size.height), display: true)
            }
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 1 }
            NSAccessibility.post(element: h, notification: .announcementRequested,
                                 userInfo: [.announcement: "Rest your eyes: look at something far away for 20 seconds.",
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        host?.rootView = PillView(progress: progress, done: false, later: { [weak self] in self?.onLater?() })
    }

    /// The break is done: say so briefly, then go.
    func finish() {
        guard panel != nil else { return }
        host?.rootView = PillView(progress: 1, done: true, later: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.hide() }
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        host = nil
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 0 } completionHandler: {
            MainActor.assumeIsolated { p.orderOut(nil) }
        }
    }
}

#if DEBUG
enum EyeOverlayPreviews {
    static func pill(progress: Double) -> NSView { NSHostingView(rootView: PillView(progress: progress, done: false, later: {})) }
    static func veil() -> NSView { NSHostingView(rootView: VeilMessage().frame(width: 900, height: 420).background(.ultraThinMaterial)) }
}
#endif

private struct PillView: View {
    let progress: Double
    let done: Bool
    let later: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: progress).stroke(Color(nsColor: Palette.gleam), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: done ? "checkmark" : "leaf").font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(done ? "Nicely done" : "Rest your eyes").font(.system(size: 13, weight: .semibold))
                Text(done ? "See you in 20 minutes" : "Look at something far away for 20 seconds")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if !done {
                Button("Later", action: later).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(8) // room for the shadow
    }
}

/// The pill's panel never becomes key, so without this its first click would only focus it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Privacy guard: frosted glass over every screen, drawn by the window server from what's
/// behind it (no screen capture involved). Any key or click lifts it.
@MainActor final class PrivacyVeil {
    private var panels: [NSPanel] = []

    var isShown: Bool { !panels.isEmpty }

    func show() {
        guard panels.isEmpty else { return }
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = .clear
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let glass = NSVisualEffectView(frame: CGRect(origin: .zero, size: screen.frame.size))
            glass.material = .fullScreenUI
            glass.blendingMode = .behindWindow
            glass.state = .active
            let label = NSHostingView(rootView: VeilMessage())
            label.frame = glass.bounds
            label.autoresizingMask = [.width, .height]
            glass.addSubview(label)
            p.contentView = glass
            p.setAccessibilityLabel("Privacy guard: someone else is looking at your screen. Press any key or click to continue.")
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
            panels.append(p)
        }
    }

    func hide() {
        let leaving = panels
        panels = []
        for p in leaving {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 0 } completionHandler: {
                MainActor.assumeIsolated { p.orderOut(nil) }
            }
        }
    }
}

private struct VeilMessage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 34, weight: .regular))
            Text("Someone else is looking at your screen").font(.system(size: 22, weight: .semibold).width(.expanded))
            Text("Press any key or click to continue").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
