import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?

    func applicationDidFinishLaunching(_ note: Notification) {
        let model = AppModel()
        self.model = model
        model.start()
    }

    func applicationWillTerminate(_ note: Notification) { model?.shutdown() }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory) // LSUIElement also says so; this covers `swift run`
    NSApplication.shared.run()
}
