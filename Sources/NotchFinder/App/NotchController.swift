import AppKit
import Carbon.HIToolbox
import QuickLookUI

@MainActor
final class NotchController: NSObject {
    private struct Display {
        let screen: NSScreen
        let notch: NotchGeometry?
        let trigger: NSRect?
    }

    let tabs: BrowserTabs
    let clipboardHistory: ClipboardHistory
    var browser: FileBrowser { tabs.active.browser }
    private let settings: NotchSettings
    private let shortcuts: PanelShortcuts
    var openSettings: (() -> Void)?
    private var displays: [Display] = []
    private var panel: NotchPanel?
    private var currentDisplay: Display?
    private weak var foregroundPreferencesWindow: NSWindow?
    private var visibility = PanelVisibility()
    private var preferredPanelSize: CGSize
    private var sizeBeforeResize: CGSize?
    private lazy var clipboardPaste = ClipboardPaste(history: clipboardHistory, desktop: .live, folder: { [weak self] in
        guard let self, browser.isBrowsingFolder else { return nil }
        let browser = browser
        return ClipboardPaste.Folder(available: !browser.isUpdatingFiles) { [weak self] urls in
            guard let self else { return }
            tabs.closeClipboard()
            browser.pasteItems(urls, cleanupInstaller: settings.cleansDiskImageAfterInstall)
        }
    }, dismissPanel: { [weak self] in self?.dismiss() })

    init(settings: NotchSettings = NotchSettings(), shortcuts: PanelShortcuts = PanelShortcuts(),
         clipboardHistory: ClipboardHistory = ClipboardHistory()) {
        self.settings = settings
        self.shortcuts = shortcuts
        self.clipboardHistory = clipboardHistory
        tabs = BrowserTabs(initialDirectory: settings.startDirectory, settings: settings,
                           clipboardHistory: clipboardHistory)
        preferredPanelSize = settings.remembersSize
            ? NotchGeometry.savedPanelSize(in: settings.defaults) : NotchGeometry.defaultPanelSize
        super.init()
        browser.onPreview = { [weak self] items in self?.panel?.preview.show(items) }
        tabs.onLeaveFileContent = { [weak self] in self?.panel?.preview.close() }
    }

