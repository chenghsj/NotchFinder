import AppKit
import Carbon.HIToolbox
import CoreGraphics
import QuickLookUI

enum ClipboardPasteResult {
    case started, copied, unavailable
}

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
    private var hover = NotchHover()
    private var fileDropDismissal: Task<Void, Never>?
    private var resumesHoverAfterFileDrop = false
    private var wasPreviewVisible = false
    private var preferredPanelSize: CGSize
    private var sizeBeforeResize: CGSize?
    private var pasteTarget: NSRunningApplication?
    private var requestedPasteAccess = false

    init(settings: NotchSettings = NotchSettings(), shortcuts: PanelShortcuts = PanelShortcuts(),
         clipboardHistory: ClipboardHistory = ClipboardHistory()) {
        self.settings = settings
        self.shortcuts = shortcuts
        self.clipboardHistory = clipboardHistory
        tabs = BrowserTabs(initialDirectory: settings.startDirectory, defaults: settings.defaults,
                           clipboardHistory: clipboardHistory)
        preferredPanelSize = settings.remembersSize
            ? NotchGeometry.savedPanelSize(in: settings.defaults) : NotchGeometry.defaultPanelSize
        super.init()
        browser.onPreview = { [weak self] items in self?.showPreview(items) }
        tabs.onActivate = { [weak self] in self?.panel?.closePreview() }
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
            workspace.addObserver(self, selector: #selector(refreshSidebarVolumes), name: event, object: nil)
        }

        // Sample pointer location without installing an event tap or a window over the menu bar.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover(at: NSEvent.mouseLocation) }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
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

    func prepareToShowPreferences() {
        panel?.closePreview()
        if !settings.panelPinned { dismiss(animated: false) }
    }

    func setForegroundPreferencesWindow(_ window: NSWindow?) {
        if foregroundPreferencesWindow !== window { foregroundPreferencesWindow?.level = .normal }
        foregroundPreferencesWindow = window
        window?.level = .floating
        guard let panel, currentDisplay != nil else { return }
        if let window, window.isVisible {
            orderPanel(panel, behind: window)
        } else if panel.isVisible && !panel.isPreviewVisible {
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

    @objc private func refreshSidebarVolumes() {
        browser.sidebar.refreshVolumes()
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
            hover.didHide(suppressUntilExit: false)
        }
    }

    func updateHover(at pointer: NSPoint) {
        let tracksEvents = RunLoop.main.currentMode == .eventTracking
        if !tracksEvents { resumesHoverAfterFileDrop = false }
        guard sizeBeforeResize == nil, !tracksEvents || resumesHoverAfterFileDrop else { return }
        let display = currentDisplay ?? displays.first { $0.trigger?.contains(pointer) == true }
        let insidePanel = currentDisplay != nil && panel?.frame.insetBy(dx: -5, dy: -5).contains(pointer) == true
        let heldOpen = currentDisplay != nil && (settings.panelPinned || !settings.autoHide)
        let previewVisible = panel?.isPreviewVisible == true
        if wasPreviewVisible && !previewVisible && currentDisplay != nil {
            hover.didShow(manually: true)
        }
        wasPreviewVisible = previewVisible
        let event = hover.update(
            insideTrigger: (settings.hoverEnabled || currentDisplay != nil) && display?.trigger?.contains(pointer) == true,
            insidePanel: insidePanel || browser.editing != nil || previewVisible || heldOpen,
            mouseDown: NSEvent.pressedMouseButtons != 0,
            now: ProcessInfo.processInfo.systemUptime,
            showDelay: settings.hoverDelay,
            hideDelay: settings.hideDelay
        )

        switch event {
        case .show:
            if let display { present(on: display, manually: false) }
        case .hide:
            dismiss(suppressUntilExit: false)
        case nil:
            break
        }
    }

    private func present(on display: Display, manually: Bool, bringToFront: Bool = false) {
        cancelFileDropDismissal()
        let panel = panel ?? makePanel()
        self.panel = panel
        let opening = currentDisplay == nil
        if opening {
            rememberPasteTarget()
            if !settings.remembersSize { preferredPanelSize = NotchGeometry.defaultPanelSize }
        }
        currentDisplay = display
        hover.didShow(manually: manually)
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
        if opening || frameChanged || !wasVisible {
            content.setExpanded(true, animated: opening, speed: settings.animation) { [weak self] in
                self?.browser.enableFileIcons()
            }
        }
    }

    private func dismiss(suppressUntilExit: Bool = true, animated: Bool = true) {
        guard currentDisplay != nil, let panel else { return }
        cancelFileDropDismissal()
        finishResize()
        currentDisplay = nil
        tabs.setPanelVisible(false)
        wasPreviewVisible = false
        settings.panelPinned = false
        hover.didHide(suppressUntilExit: suppressUntilExit)
        panel.closePreview()

        panel.animatedContent.setExpanded(false, animated: animated, speed: settings.animation) { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func fileDragEnded() {
        guard currentDisplay != nil, settings.autoHide, !settings.panelPinned else { return }
        fileDropDismissal?.cancel()
        let delay = settings.hideDelay
        // The system can remain in event tracking after it delivers the drop.
        fileDropDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            fileDropDismissal = nil
            guard currentDisplay != nil, let panel, settings.autoHide, !settings.panelPinned,
                  sizeBeforeResize == nil, browser.editing == nil, !panel.isPreviewVisible else { return }
            let pointer = NSEvent.mouseLocation
            let windowUnderPointer = NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0)
            guard windowUnderPointer != panel.windowNumber else { return }
            // Restore hover immediately while the completed drag still owns the tracking loop.
            resumesHoverAfterFileDrop = true
            let pointerAtNotch = displays.contains { $0.trigger?.contains(pointer) == true }
            dismiss(suppressUntilExit: pointerAtNotch)
        }
    }

    private func cancelFileDropDismissal() {
        fileDropDismissal?.cancel()
        fileDropDismissal = nil
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
        guard let command = shortcuts.command(for: event) else { return false }
        if editingText && command != .close && command != .settings && command != .filter {
            let usesModifier = !event.modifierFlags.intersection([.command, .control]).isEmpty
            if !command.isTabCommand || !usesModifier { return false }
        }
        if tabs.showsClipboard {
            switch command {
            case .close, .back:
                if !event.isARepeat { tabs.closeClipboard() }
                return true
            case .reload:
                if !event.isARepeat { clipboardHistory.refreshPreview() }
                return true
            case .filter:
                if !event.isARepeat { focusSearch() }
                return true
            case .goToFolder, .paste:
                if event.isARepeat { return true }
                tabs.closeClipboard()
            case .forward, .parent, .togglePanel, .settings, .pin, .newTab, .closeTab, .nextTab, .previousTab:
                break
            default:
                return false
            }
        }
        let selection = browser.selection
        if command == .preview && selection.isEmpty && panel?.isPreviewVisible != true { return false }
        if event.isARepeat { return true }
        switch command {
        case .togglePanel: return false
        case .settings: showSettings()
        case .close: closeOrCancel()
        case .pin: settings.panelPinned.toggle()
        case .back: browser.goBack()
        case .forward: tabs.goForward()
        case .parent: tabs.goUp()
        case .goToFolder: browser.beginEditing(.goToFolder)
        case .filter: focusSearch()
        case .reload: browser.reload()
        case .toggleHidden: browser.setShowsHidden(!browser.showsHidden)
        case .open: browser.openItems(selection)
        case .preview:
            if panel?.isPreviewVisible == true { panel?.closePreview() }
            else { browser.showPreview(selection) }
        case .selectAll:
            browser.selection = FileListing(browser: browser, settings: settings).visibleIDs
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
        }
        return true
    }

    private func closeOrCancel() {
        if panel?.isPreviewVisible == true { panel?.closePreview() }
        else if browser.editing != nil { browser.cancelEditing() }
        else if tabs.showsClipboard { tabs.closeClipboard() }
        else { dismiss() }
    }

    private func showPreview(_ selected: Set<URL>) {
        let entries = FileListing(browser: browser, settings: settings).selected(selected)
        guard !entries.isEmpty else { return }
        let folder = entries.count == 1 ? entries.first(where: \.isFolder) : nil
        panel?.showPreview(entries.map(\.url), folder: folder, includeHidden: browser.showsHidden, settings: settings)
    }

    private func focusSearch() {
        panel?.focusForInteraction()
        settings.filterFocusRequest += 1
    }

    private func showSettings() {
        openSettings?()
    }

    private func rememberPasteTarget() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != NSRunningApplication.current.processIdentifier,
           app.activationPolicy == .regular {
            pasteTarget = app
        }
    }

    private func pasteClipboard(_ row: ClipboardHistory.Row) -> ClipboardPasteResult {
        if case .files(let urls) = row.contents {
            guard !browser.isUpdatingFiles, !browser.showsRecentItems else { return .unavailable }
            if case .current = row, clipboardHistory.restore(row) == nil { return .unavailable }
            tabs.closeClipboard()
            browser.pasteItems(urls, cleanupInstaller: settings.cleansDiskImageAfterInstall)
            return .started
        }

        guard let target = pasteTarget, !target.isTerminated,
              let snapshot = clipboardHistory.restore(row) else { return .unavailable }
        if !CGPreflightPostEventAccess() {
            guard !requestedPasteAccess else { return .copied }
            requestedPasteAccess = true
            guard CGRequestPostEventAccess() else { return .copied }
        }

        dismiss()
        if !target.isActive {
            NSApp.yieldActivation(to: target)
            _ = target.activate(options: [])
        }
        let changeCount = snapshot.changeCount
        Task { @MainActor in
            for _ in 0..<15 {
                if target.isActive || target.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(55))
            let pid = target.processIdentifier
            // If focus or clipboard data changed, leave the copied item available for manual paste.
            guard !target.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  NSPasteboard.general.changeCount == changeCount,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return .started
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(rootView: BrowserPanel(
            tabs: tabs,
            settings: settings,
            quickLookSources: QuickLookSources(),
            close: { [weak self] in self?.closeOrCancel() },
            openSettings: { [weak self] in self?.showSettings() },
            clipboardPasteTarget: { [weak self] in
                guard let target = self?.pasteTarget, !target.isTerminated else { return nil }
                return target.localizedName
            },
            pasteClipboard: { [weak self] in self?.pasteClipboard($0) ?? .unavailable },
            resizeHandle: PanelResizeHandle(
                begin: { [weak self] in self?.beginResize() },
                update: { [weak self] delta in self?.resize(by: delta) },
                end: { [weak self] in self?.finishResize() }
            ),
            onFileDragEnded: { [weak self] in self?.fileDragEnded() }
        ))
        panel.beforeActivating = { [weak self] in self?.rememberPasteTarget() }
        panel.onEmptyTableClick = { [weak self] in
            guard let self, !tabs.showsClipboard else { return false }
            browser.selection.removeAll()
            return true
        }
        panel.onMouseDown = { [weak self] in
            // A drag can leave the panel before the next pointer sample.
            self?.resumesHoverAfterFileDrop = false
            self?.cancelFileDropDismissal()
            self?.hover.didInteract()
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
        panel.previewKeyAction = { [weak self] event in
            let command = self?.shortcuts.command(for: event)
            return command == .preview || command == .close
        }
        panel.onDismiss = { [weak self] in
            guard let self else { return }
            if self.browser.editing != nil || self.panel?.isPreviewVisible == true
                || self.shortcuts[.close].matches(PanelCommand.close.defaultShortcut) {
                self.closeOrCancel()
            }
        }
        return panel
    }
}

@MainActor
private final class NotchPanel: NSPanel, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    let animatedContent: AnimatedPanelView
    private let quickLookSources: QuickLookSources
    var onDismiss: (() -> Void)?
    var beforeActivating: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onEmptyTableClick: (() -> Bool)?
    var keyAction: ((NSEvent, Bool) -> Bool)?
    var previewKeyAction: ((NSEvent) -> Bool)?
    private var previewItems: [URL] = []
    private weak var previewWindow: QLPreviewPanel?
    private var folderPreviewWindow: FolderPreviewPanel?
    private var previewKeyMonitor: Any?

    var isPreviewVisible: Bool { previewWindow?.isVisible == true || folderPreviewWindow?.isVisible == true }

    init(rootView: BrowserPanel) {
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

    func focusForInteraction() {
        if !NSApp.isActive {
            beforeActivating?()
            NSApp.activate()
        }
        if !isKeyWindow { makeKey() }
    }

    func showPreview(_ items: [URL], folder: FileEntry?, includeHidden: Bool, settings: NotchSettings) {
        guard !items.isEmpty, isVisible else { return }
        if let folder {
            closePreview()
            let source = quickLookSources.screenFrame(for: folder.url, in: self)
            let window = FolderPreviewPanel(folder: folder, includeHidden: includeHidden,
                                            interfaceSize: settings.interfaceSize)
            window.handlesKey = previewKeyAction
            window.onClose = { [weak self] in self?.folderPreviewWindow = nil }
            folderPreviewWindow = window
            focusForInteraction()
            window.show(on: screen, sourceFrame: source, animation: settings.animation)
            return
        }
        folderPreviewWindow?.close()
        guard let preview = QLPreviewPanel.shared() else { return }
        previewItems = items
        focusForInteraction()
        if !isMainWindow { makeMain() }
        if previewWindow === preview {
            startPreviewKeyMonitor()
            preview.reloadData()
            preview.currentPreviewItemIndex = 0
        }
        preview.makeKeyAndOrderFront(nil)
    }

    func closePreview() {
        folderPreviewWindow?.close()
        if let previewWindow, previewWindow.isVisible { previewWindow.close() }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !previewItems.isEmpty }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewWindow = panel
            panel.dataSource = self
            panel.delegate = self
            startPreviewKeyMonitor()
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            stopPreviewKeyMonitor()
            panel.dataSource = nil
            panel.delegate = nil
            previewWindow = nil
            previewItems = []
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let url = item?.previewItemURL else { return .zero }
        return quickLookSources.screenFrame(for: url, in: self)
    }

    func windowWillClose(_ notification: Notification) {
        stopPreviewKeyMonitor()
        previewItems = []
    }

    private func startPreviewKeyMonitor() {
        guard previewKeyMonitor == nil else { return }
        // Let the user’s shortcut take precedence over Quick Look’s own shortcuts.
        previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let previewWindow = self.previewWindow, previewWindow.isVisible,
                  (event.window ?? NSApp.keyWindow) === previewWindow,
                  self.previewKeyAction?(event) == true else { return event }
            if !event.isARepeat { self.closePreview() }
            return nil
        }
    }

    private func stopPreviewKeyMonitor() {
        if let previewKeyMonitor { NSEvent.removeMonitor(previewKeyMonitor) }
        previewKeyMonitor = nil
    }

    private var isEditingText: Bool {
        (firstResponder as? NSTextView)?.isFieldEditor == true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyAction?(event, isEditingText) == true { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            onMouseDown?()
        }
        if event.type == .leftMouseDown {
            focusForInteraction()
            if let table = table(at: event.locationInWindow) {
                // Let the table process the same click that ends field editing.
                if isEditingText { makeFirstResponder(table) }
                let point = table.convert(event.locationInWindow, from: nil)
                if !event.modifierFlags.contains(.control), isBlankTablePoint(point, in: table), onEmptyTableClick?() == true {
                    return
                }
            }
        }
        super.sendEvent(event)
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

    private func table(at point: NSPoint) -> NSTableView? {
        guard let contentView else { return nil }
        let location = contentView.superview?.convert(point, from: nil) ?? point
        var hit = contentView.hitTest(location)
        while let view = hit {
            if let table = view as? NSTableView { return table }
            if view is NSScroller || view is NSTableHeaderView { return nil }
            if let scrollView = view as? NSScrollView,
               let table = scrollView.documentView as? NSTableView,
               scrollView.contentView.bounds.contains(scrollView.contentView.convert(point, from: nil)) {
                return table
            }
            hit = view.superview
        }
        return nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyAction?(event, isEditingText) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
