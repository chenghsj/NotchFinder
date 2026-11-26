import Foundation
import Observation

@MainActor
@Observable
final class BrowserTabs {
    struct Tab: Identifiable {
        let id = UUID()
        let browser: FileBrowser
    }

    @ObservationIgnored private let defaults: UserDefaults
    let clipboardHistory: ClipboardHistory
    @ObservationIgnored private var isPanelVisible = false
    private(set) var items: [Tab]
    private(set) var active: Tab
    private(set) var showsClipboard = false
    @ObservationIgnored var onActivate: (() -> Void)?

    init(initialDirectory: URL?, defaults: UserDefaults = .standard, clipboardHistory: ClipboardHistory) {
        self.defaults = defaults
        self.clipboardHistory = clipboardHistory
        let tab = Tab(browser: FileBrowser(initialDirectory: initialDirectory, defaults: defaults))
        items = [tab]
        active = tab
        trackLocation(of: tab.browser)
    }

    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        updateMonitoring()
        if visible {
            if showsClipboard { clipboardHistory.sample() }
            else { active.browser.reload() }
            rememberLocation()
        } else {
            active.browser.cancelEditing()
        }
    }

    func showClipboard() {
        if !showsClipboard {
            active.browser.cancelEditing()
            showsClipboard = true
            updateMonitoring()
            rememberLocation()
        }
        if isPanelVisible { clipboardHistory.refreshPreview() }
    }

    func closeClipboard() {
        browse { _ in }
    }

    func navigate(to directory: URL) {
        browse { $0.navigate(to: directory) }
    }

    func showRecentItems() {
        browse { $0.showRecentItems() }
    }

    func goForward() {
        browse { $0.goForward() }
    }

    func goUp() {
        browse { $0.goUp() }
    }

    func add() {
        let browser = FileBrowser(initialDirectory: active.browser.directory, sidebar: active.browser.sidebar,
                                  defaults: defaults)
        browser.onPreview = active.browser.onPreview
        trackLocation(of: browser)
        let tab = Tab(browser: browser)
        items.append(tab)
        activate(tab)
    }

    func select(_ id: UUID) {
        guard id != active.id, let tab = items.first(where: { $0.id == id }) else { return }
        activate(tab)
    }

    func close(_ id: UUID) {
        guard items.count > 1, let index = items.firstIndex(where: { $0.id == id }) else { return }
        if id == active.id {
            let neighbor = index + 1 < items.count ? index + 1 : index - 1
            activate(items[neighbor])
        }
        items.remove(at: index)
    }

    func cycle(forward: Bool) {
        guard items.count > 1, let index = items.firstIndex(where: { $0.id == active.id }) else { return }
        let next = (index + (forward ? 1 : -1) + items.count) % items.count
        activate(items[next])
    }

    private func activate(_ tab: Tab) {
        onActivate?()
        active.browser.setContentMonitoring(false)
        active.browser.cancelEditing()
        showsClipboard = false
        active = tab
        updateMonitoring()
        tab.browser.activate()
        rememberLocation()
    }

    private func browse(_ change: (FileBrowser) -> Void) {
        let browser = active.browser
        guard showsClipboard else {
            change(browser)
            return
        }
        let previousDestination = browser.destination
        showsClipboard = false
        updateMonitoring()
        change(browser)
        if isPanelVisible, previousDestination == browser.destination {
            browser.reload(quietly: true)
        }
        rememberLocation()
    }

    private func updateMonitoring() {
        clipboardHistory.setPreviewVisible(isPanelVisible && showsClipboard)
        active.browser.setContentMonitoring(isPanelVisible && !showsClipboard)
    }

    private func trackLocation(of browser: FileBrowser) {
        browser.onDirectoryChange = { [weak self, weak browser] in
            guard let self, self.active.browser === browser else { return }
            self.rememberLocation()
        }
    }

    private func rememberLocation() {
        defaults.set(active.browser.directory.path, forKey: "lastVisitedFolder")
        defaults.set(showsClipboard, forKey: "lastLocationWasClipboard")
    }
}