    func start() {
        NSApp.appearance = settings.appearance.colorMode.appearance
        settings.colorModeDidChange = { NSApp.appearance = $0.appearance }
        clipboardHistory.resumeIfEnabled()
        if settings.opensClipboardAtStartup { tabs.showClipboard() }
        updateDisplays()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateDisplays),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(workspaceDidActivateApplication(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(self, selector: #selector(workspaceVolumeDidChange(_:)), name: event, object: nil)
        }

        // Sample pointer location without installing an event tap or a window over the menu bar.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover(at: NSEvent.mouseLocation) }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func showPanel(focus: Bool = false) {
        let pointer = NSEvent.mouseLocation
        if let display = displays.first(where: { $0.screen.frame.contains(pointer) }) ?? displays.first {
            present(on: display, manually: true, bringToFront: focus)
            if focus { panel?.focusForInteraction() }
        }
    }

    func togglePanel() {
        if currentDisplay == nil {
            showPanel(focus: true)
        } else {
            dismiss()
        }
    }

    func toggleClipboard() {
        let wasVisible = currentDisplay != nil
        if wasVisible && tabs.showsClipboard {
            dismiss()
            return
        }
        if wasVisible { clipboardPaste.captureTarget() }
        tabs.showClipboard()
        showPanel(focus: true)
        if !wasVisible && clipboardHistory.isWaitingForAccess { clipboardHistory.refreshPreview() }
    }

    func prepareToShowPreferences() {
        panel?.preview.close()
        if !settings.panelPinned { dismiss(animated: false) }
    }

    func setForegroundPreferencesWindow(_ window: NSWindow?) {
        if foregroundPreferencesWindow !== window { foregroundPreferencesWindow?.level = .normal }
        foregroundPreferencesWindow = window
        window?.level = .floating
        guard let panel, currentDisplay != nil else { return }
        if let window, window.isVisible {
            orderPanel(panel, behind: window)
        } else if panel.isVisible && !panel.preview.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func orderPanel(_ panel: NotchPanel, behind preferencesWindow: NSWindow) {
        panel.order(.below, relativeTo: preferencesWindow.windowNumber)
    }

    var pinnedPanelPlacement: (frame: NSRect, visibleFrame: NSRect)? {
        guard settings.panelPinned, let panel, panel.isVisible, let currentDisplay else { return nil }
        return (panel.frame, currentDisplay.screen.visibleFrame)
    }

    func savePreferredSize() {
        if settings.remembersSize { NotchGeometry.savePanelSize(preferredPanelSize, in: settings.defaults) }
    }

    func restoreDefaultSize() {
        finishResize()
        preferredPanelSize = NotchGeometry.defaultPanelSize
        savePreferredSize()
        guard let panel, let currentDisplay, position(panel, on: currentDisplay, requestedSize: preferredPanelSize) else { return }
        panel.animatedContent.setExpanded(true, animated: false) { [weak self] in self?.browser.enableFileIcons() }
    }

    @objc private nonisolated func workspaceVolumeDidChange(_ notification: Notification) {
        let unmountedVolume = notification.name == NSWorkspace.didUnmountNotification
            ? notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.browser.sidebar.refreshVolumes()
            if let unmountedVolume {
                for tab in self.tabs.items { tab.browser.volumeDidUnmount(at: unmountedVolume) }
            }
        }
    }

    @objc private func workspaceDidActivateApplication(_ notification: Notification) {
        guard let active = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              active.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        setForegroundPreferencesWindow(nil)
    }

    @objc private func updateDisplays() {
        finishResize()
        let screens = NSScreen.screens
        let notches = screens.map { NotchGeometry(screen: $0) }
        let useTopCenter = notches.allSatisfy { $0 == nil }
        displays = zip(screens, notches).enumerated().map { index, pair in
            let (screen, notch) = pair
            let fallback = useTopCenter && index == 0
                ? NotchGeometry.topCenterTrigger(frame: screen.frame, visibleFrame: screen.visibleFrame)
                : nil
            return Display(screen: screen, notch: notch, trigger: notch?.trigger ?? fallback)
        }
        if currentDisplay != nil {
            showPanel()
        } else {
            visibility.didHide(suppressUntilExit: false)
        }
    }

    func updateHover(at pointer: NSPoint) {
        let display = currentDisplay ?? displays.first { $0.trigger?.contains(pointer) == true }
        let event = visibility.update(PanelVisibility.Sample(
            now: ProcessInfo.processInfo.systemUptime,
            insideTrigger: (settings.hoverEnabled || currentDisplay != nil) && display?.trigger?.contains(pointer) == true,
            insideAnyTrigger: displays.contains { $0.trigger?.contains(pointer) == true },
            insidePanel: currentDisplay != nil && panel?.frame.insetBy(dx: -5, dy: -5).contains(pointer) == true,
            mouseDown: NSEvent.pressedMouseButtons != 0,
            trackingEvents: RunLoop.main.currentMode == .eventTracking,
            resizing: sizeBeforeResize != nil,
            editing: browser.editing != nil,
            previewVisible: panel?.preview.isVisible == true,
            automaticHide: settings.autoHide && !settings.panelPinned && panel?.attachedSheet == nil,
            showDelay: settings.hoverDelay,
            hideDelay: settings.hideDelay
        )) {
            guard let panel else { return false }
            return NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0) == panel.windowNumber
        }

        switch event {
        case .show:
            if let display { present(on: display, manually: false) }
        case .hide(let suppressUntilExit):
            dismiss(suppressUntilExit: suppressUntilExit)
        case nil:
            break
        }
    }

    private func present(on display: Display, manually: Bool, bringToFront: Bool = false) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let opening = currentDisplay == nil
        if opening {
            clipboardPaste.captureTarget()
            if !settings.remembersSize { preferredPanelSize = NotchGeometry.defaultPanelSize }
        }
        currentDisplay = display
        visibility.didShow(manually: manually)
        tabs.setPanelVisible(true)

        let frameChanged = position(panel, on: display, requestedSize: preferredPanelSize)
        let content = panel.animatedContent

