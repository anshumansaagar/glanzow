import AppKit
import Combine
import SwiftUI
import GlanzowKit

/// FR-UI-01, FR-UI-02: the gleam in the menu bar. Left-click opens the panel with the live
/// view; right-click (or Control-click) opens the classic menu.
@MainActor final class MenuBarController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private unowned let model: AppModel
    private var sub: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: GlancePanel(model: model))
        sub = model.$status.sink { [weak self] status in self?.show(status) }
    }

    private func show(_ status: AppModel.Status) {
        item.button?.image = Glyph.image(status.glyph, description: "Glanzow: \(status.title)")
        item.button?.toolTip = "Glanzow — \(status.title)"
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) { model.panelOpened() }
    func popoverDidClose(_ notification: Notification) { model.panelClosed() }

    // MARK: Classic menu

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: model.status.title, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        let defaults = UserDefaults.standard
        add(menu, "\(model.userPaused ? "Follow Me Again" : "Hold Focus")   \(defaults.string(forKey: Pref.hotkeyLabel) ?? "")",
            #selector(toggleHold), symbol: model.userPaused ? "play.fill" : "pause.fill")
        add(menu, "Undo Last Switch   \(defaults.string(forKey: Pref.undoHotkeyLabel) ?? "")", #selector(undo), symbol: "arrow.uturn.backward")

        let teach = NSMenuItem(title: "Teach My Screens", action: nil, keyEquivalent: "")
        teach.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)
        let sub = NSMenu()
        add(sub, "All Screens", #selector(recalibrateAll))
        sub.addItem(.separator())
        for d in model.displays {
            let i = add(sub, d.name, #selector(recalibrateOne(_:)))
            i.representedObject = d.key
        }
        teach.submenu = sub
        menu.addItem(teach)

        add(menu, "Settings…", #selector(settings), key: ",", symbol: "gearshape")
        let debug = add(menu, "Debug Settings…", #selector(debugSettings), key: ",", symbol: "ladybug")
        debug.keyEquivalentModifierMask = [.command, .option]
        debug.isAlternate = true
        add(menu, "Set Up Glanzow…", #selector(welcome), symbol: "checklist")
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

    @objc private func toggleHold() { model.userPaused.toggle() }
    @objc private func undo() { model.undoSwitch() }
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
