import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var controller: BlackoutController!
    private var hotKey: HotKey?
    private let combination = HotKeyCombination.configured

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        controller = BlackoutController()
        controller.onChange = { [weak self] in self?.updateStatusIcon() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Umbra — \(combination.display)"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        hotKey = HotKey(combination) { [weak self] in
            DispatchQueue.main.async { self?.controller.toggle() }
        }
        if hotKey == nil { warnAboutUnavailableHotKey() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.restoreNow()
    }

    // MARK: - Menu

    /// Rebuilt on every open so the per-display status reflects reality rather
    /// than whatever was true at launch — displays get plugged in.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(
            title: controller.isBlacked ? "Restore Screens" : "Black Out Screens",
            action: #selector(toggleBlackout),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(disabled(hotKey == nil ? "Shortcut unavailable" : "Shortcut: \(combination.display)"))

        menu.addItem(.separator())
        menu.addItem(disabled("Mode"))
        for mode in [BlackoutController.Mode.full, .gammaOnly] {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.state = controller.mode == mode ? .on : .off
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(disabled("Displays: \(controller.displayCount)"))
        if !controller.ddcAvailable {
            menu.addItem(disabled("  DDC unavailable on this system"))
        } else if controller.ddcDisplays.isEmpty {
            menu.addItem(disabled("  No DDC displays found"))
        } else {
            for display in controller.ddcDisplays {
                menu.addItem(disabled("  \(display.statusText)"))
            }
        }
        let rescan = NSMenuItem(title: "Rescan Displays", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit Umbra", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleBlackout() {
        controller.toggle()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = BlackoutController.Mode(rawValue: raw) else { return }
        controller.mode = mode
    }

    @objc private func rescan() {
        controller.rescanDisplays { [weak self] in self?.updateStatusIcon() }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            present(
                title: "Could not change the login item",
                message: """
                    \(error.localizedDescription)

                    This usually means the app is not in /Applications. Move it there and try again.
                    """
            )
        }
    }

    @objc private func quit() {
        controller.restoreNow()
        NSApp.terminate(nil)
    }

    private func warnAboutUnavailableHotKey() {
        present(
            title: "Shortcut \(combination.display) is already taken",
            message: """
                Another app registered it first, so Umbra could not claim it. The menu bar item \
                still works, and a different combination can be set with:

                defaults write io.github.frapsd.Umbra hotKeyCode -int <carbon key code>
                """
        )
    }

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Status icon

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let symbol = controller.isBlacked ? "moon.fill" : "moon"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Umbra") {
            button.image = image
            button.title = ""
        } else {
            // Symbol unavailable on this OS — fall back to text so the item stays findable.
            button.image = nil
            button.title = controller.isBlacked ? "◼︎" : "◻︎"
        }
    }
}