        let wasVisible = panel.isVisible
        if !wasVisible { content.prepareForReveal() }
        if !bringToFront, let foregroundPreferencesWindow, foregroundPreferencesWindow.isVisible {
            orderPanel(panel, behind: foregroundPreferencesWindow)
        } else {
            panel.orderFrontRegardless()
            if opening { panel.makeKey() }
        }
        panel.startHistoryEventMonitor()
        if opening || frameChanged || !wasVisible {
            content.setExpanded(true, animated: opening, speed: settings.animation) { [weak self] in
                self?.browser.enableFileIcons()
            }
        }
    }

    private func dismiss(suppressUntilExit: Bool = true, animated: Bool = true) {
        guard currentDisplay != nil, let panel else { return }
        if let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .cancel) }
        finishResize()
        currentDisplay = nil
        tabs.setPanelVisible(false)
        settings.panelPinned = false
        visibility.didHide(suppressUntilExit: suppressUntilExit)
        panel.preview.close()

        panel.animatedContent.setExpanded(false, animated: animated, speed: settings.animation) { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func fileDragEnded() {
        visibility.fileDragEnded(now: ProcessInfo.processInfo.systemUptime, hideDelay: settings.hideDelay,
                                 automaticHide: settings.autoHide && !settings.panelPinned)
    }

    @discardableResult
    private func position(_ panel: NotchPanel, on display: Display, requestedSize: CGSize) -> Bool {
        let frame = NotchGeometry.panelFrame(on: display.screen, notch: display.notch, requestedSize: requestedSize)
        let frameChanged = frame != panel.frame
        if frameChanged { panel.setFrame(frame, display: false) }
        panel.animatedContent.collapsedCenterX = (display.notch?.centerX ?? frame.midX) - frame.minX
        panel.animatedContent.collapsedWidth = display.notch?.width ?? 116
        return frameChanged
    }

    private func beginResize() {
        guard sizeBeforeResize == nil, currentDisplay != nil, let panel else { return }
        sizeBeforeResize = panel.frame.size
        panel.animatedContent.setExpanded(true, animated: false) { [weak self] in
            self?.browser.enableFileIcons()
        }
    }

    private func resize(by delta: CGSize) {
        guard let initial = sizeBeforeResize, let display = currentDisplay, let panel else { return }
        let size = CGSize(width: initial.width + 2 * delta.width, height: initial.height - delta.height)
        if position(panel, on: display, requestedSize: size) {
            panel.animatedContent.fitExpandedPanel()
        }
    }

    private func finishResize() {
        guard let initial = sizeBeforeResize, let panel else { return }
        sizeBeforeResize = nil
        let size = panel.frame.size
        if size != initial {
            preferredPanelSize = size
            savePreferredSize()
            panel.invalidateShadow()
        }
    }

    fileprivate func dispatchShortcut(_ event: NSEvent, editingText: Bool) -> Bool {
        guard let command = shortcuts.command(for: event) else {
            return !editingText && handleGalleryArrow(event)
        }
        if editingText && command != .close && command != .settings && command != .filter {
            let usesModifier = !event.modifierFlags.intersection([.command, .control]).isEmpty
            if !command.isTabCommand || !usesModifier { return false }
        }
        if tabs.showsClipboard {
            switch command {
            case .close:
                if !event.isARepeat { tabs.closeClipboard() }
                return true
            case .reload:
                if !event.isARepeat { clipboardHistory.refreshPreview() }
                return true
            case .goToFolder, .paste:
                if event.isARepeat { return true }
                tabs.closeClipboard()
            case .back, .forward, .parent, .togglePanel, .settings, .pin, .filter, .newTab, .closeTab, .nextTab, .previousTab:
                break
            default:
                return false
            }
        }
        let selection = browser.selection
        if command == .preview && selection.isEmpty && panel?.preview.isVisible != true { return false }
        if event.isARepeat { return true }
        switch command {
        case .togglePanel, .openClipboard: return false
        case .settings: showSettings()
        case .close: closeOrCancel()
        case .pin: settings.panelPinned.toggle()
        case .back: navigateBack()
        case .forward: tabs.goForward()
        case .parent: tabs.goUp()
        case .goToFolder: browser.beginEditing(.goToFolder)
        case .filter:
            panel?.focusForInteraction()
            settings.searchRequest = PanelSearchRequest(action: shortcuts.isSearchToggle(event) ? .toggle : .focus)
        case .reload: browser.reload()
        case .toggleHidden: browser.setShowsHidden(!browser.showsHidden)
        case .open: browser.openItems(selection)
        case .preview:
            panel?.togglePreview()
        case .selectAll: browser.selectAll()
        case .copy: browser.copyItems(selection)
        case .paste: browser.pasteItems(cleanupInstaller: settings.cleansDiskImageAfterInstall)
        case .copyPath: browser.copyPaths(selection)
        case .reveal: browser.revealInFinder(selection)
        case .rename:
            if selection.count == 1, let item = selection.first { browser.beginEditing(.rename(item)) }
        case .newFolder: browser.beginEditing(.createFolder)
        case .trash: browser.trashItems(selection)
        case .newTab: tabs.add()
        case .closeTab:
            if tabs.items.count > 1 { tabs.close(tabs.active.id) }
            else { closeOrCancel() }
        case .nextTab: tabs.cycle(forward: true)
        case .previousTab: tabs.cycle(forward: false)
        case .undo: browser.replayFileOperation(.undo)
        case .redo: browser.replayFileOperation(.redo)
        }
        return true
    }

    private func navigateBack() {
        if tabs.showsClipboard { tabs.closeClipboard() }
        else { browser.goBack() }
    }

    private func handleGalleryArrow(_ event: NSEvent) -> Bool {
        guard !tabs.showsClipboard, panel?.preview.isVisible != true, !(panel?.firstResponder is NSSlider),
              event.modifierFlags.intersection([.command, .control, .shift, .option]).isEmpty,
              event.keyCode == kVK_LeftArrow || event.keyCode == kVK_RightArrow else { return false }
        return browser.moveGallerySelection(by: event.keyCode == kVK_LeftArrow ? -1 : 1)
    }

    private func closeOrCancel() {
        if panel?.preview.isVisible == true { panel?.preview.close(animated: true) }
        else if browser.editing != nil { browser.cancelEditing() }
        else if tabs.showsClipboard { tabs.closeClipboard() }
        else { dismiss() }
    }

    private func updateOpenPreview() {
        panel?.preview.selectionDidChange { [weak self] in
            guard let self, !tabs.showsClipboard else { return [] }
            return browser.entries(matching: browser.selection)
        }
    }

    private func showSettings() {
        openSettings?()
    }

    private func confirmEmptyTrash() {
        guard let panel, panel.isVisible, panel.attachedSheet == nil,
              let directory = browser.sidebar.trashDirectory, !browser.isUpdatingFiles else { return }
        panel.preview.close()
        panel.focusForInteraction()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("要清空垃圾桶嗎？")
        alert.informativeText = L10n.text("這會永久刪除本機垃圾桶中的所有項目，包括隱藏項目。此操作無法復原。")
        let empty = alert.addButton(withTitle: L10n.text("清空垃圾桶"))
        empty.hasDestructiveAction = true
        empty.keyEquivalent = ""
        alert.addButton(withTitle: L10n.text("取消")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            tabs.navigate(to: directory)
            browser.emptyTrash()
        }
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(rootView: BrowserPanel(
            tabs: tabs,
            settings: settings,
            quickLookSources: QuickLookSources(),
            close: { [weak self] in self?.closeOrCancel() },
            openSettings: { [weak self] in self?.showSettings() },
            confirmEmptyTrash: { [weak self] in self?.confirmEmptyTrash() },
            onFileSelectionChange: { [weak self] in self?.updateOpenPreview() },
            clipboardPaste: clipboardPaste,
            resizeHandle: PanelResizeHandle(
                begin: { [weak self] in self?.beginResize() },
                update: { [weak self] delta in self?.resize(by: delta) },
                end: { [weak self] in self?.finishResize() }
            ),
            onFileDragEnded: { [weak self] in self?.fileDragEnded() }
        ))
        panel.beforeActivating = { [weak self] in self?.clipboardPaste.captureTarget() }
        panel.onEmptyTableClick = { [weak self] in
            guard let self, !tabs.showsClipboard else { return false }
            browser.selectItems([])
            return true
        }
        panel.onMouseDown = { [weak self] in self?.visibility.didInteract() }
        panel.onFileListHeaderPress = { [weak self] in
            guard let self, !tabs.showsClipboard, browser.displayMode == .list else { return }
            settings.beginCustomizingFileListColumns(for: browser.destination)
        }
        panel.onNavigateHistory = { [weak self] forward in
            guard let self, currentDisplay != nil else { return false }
            if forward { tabs.goForward() }
            else { navigateBack() }
            return true
        }
        panel.title = "Notch Finder"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.keyAction = { [weak self] event, editingText in
            self?.dispatchShortcut(event, editingText: editingText) == true
        }
        panel.previewKeyCommand = { [weak self] event in
            guard let command = self?.shortcuts.command(for: event), command == .preview || command == .close else {
                return nil
            }
            return command
        }
        panel.onDismiss = { [weak self] in
            guard let self else { return }
            if self.browser.editing != nil || self.panel?.preview.isVisible == true
                || self.shortcuts[.close].matches(PanelCommand.close.defaultShortcut) {
                self.closeOrCancel()
            }
        }
        return panel
    }
}

