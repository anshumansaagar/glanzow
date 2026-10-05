#if DEBUG
import AppKit
import SwiftUI
import GlanzowKit

/// Debug builds only: `Glanzow --snapshots <dir>` renders the welcome steps and a calibration
/// screen to PNG, so the design can be reviewed without granting any permission.
@MainActor enum Snapshots {
    static func write(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = AppModel()
        model.preview(displays: [ // the arrangement on the developer's desk: two monitors, laptop below
            DisplayInfo(id: 1, key: "l", name: "Left", bounds: CGRect(x: -1920, y: -1080, width: 1920, height: 1080), isBuiltin: false),
            DisplayInfo(id: 2, key: "r", name: "Right", bounds: CGRect(x: 0, y: -1080, width: 1920, height: 1080), isBuiltin: false),
            DisplayInfo(id: 3, key: "m", name: "MacBook", bounds: CGRect(x: -864, y: 0, width: 1728, height: 1117), isBuiltin: true),
        ])
        for dark in [false, true] {
            let host = NSHostingView(rootView: OnboardingView(model: model))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            save(host, size: CGSize(width: 620, height: 560), dir.appending(path: "onboarding-\(dark ? "dark" : "light").png"))
        }
        // A split view won't draw off-screen, so each settings page is rendered on its own.
        let pages: [(String, AnyView)] = [
            ("following", AnyView(FollowingSettings(model: model))), ("windows", AnyView(WindowsSettings())),
            ("eyes", AnyView(EyesSettings())), ("feel", AnyView(FeelSettings())), ("screens", AnyView(ScreensSettings(model: model))),
            ("shortcuts", AnyView(ShortcutSettings())), ("privacy", AnyView(PrivacySettings(model: model))),
        ]
        for (name, page) in pages {
            save(NSHostingView(rootView: page), size: CGSize(width: 570, height: 560), dir.appending(path: "settings-\(name).png"))
        }
        model.previewLive()
        for dark in [false, true] {
            // The popover supplies the backdrop in the app; recreate it for the render.
            let backdrop = NSVisualEffectView()
            backdrop.material = .popover
            backdrop.state = .active
            backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let panel = NSHostingView(rootView: GlancePanel(model: model))
            let size = panel.fittingSize
            panel.frame = CGRect(origin: .zero, size: size)
            backdrop.addSubview(panel)
            save(backdrop, size: size, dir.appending(path: dark ? "panel-dark.png" : "panel.png"))
        }
        for (name, style) in [("following", Glyph.Style.following), ("holding", .holding), ("faint", .faint), ("attention", .attention), ("learning", .learning)] {
            let icon = NSImageView(image: Glyph.image(style, description: name))
            icon.imageScaling = .scaleProportionallyUpOrDown
            save(icon, size: CGSize(width: 72, height: 72), dir.appending(path: "glyph-\(name).png"))
        }
        save(FocusFeedback.preview(), size: CGSize(width: 900, height: 360), dir.appending(path: "flash.png"))
        save(FocusFeedback.spotlightPreview(strength: 0.22), size: CGSize(width: 960, height: 600), dir.appending(path: "spotlight-first.png"))
        save(FocusFeedback.spotlightPreview(strength: 0.14), size: CGSize(width: 960, height: 600), dir.appending(path: "spotlight-seasoned.png"))
        let pill = EyeOverlayPreviews.pill(progress: 0.35)
        save(pill, size: pill.fittingSize, dir.appending(path: "eye-break.png"))
        save(EyeOverlayPreviews.veil(), size: CGSize(width: 900, height: 420), dir.appending(path: "privacy-veil.png"))
        let calibration = CalibrationOverlay.preview(size: CGSize(width: 1440, height: 900))
        save(calibration, size: CGSize(width: 1440, height: 900), dir.appending(path: "calibration.png"))
        print("snapshots written to \(dir.path)")
    }

    private static func save(_ view: NSView, size: CGSize, _ url: URL) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
