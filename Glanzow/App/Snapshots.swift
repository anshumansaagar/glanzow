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
        for step in 0..<4 {
            for dark in [false, true] {
                let host = NSHostingView(rootView: OnboardingView(model: model, step: step))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                save(host, size: CGSize(width: 620, height: 490), dir.appending(path: "onboarding-\(step + 1)-\(dark ? "dark" : "light").png"))
            }
        }
        let settings = NSHostingView(rootView: SettingsView(model: model, showDebug: false))
        save(settings, size: CGSize(width: 520, height: 560), dir.appending(path: "settings.png"))
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
