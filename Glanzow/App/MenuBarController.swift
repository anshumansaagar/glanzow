import AppKit
import Combine
import GlanzowKit

/// FR-UI-01, FR-UI-02: status item whose icon tracks the app state, and its menu.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let model: AppModel
    private var sub: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        sub = model.$status.sink { [weak self] status in self?.show(status) }
    }

    private func show(_ status: AppModel.Status) {
        let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: "Glanzow: \(status.title)")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = image == nil ? "GF" : ""
        item.button?.toolTip = "Glanzow — \(status.title)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: model.status.title, action: nil, keyEquivalent: "")
        state.isEnabled = false
        state.image = NSImage(systemSymbolName: model.status.symbol, accessibilityDescription: nil)
        menu.addItem(state)
        menu.addItem(.separator())

        let shortcut = UserDefaults.standard.string(forKey: Pref.hotkeyLabel) ?? ""
        add(menu, "\(model.userPaused ? "Resume" : "Pause")   \(shortcut)", #selector(togglePause),
            symbol: model.userPaused ? "play.fill" : "pause.fill")

        let recal = NSMenuItem(title: "Recalibrate", action: nil, keyEquivalent: "")
        recal.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
        let sub = NSMenu()
        add(sub, "All Displays", #selector(recalibrateAll))
        sub.addItem(.separator())
        for d in model.displays {
            let i = add(sub, d.name, #selector(recalibrateOne(_:)))
            i.representedObject = d.key
        }
        recal.submenu = sub
        menu.addItem(recal)

        add(menu, "Settings…", #selector(settings), key: ",", symbol: "gearshape")
        let debug = add(menu, "Debug Settings…", #selector(debugSettings), key: ",", symbol: "ladybug")
        debug.keyEquivalentModifierMask = [.command, .option]
        debug.isAlternate = true
        add(menu, "Welcome Guide…", #selector(welcome), symbol: "hand.wave")
        menu.addItem(.separator())
        add(menu, "Quit Glanzow", #selector(quit), key: "q", symbol: "power")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(i)
        return i
    }

    @objc private func togglePause() { model.userPaused.toggle() }
    @objc private func recalibrateAll() { Task { await model.calibrate(nil) } }
    @objc private func recalibrateOne(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Task { await model.calibrate([key]) }
    }
    @objc private func settings() { model.showSettings() }
    @objc private func debugSettings() { model.showSettings(debug: true) }
    @objc private func welcome() { model.showOnboarding() }
    @objc private func quit() { NSApp.terminate(nil) }
}