@MainActor
final class NotchPanel: NSPanel, FilePreviewWindows, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    let animatedContent: AnimatedPanelView
    private let quickLookSources: QuickLookSources
    var onDismiss: (() -> Void)?
    var beforeActivating: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onFileListHeaderPress: (() -> Void)?
    var onNavigateHistory: ((_ forward: Bool) -> Bool)?
    var onEmptyTableClick: (() -> Bool)?
    var keyAction: ((NSEvent, Bool) -> Bool)?
    var previewKeyCommand: ((NSEvent) -> PanelCommand?)?
    private var previewItems: [URL] = []
    private let tabs: BrowserTabs
    private let settings: NotchSettings
    private(set) lazy var preview = FilePreviewSession(windows: self)
    private var isOpeningNativePreviewWithoutItems = false
    private weak var previewWindow: QLPreviewPanel?
    private var folderPreviewWindow: FolderPreviewPanel?
    private var recentlyClosedFolder: (url: URL, time: TimeInterval)?
    private var reselectedFolderAfterPreview: URL?
    private var historyEventMonitor: Any?
    private var globalHistoryMonitor: Any?
    private var previewEventMonitor: Any?
    private var forwardingPreviewClick = false
    private var nativeCloseButtonAction: (button: NSButton, target: AnyObject?, action: Selector?)?

    var canPresent: Bool { isVisible }
    var visibleFolder: URL? {
        guard let folderPreviewWindow, folderPreviewWindow.isVisible else { return nil }
        return folderPreviewWindow.folderURL
    }
    var folderIsClosing: Bool { folderPreviewWindow?.ignoresMouseEvents == true }
    var nativeState: FilePreviewSession.NativeState {
        guard let previewWindow else { return .closed }
        if previewWindow.ignoresMouseEvents { return .closing }
        return previewWindow.isVisible ? .open : .closed
    }

    init(rootView: BrowserPanel) {
        tabs = rootView.tabs
        settings = rootView.settings
        quickLookSources = rootView.quickLookSources
        animatedContent = AnimatedPanelView(rootView: rootView)
        super.init(
            contentRect: NSRect(origin: .zero, size: NotchGeometry.defaultPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = animatedContent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func startHistoryEventMonitor() {
        guard historyEventMonitor == nil else { return }
        // Mouse drivers may send navigation gestures to the foreground app while our panel is pinned.
        globalHistoryMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { [weak self] event in
            guard let self, isVisible, !ignoresMouseEvents,
                  isTopWindow(at: NSEvent.mouseLocation), handleHistoryEvent(event) else { return }
            onMouseDown?()
        }
        // AppKit may receive these events without assigning them to a window.
        historyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { [weak self] event in
            guard let self, event.windowNumber == 0, isVisible, !ignoresMouseEvents else { return event }
            let point = event.type == .swipe ? NSEvent.mouseLocation : event.locationInWindow
            guard isTopWindow(at: point), handleHistoryEvent(event) else { return event }
            if event.type == .otherMouseDown { onMouseDown?() }
            return nil
        }
    }

    private func isTopWindow(at point: NSPoint) -> Bool {
        frame.contains(point) && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == windowNumber
    }

    override func orderOut(_ sender: Any?) {
        if let historyEventMonitor { NSEvent.removeMonitor(historyEventMonitor) }
        if let globalHistoryMonitor { NSEvent.removeMonitor(globalHistoryMonitor) }
        historyEventMonitor = nil
        globalHistoryMonitor = nil
        super.orderOut(sender)
    }

    func focusForInteraction() {
        if NSWorkspace.shared.frontmostApplication != .current {
            beforeActivating?()
            NSApp.activate()
        }
        if !isKeyWindow { makeKey() }
    }

    func presentFolder(_ folder: FileEntry, followingSelection: Bool) {
        let sourceFrame: () -> NSRect = { [weak self, url = folder.url] in
            guard let self else { return .zero }
            return quickLookSources.screenFrame(for: url, in: self)
        }
        let hidden = tabs.active.browser.showsHidden
        if let window = folderPreviewWindow, !window.ignoresMouseEvents, window.isVisible || followingSelection {
            let resuming = !window.isVisible
            window.updateFolder(folder, includeHidden: hidden, interfaceSize: settings.interfaceSize,
                                sourceFrame: sourceFrame, reload: resuming)
            if resuming {
                window.show(above: self, animation: settings.animation, followingSelection: true, sourceFrame: sourceFrame)
            }
            return
        }

        folderPreviewWindow?.close()
        let window = FolderPreviewPanel(folder: folder, includeHidden: hidden, interfaceSize: settings.interfaceSize)
        window.commandForKey = previewKeyCommand
        window.onDismiss = { [weak self] url in
            self?.recentlyClosedFolder = (url, ProcessInfo.processInfo.systemUptime)
        }
        window.onClose = { [weak self, weak window] in
            guard let self, folderPreviewWindow === window else { return }
            folderPreviewWindow = nil
        }
        folderPreviewWindow = window
        focusForInteraction()
        window.show(above: self, animation: settings.animation, followingSelection: followingSelection, sourceFrame: sourceFrame)
    }

    func dismissFolder(_ disposition: FilePreviewSession.FolderDismissal) {
        guard let window = folderPreviewWindow else { return }
        switch disposition {
        case .keepForSelection: window.hideForSelectionChange()
        case .animated where window.isVisible: window.dismiss()
        default: window.close()
        }
    }

    func reopenFolder() { folderPreviewWindow?.toggleVisibility() }

    func togglePreview() {
        let browser = tabs.active.browser
        if !preview.toggle(for: browser.selection) { browser.showPreview(browser.selection) }
    }

    func dismissNative(followingSelection: Bool) {
        guard let window = previewWindow else { return }
        window.ignoresMouseEvents = true
        if followingSelection { window.orderOut(nil) }
        else { window.close() }
    }

    func presentFiles(_ items: [URL], followingSelection: Bool) {
        if nativeState == .open, let window = previewWindow {
            if previewItems != items {
                previewItems = items
                reloadNativePreview(window)
            }
            return
        }
        guard let preview = QLPreviewPanel.shared() else { return }
        previewItems = items
        focusForInteraction()
        if !isMainWindow { makeMain() }
        if previewWindow === preview {
            startPreviewEventMonitor()
            if !followingSelection { reloadNativePreview(preview) }
        }
        preview.ignoresMouseEvents = false
        if followingSelection {
            // Quick Look can wait synchronously for the initial item while opening.
            // Show the panel first, then load the selection through its in-place update path.
            isOpeningNativePreviewWithoutItems = true
            preview.orderFront(nil)
            isOpeningNativePreviewWithoutItems = false
            if previewWindow === preview { reloadNativePreview(preview) }
        } else {
            preview.makeKeyAndOrderFront(nil)
        }
        installNativeCloseButtonAction(for: preview)
    }

    private func reloadNativePreview(_ preview: QLPreviewPanel) {
        preview.reloadData()
        preview.currentPreviewItemIndex = 0
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !previewItems.isEmpty }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewWindow = panel
            panel.dataSource = self
            panel.delegate = self
            startPreviewEventMonitor()
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            stopPreviewEventMonitor()
            restoreNativeCloseButtonAction()
            panel.dataSource = nil
            panel.delegate = nil
            previewWindow = nil
            previewItems = []
            preview.nativeControlEnded { NSApp.isActive }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        isOpeningNativePreviewWithoutItems ? 0 : previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard settings.animation != .off, !isOpeningNativePreviewWithoutItems,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let url = item?.previewItemURL else { return .zero }
        return quickLookSources.screenFrame(for: url, in: self)
    }

    func windowShouldClose(_ window: NSWindow) -> Bool {
        // Quick Look can continue receiving clicks during its closing transition.
        window.ignoresMouseEvents = true
        return true
    }

    func windowWillClose(_ notification: Notification) {
        stopPreviewEventMonitor()
        previewItems = []
    }

    private func installNativeCloseButtonAction(for preview: QLPreviewPanel) {
        guard let button = preview.standardWindowButton(.closeButton),
              nativeCloseButtonAction?.button !== button else { return }
        restoreNativeCloseButtonAction()
        // Quick Look's close button can start its animation without calling the window delegate.
        nativeCloseButtonAction = (button, button.target, button.action)
        button.target = self
        button.action = #selector(closeNativePreviewFromButton(_:))
    }

    private func restoreNativeCloseButtonAction() {
        guard let original = nativeCloseButtonAction else { return }
        nativeCloseButtonAction = nil
        guard original.button.target === self else { return }
        original.button.target = original.target
        original.button.action = original.action
    }

    @objc private func closeNativePreviewFromButton(_ sender: NSButton) {
        preview.close()
    }

    private func startPreviewEventMonitor() {
        guard previewEventMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        previewEventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self, let previewWindow else { return event }
            if event.type == .keyDown {
                return handleNativePreviewKey(event, from: event.window ?? NSApp.keyWindow) ? nil : event
            }
            return browserMouseEvent(event, duringZoomOf: previewWindow)
        }
    }

    func handleNativePreviewKey(_ event: NSEvent, from target: NSWindow?) -> Bool {
        // Keys queued during opening may still name the browser after Quick Look becomes key.
        guard let previewWindow, let command = previewKeyCommand?(event),
              target === previewWindow || (target === self && NSApp.keyWindow === previewWindow) else { return false }
        if !event.isARepeat {
            if command == .preview { togglePreview() }
            else { preview.close() }
        }
        return true
    }

    private func browserMouseEvent(_ event: NSEvent, duringZoomOf preview: QLPreviewPanel) -> NSEvent {
        // During its zoom, WindowServer can deliver clicks outside Quick Look's frame to it.
        let point = event.cgEvent?.unflippedLocation ?? NSEvent.mouseLocation
        if event.type == .leftMouseDown {
            forwardingPreviewClick = event.window === preview && !preview.frame.contains(point)
                && frame.contains(point) && isVisible && !ignoresMouseEvents
                && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: preview.windowNumber) == windowNumber
        }
        guard forwardingPreviewClick else { return event }
        if event.type == .leftMouseUp { forwardingPreviewClick = false }
        guard event.window !== self else { return event }
        return NSEvent.mouseEvent(with: event.type, location: convertPoint(fromScreen: point),
                                 modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                 windowNumber: windowNumber, context: nil, eventNumber: event.eventNumber,
                                 clickCount: event.clickCount, pressure: event.pressure) ?? event
    }

    private func stopPreviewEventMonitor() {
        if let previewEventMonitor { NSEvent.removeMonitor(previewEventMonitor) }
        previewEventMonitor = nil
        forwardingPreviewClick = false
    }

    private var isEditingText: Bool {
        (firstResponder as? NSTextView)?.isFieldEditor == true
    }

    private func handleHistoryEvent(_ event: NSEvent) -> Bool {
        let forward: Bool
        switch event.type {
        case .otherMouseDown where (3...4).contains(event.buttonNumber):
            forward = event.buttonNumber == 4
        case .swipe where event.deltaX != 0:
            forward = event.deltaX < 0
        default:
            return false
        }
        return attachedSheet == nil && onNavigateHistory?(forward) == true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyAction?(event, isEditingText) == true { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            onMouseDown?()
        }
        if handleHistoryEvent(event) { return }
        if event.type == .leftMouseDown {
            let point = event.locationInWindow
            let table = table(at: point, onHeader: onFileListHeaderPress)
            // End the table's double-click sequence when the user dismisses a folder preview.
            reselectedFolderAfterPreview = recentlyClosedFolder.flatMap {
                event.timestamp - $0.time <= NSEvent.doubleClickInterval ? $0.url : nil
            }
            recentlyClosedFolder = nil
            // Give the panel focus while the button is still down so this click can select the row.
            focusForInteraction()
            if event.clickCount == 1, !event.modifierFlags.contains(.control),
               let source = fileDragSource(at: point, in: table) {
                if source.entry?.canExpand == true, interactionTarget(FileDisclosureHitArea.Target.self, at: point) != nil {
                    super.sendEvent(event)
                    return
                }
                if let table, tabs.active.browser.displayMode == .list {
                    selectFileRowOnPress(event, in: table, source: source)
                }
                let singleSelection = event.modifierFlags.intersection([.command, .option, .shift]).isEmpty
                let selectForwardedItem = forwardingPreviewClick && (table == nil || singleSelection) ? source.selectOnPress : nil
                if trackFileDrag(from: event, source: source) { return }
                // The file view never tracked the original press in Quick Look.
                if let selectForwardedItem { selectForwardedItem(); return }
            }
            if let slider = firstResponder as? NSSlider,
               !slider.bounds.contains(slider.convert(event.locationInWindow, from: nil)) {
                makeFirstResponder(nil)
            }
            if let table {
                // Let the table process the same click that ends field editing.
                if isEditingText { makeFirstResponder(table) }
                let point = table.convert(event.locationInWindow, from: nil)
                if !event.modifierFlags.contains(.control), isBlankTablePoint(point, in: table) {
                    if let target = interactionTarget(ColumnClickTarget.Target.self, at: event.locationInWindow) {
                        target.clearSelection()
                        return
                    }
                    if onEmptyTableClick?() == true { return }
                }
                if !event.modifierFlags.contains(.control) {
                    FileClickTracking.forwardToAppKit(event) { super.sendEvent(event) }
                    return
                }
            }
        }
        if event.type == .leftMouseUp, table(at: event.locationInWindow) != nil {
            // AppKit may deliver a deferred table press while dispatching the corresponding release.
            FileClickTracking.forwardToAppKit(event) { super.sendEvent(event) }
            return
        }
        super.sendEvent(event)
    }

    func isReselectingDismissedFolder(_ items: Set<URL>) -> Bool {
        guard let folder = reselectedFolderAfterPreview, let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp else { return false }
        return items == [folder]
    }

    private func selectFileRowOnPress(_ event: NSEvent, in table: NSTableView, source: FileDragTarget) {
        guard let select = source.selectOnPress, !isEditingText,
              event.modifierFlags.intersection([.command, .shift, .option]).isEmpty else { return }
        let tablePoint = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: tablePoint)
        guard row >= 0, !table.selectedRowIndexes.contains(row),
              !isBlankTablePoint(tablePoint, in: table) else { return }
        // Update the model and native highlight before drag tracking waits for movement or mouse-up.
        select()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func trackFileDrag(from mouseDown: NSEvent, source: FileDragTarget) -> Bool {
        // Track before the table or tile handles mouseDown so it can start dragging on the first movement.
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        let origin = mouseDown.locationInWindow
        while isVisible {
            let deadline = Date(timeIntervalSinceNow: FileClickTracking.checkInterval)
            guard let event = NSApp.nextEvent(matching: mask, until: deadline, inMode: .eventTracking, dequeue: false) else {
                if !FileClickTracking.isButtonDown { return true }
                continue
            }
            if event.window !== self {
                // Drag tracking reads directly from the queue, before local event monitors run.
                guard forwardingPreviewClick, let previewWindow, event.window === previewWindow,
                      let original = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .eventTracking,
                                                     dequeue: true) else { return true }
                let routed = browserMouseEvent(original, duringZoomOf: previewWindow)
                guard routed.window === self else { return true }
                NSApp.postEvent(routed, atStart: true)
                continue
            }
            // Leave a normal mouseUp queued for the table or tile to finish the click.
            if event.type == .leftMouseUp { return false }
            _ = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .eventTracking, dequeue: true)
            let point = event.locationInWindow
            if hypot(point.x - origin.x, point.y - origin.y) >= 4, source.beginDrag(with: event) {
                return true
            }
        }
        return true
    }

    private func isBlankTablePoint(_ point: NSPoint, in table: NSTableView) -> Bool {
        let index = table.row(at: point)
        if index < 0 || table.column(at: point) < 0 { return true }
        if let outline = table as? NSOutlineView, let item = outline.item(atRow: index) {
            return outline.delegate?.outlineView?(outline, isGroupItem: item) == true
                || outline.delegate?.outlineView?(outline, shouldSelectItem: item) == false
        }
        return table.rowView(atRow: index, makeIfNecessary: false)?.isGroupRowStyle == true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyAction?(event, isEditingText) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
