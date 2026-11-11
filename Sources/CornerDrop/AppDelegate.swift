import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: FileStore!
    private var panelController: PanelController!
    private var statusItem: NSStatusItem!
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = FileStore(settings: .shared)
        panelController = PanelController(store: store)
        store.start()
        setupStatusItem()
        _ = Updater.shared

        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.panelController.showManually() }
            }
        }

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "hasLaunchedBefore") {
            defaults.set(true, forKey: "hasLaunchedBefore")
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func openSettings() {
        settingsWindow.show()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Corner Drop")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show Recent Files") { [weak self] in
            self?.panelController.showManually()
        })
        menu.addItem(ClosureMenuItem("Open Watched Folder") {
            NSWorkspace.shared.open(AppSettings.shared.folderURL)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Check for Updates…") { Updater.shared.checkForUpdates() })
        let settingsItem = ClosureMenuItem("Settings…") { [weak self] in self?.openSettings() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = ClosureMenuItem("Quit Corner Drop") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu
    }
}
