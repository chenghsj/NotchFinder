import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: PreferencesWindow?
    private let shortcuts: PanelShortcuts
    private let settings: NotchSettings
    private let controller: NotchController
    private var preferredContentSize = NSSize(width: 680, height: 460)

    init(settings: NotchSettings, shortcuts: PanelShortcuts, controller: NotchController) {
        self.settings = settings
        self.shortcuts = shortcuts
        self.controller = controller
        super.init()
        settings.interfaceSizeDidChange = { [weak self] in self?.resizeForInterfaceSize() }
    }

    var isVisible: Bool { window?.isVisible == true && window?.isMiniaturized == false }
    var isRecording: Bool { window?.isKeyWindow == true && shortcuts.recording != nil }

    func updateTitle() { window?.title = L10n.text("Notch Finder 設定") }

    func show() {
        if window == nil {
            let view = PreferencesView(settings: settings, shortcuts: shortcuts, tabs: controller.tabs,
                                       clipboardHistory: controller.clipboardHistory,
                                       restoreSize: controller.restoreDefaultSize, saveSize: controller.savePreferredSize)
            let window = PreferencesWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.capture = { [weak shortcuts] in shortcuts?.capture($0) == true }
            self.window = window
            updateTitle()
            resizeForInterfaceSize()
            window.center()
        }
        guard let window else { return }
        NSApp.activate()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        } else {
            if !window.isVisible {
                controller.prepareToShowPreferences()
                positionNearPinnedPanel(window)
            }
            orderFront(window)
        }
    }

    private func resizeForInterfaceSize() {
        guard let window, !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
        let scale = settings.interfaceSize.preferencesScale
        let originalFrame = window.frame
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8)
        let limit = available.map { window.contentRect(forFrameRect: $0).size }
        let maximumWidth = limit?.width ?? .greatestFiniteMagnitude
        let maximumHeight = limit?.height ?? .greatestFiniteMagnitude
        window.contentMinSize = NSSize(width: min(630 * scale, maximumWidth),
                                       height: min(400 * scale, maximumHeight))
        let size = NSSize(width: min(preferredContentSize.width * scale, maximumWidth),
                          height: min(preferredContentSize.height * scale, maximumHeight))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: originalFrame.minX, y: originalFrame.maxY - frame.height)
        if let available {
            frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
        }
        window.setFrame(frame, display: window.isVisible)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        let scale = settings.interfaceSize.preferencesScale
        preferredContentSize = NSSize(width: size.width / scale, height: size.height / scale)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        resizeForInterfaceSize()
    }

    private func positionNearPinnedPanel(_ window: NSWindow) {
        guard let placement = controller.pinnedPanelPlacement else { return }
        let frame = NotchGeometry.preferencesFrame(
            size: window.frame.size, beside: placement.frame, in: placement.visibleFrame
        )
        window.setFrameOrigin(frame.origin)
    }

    private func orderFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { window.orderFrontRegardless() }
        controller.setForegroundPreferencesWindow(window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        controller.setForegroundPreferencesWindow(window)
    }

    func windowDidResignKey(_ notification: Notification) {
        controller.setForegroundPreferencesWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        shortcuts.cancelRecording()
        controller.setForegroundPreferencesWindow(nil)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        controller.setForegroundPreferencesWindow(nil)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window else { return }
        resizeForInterfaceSize()
        controller.prepareToShowPreferences()
        positionNearPinnedPanel(window)
        orderFront(window)
    }
}

@MainActor
private final class PreferencesWindow: NSWindow {
    var capture: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if capture?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if capture?(event) == true { return }
        super.sendEvent(event)
    }
}
