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
    #if DEBUG
    if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count {
        Snapshots.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    }
    #endif
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory) // LSUIElement also says so; this covers `swift run`
    NSApplication.shared.run()
}
