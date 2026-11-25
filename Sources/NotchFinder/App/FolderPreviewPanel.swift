import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class FolderPreviewPanel: NSPanel, NSWindowDelegate {
    private static let defaultContentSize = NSSize(width: 560, height: 390)

    var onClose: (() -> Void)?
    var handlesKey: ((NSEvent) -> Bool)?

    init(folder: FileEntry, includeHidden: Bool, interfaceSize: FileDisplaySize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = folder.name
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        let content = NSView(frame: NSRect(origin: .zero, size: Self.defaultContentSize))
        let host = NSHostingView(rootView: FolderPreviewContents(
            folder: folder.url, includeHidden: includeHidden, interfaceSize: interfaceSize
        ))
        host.sizingOptions = []
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        contentView = content
        contentMinSize = NSSize(width: 320, height: 190)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(on screen: NSScreen?, sourceFrame: NSRect, animation: PanelAnimationSpeed) {
        if let display = screen ?? NSScreen.main {
            let available = display.visibleFrame.insetBy(dx: 12, dy: 12)
            let size = CGSize(width: min(frame.width, available.width), height: min(frame.height, available.height))
            setFrame(NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                            width: size.width, height: size.height), display: false)
        } else {
            center()
        }

        guard !sourceFrame.isEmpty, animation != .off, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            makeKeyAndOrderFront(nil)
            return
        }

        let destination = frame
        let startX = min(90, max(-90, sourceFrame.midX - destination.midX))
        let startY = min(90, max(-90, sourceFrame.midY - destination.midY))
        alphaValue = 0
        setFrame(destination.offsetBy(dx: startX, dy: startY), display: false)
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20 / animation.rate
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(destination, display: true)
            animator().alphaValue = 1
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handlePreviewKey(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handlePreviewKey(event) || super.performKeyEquivalent(with: event)
    }

    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        guard handlesKey?(event) == true else { return false }
        if !event.isARepeat { close() }
        return true
    }
}
