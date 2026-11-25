import AppKit

@main
@MainActor
enum NotchFinderApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = NotchSettings()
    private let shortcuts = PanelShortcuts()
    private lazy var controller = NotchController(settings: settings, shortcuts: shortcuts)
    private lazy var preferences = PreferencesWindowController(settings: settings, shortcuts: shortcuts, controller: controller)
    private var globalHotKey: PanelGlobalHotKey?
    private var settingsMenuItems: [NSMenuItem] = []
    private var localizedMenuItems: [(item: NSMenuItem, key: String)] = []
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        L10n.select(settings.interfaceLanguage)
        settings.interfaceLanguageDidChange = { [weak self] language in
            L10n.select(language)
            self?.updateLanguage()
        }
        controller.openSettings = { [weak self] in self?.openPreferences() }
        configureAppMenu()
        configureDockIconVisibility(settings: settings, application: NSApp)

        let opensPreferences = ProcessInfo.processInfo.arguments.contains("--settings")
        let startupDirectory = opensPreferences || settings.opensClipboardAtStartup ? nil : controller.browser.directory
        Task { [weak self] in
            let needsPermission = await Task.detached(priority: .userInitiated) {
                FileAccess.needsStartupPermission(for: startupDirectory)
            }.value
            self?.finishLaunching(needsPermission: needsPermission, opensPreferences: opensPreferences)
        }
    }

    private func finishLaunching(needsPermission: Bool, opensPreferences: Bool) {
        let opensFileAccessSettings = needsPermission && FileAccess.confirmRequest()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeStatusBarIcon()
        item.button?.toolTip = "Notch Finder"
        item.button?.target = self
        item.button?.action = #selector(handleStatusClick(_:))

        let showItem = addLocalizedItem("顯示檔案面板", to: statusMenu, action: #selector(showPanel))
        showItem.target = self
        let preferencesItem = addPreferencesItem(to: statusMenu)
        preferencesItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        preferencesItem.image?.isTemplate = true
        statusMenu.addItem(.separator())
        addLocalizedItem("結束 Notch Finder", to: statusMenu, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem = item

        let globalHotKey = PanelGlobalHotKey { [weak self] in
            guard let self, !self.preferences.isRecording else { return }
            self.controller.togglePanel()
        }
        self.globalHotKey = globalHotKey
        shortcuts.installGlobal = { [weak globalHotKey] in globalHotKey?.replace(with: $0) == true }
        shortcuts.settingsShortcutChanged = { [weak self] in self?.updatePreferencesKey($0) }
        shortcuts.installInitialGlobal()
        updatePreferencesKey(shortcuts[.settings])

        controller.start()
        if opensFileAccessSettings { FileAccess.openSystemSettings() }
        else if opensPreferences { openPreferences() }
        else { controller.showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if preferences.isVisible { openPreferences() }
        else { controller.showPanel() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.clipboardHistory.finishSaving()
        globalHotKey?.stop()
    }

    private func configureAppMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Notch Finder")
        addPreferencesItem(to: appMenu)
        appMenu.addItem(.separator())
        addLocalizedItem("結束 Notch Finder", to: appMenu, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @discardableResult
    private func addPreferencesItem(to menu: NSMenu) -> NSMenuItem {
        let item = addLocalizedItem("設定…", to: menu, action: #selector(openPreferences))
        item.target = self
        settingsMenuItems.append(item)
        return item
    }

    @discardableResult
    private func addLocalizedItem(_ key: String, to menu: NSMenu, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: L10n.text(key), action: action, keyEquivalent: keyEquivalent)
        localizedMenuItems.append((item, key))
        return item
    }

    private func updateLanguage() {
        for (item, key) in localizedMenuItems {
            item.title = L10n.text(key)
        }
        preferences.updateTitle()
    }

    private func updatePreferencesKey(_ key: KeyShortcut) {
        for item in settingsMenuItems {
            item.keyEquivalent = key.characters
            item.keyEquivalentModifierMask = key.modifiers
        }
    }

    @objc private func handleStatusClick(_ button: NSStatusBarButton) {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            openPreferences()
            return
        }

        let bottom = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        button.highlight(true)
        defer { button.highlight(false) }
        statusMenu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: bottom), in: button)
    }

    @objc private func openPreferences() {
        preferences.show()
    }

    @objc private func showPanel() {
        controller.showPanel(focus: true)
    }
}
