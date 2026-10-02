import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: AboutWindowController?

    @objc private func showSettings(_ sender: Any?) {
        let controller = settingsWindow ?? SettingsWindowController()
        settingsWindow = controller
        controller.show()
    }

    /// View ▸ Wrap Detail Lines — toggles line wrapping in the plain-text detail
    /// tabs. The setter posts a notification so the detail pane re-flows live.
    @objc private func toggleWrapDetailText(_ sender: NSMenuItem) {
        Settings.wrapDetailText.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleWrapDetailText(_:)) {
            menuItem.state = Settings.wrapDetailText ? .on : .off
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ResourceKindStore.seedDefaultsIfNeeded()   // first launch → developer default set
        Notifier.shared.configure()                // diagnostics completion banners
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        setupMainMenu()
        let controller = MainWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cmd-Q / Quit doesn't fire windowWillClose — tear down child processes
        // (port-forwards / log streams) here so they aren't orphaned to launchd.
        windowController?.shutdown()
    }

    // MARK: - About

    /// Custom About window (hero artwork + slogan + blurb) — see AboutWindowController.
    @objc private func showAbout(_ sender: Any?) {
        let controller = aboutWindow ?? AboutWindowController()
        aboutWindow = controller
        controller.show()
    }

    // MARK: - Menu

    private func setupMainMenu() {
        let appName = "Kub"
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let aboutItem = appMenu.addItem(withTitle: "About \(appName)",
                                        action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (standard text editing)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find", action: Selector(("focusSearch:")), keyEquivalent: "f")
        find.keyEquivalentModifierMask = [.command]

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let refreshItem = viewMenu.addItem(withTitle: "Refresh",
                                           action: Selector(("refresh:")), keyEquivalent: "r")
        refreshItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(.separator())
        let hideSystem = viewMenu.addItem(withTitle: "Hide System Namespaces",
                                          action: Selector(("toggleHideSystemNamespaces:")), keyEquivalent: "k")
        hideSystem.keyEquivalentModifierMask = [.command, .shift]
        hideSystem.state = UserDefaults.standard.bool(forKey: "HideSystemNamespaces") ? .on : .off
        let showDetails = viewMenu.addItem(withTitle: "Show Details",
                                           action: Selector(("toggleDetails:")), keyEquivalent: "d")
        showDetails.keyEquivalentModifierMask = [.command, .shift]
        showDetails.state = (UserDefaults.standard.object(forKey: "ShowDetails") as? Bool ?? true) ? .on : .off
        let wrapItem = viewMenu.addItem(withTitle: "Wrap Detail Lines",
                                        action: #selector(toggleWrapDetailText(_:)), keyEquivalent: "")
        wrapItem.target = self
        wrapItem.state = Settings.wrapDetailText ? .on : .off
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Customize Current Context…",
                         action: Selector(("customizeContext:")), keyEquivalent: "")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
