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
    @ObservationIgnored private let settings: NotchSettings
    @ObservationIgnored private let contentSource: BrowserContentRefresh.Source
    @ObservationIgnored private let fileHistory: FileOperationHistory
    let clipboardHistory: ClipboardHistory
    @ObservationIgnored private var pendingOperationMessage: String?
    @ObservationIgnored private var isPanelVisible = false
    private(set) var items: [Tab]
    private(set) var active: Tab
    private(set) var showsClipboard = false
    @ObservationIgnored var onLeaveFileContent: (() -> Void)?

    init(initialDirectory: URL?, settings: NotchSettings, clipboardHistory: ClipboardHistory,
         contentSource: BrowserContentRefresh.Source = .live, sidebar: SidebarLocations? = nil) {
        self.settings = settings
        self.contentSource = contentSource
        defaults = settings.defaults
        self.clipboardHistory = clipboardHistory
        let fileHistory = FileOperationHistory()
        self.fileHistory = fileHistory
        let tab = Tab(browser: FileBrowser(initialDirectory: initialDirectory, sidebar: sidebar, settings: settings,
                                           contentSource: contentSource, fileHistory: fileHistory))
        items = [tab]
        active = tab
        trackLocation(of: tab.browser)
        fileHistory.deliver = { [weak self] result in
            guard let self else { return }
            if isPanelVisible && !showsClipboard {
                active.browser.receive(result)
            } else {
                pendingOperationMessage = result.message
                active.browser.showOperationMessage(result.message)
            }
        }
        settings.filePresentationDidChange = { [weak self] in
            self?.items.forEach { $0.browser.filePresentationDidChange() }
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        updateActiveContent(revalidation: .immediately)
        if visible {
            if showsClipboard { clipboardHistory.sample() }
            rememberLocation()
        } else {
            active.browser.cancelEditing()
        }
    }

    func showClipboard() {
        if !showsClipboard {
            onLeaveFileContent?()
            active.browser.cancelEditing()
            showsClipboard = true
            updateActiveContent(revalidation: .quietly)
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

    func showTag(_ name: String) {
        browse { $0.showTag(name) }
    }

    func goForward() {
        browse { $0.goForward() }
    }

    func goUp() {
        browse { $0.goUp() }
    }

    func add() {
        let browser = FileBrowser(initialDirectory: active.browser.directory, sidebar: active.browser.sidebar,
                                  settings: settings, contentSource: contentSource, fileHistory: fileHistory)
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
        onLeaveFileContent?()
        active.browser.setContentActive(false, revalidation: .afterDelay)
        active.browser.cancelEditing()
        showsClipboard = false
        active = tab
        updateActiveContent(revalidation: .afterDelay)
        tab.browser.enableFileIcons()
        rememberLocation()
    }

    private func browse(_ change: (FileBrowser) -> Void) {
        let browser = active.browser
        guard showsClipboard else {
            change(browser)
            return
        }
        showsClipboard = false
        updateActiveContent(revalidation: .quietly)
        change(browser)
        rememberLocation()
    }

    private func updateActiveContent(revalidation: BrowserContentRefresh.Revalidation) {
        clipboardHistory.setPreviewVisible(isPanelVisible && showsClipboard)
        let browsing = isPanelVisible && !showsClipboard
        active.browser.setContentActive(browsing, revalidation: revalidation)
        if browsing, let message = pendingOperationMessage {
            pendingOperationMessage = nil
            active.browser.showOperationMessage(message)
        }
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
