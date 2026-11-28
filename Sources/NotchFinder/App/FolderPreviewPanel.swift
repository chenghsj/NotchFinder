import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class FolderPreviewPanel: NSPanel, NSWindowDelegate {
    private static let defaultContentSize = NSSize(width: 560, height: 390)

    private(set) var folderURL: URL
    private var sourceFrame: (() -> NSRect)?
    private var animationSpeed: PanelAnimationSpeed = .off
    private var zoomWindow: NSPanel?
    private var isClosing = false
    private var needsInitialKeyHandoff = false
    private var foregroundApplicationAtOpen: pid_t?

    var onClose: (() -> Void)?
    var onDismiss: ((URL) -> Void)?
    var commandForKey: ((NSEvent) -> PanelCommand?)?

    init(folder: FileEntry, includeHidden: Bool, interfaceSize: FileDisplaySize) {
        folderURL = folder.url
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = NSView(frame: NSRect(origin: .zero, size: Self.defaultContentSize))
        setContents(for: folder, includeHidden: includeHidden, interfaceSize: interfaceSize)
        contentMinSize = NSSize(width: 320, height: 190)
        delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func updateFolder(_ folder: FileEntry, includeHidden: Bool, interfaceSize: FileDisplaySize,
                      sourceFrame: @escaping () -> NSRect, reload: Bool = false) {
        guard reload || folderURL != folder.url else { return }
        folderURL = folder.url
        self.sourceFrame = sourceFrame
        needsInitialKeyHandoff = false
        setContents(for: folder, includeHidden: includeHidden, interfaceSize: interfaceSize)
        reveal()
    }

    func hideForSelectionChange() {
        needsInitialKeyHandoff = false
        discardZoomWindow()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private func setContents(for folder: FileEntry, includeHidden: Bool, interfaceSize: FileDisplaySize) {
        guard let contentView else { return }
        title = folder.name
        let host = NSHostingView(rootView: FolderPreviewContents(
            folder: folder.url, includeHidden: includeHidden, interfaceSize: interfaceSize,
            didFinishLoading: { [weak self] in await self?.finishInitialKeyHandoff() }
        ))
        host.sizingOptions = []
        host.frame = contentView.bounds
        host.autoresizingMask = [.width, .height]
        contentView.subviews = [host]
    }

    func show(above browser: NSWindow?, animation: PanelAnimationSpeed, followingSelection: Bool = false,
              sourceFrame: @escaping () -> NSRect) {
        self.sourceFrame = sourceFrame
        animationSpeed = animation
        if let display = browser?.screen ?? NSScreen.main {
            let available = display.visibleFrame.insetBy(dx: 12, dy: 12)
            let size = CGSize(width: min(frame.width, available.width), height: min(frame.height, available.height))
            setFrame(NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                            width: size.width, height: size.height), display: false)
        } else {
            center()
        }

        let source = followingSelection ? nil : animationSourceFrame
        if !followingSelection {
            needsInitialKeyHandoff = true
            foregroundApplicationAtOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
            // A system permission prompt can take focus before the opening transition finishes.
            hidesOnDeactivate = false
            if source != nil { alphaValue = 0 }
        }
        // Clicking another browser row must leave the preview's title bar accessible.
        browser?.addChildWindow(self, ordered: .above)
        if followingSelection { orderFront(nil) }
        else { makeKeyAndOrderFront(nil) }
        if let source, animateZoom(from: source, opening: true) { return }
        reveal()
    }

    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        onDismiss?(folderURL)
        // The invisible preview must let clicks reach the file list during the closing zoom.
        ignoresMouseEvents = true
        if zoomWindow == nil, let source = animationSourceFrame, animateZoom(from: source, opening: false) {
            return
        }
        close()
    }

    func toggleVisibility() {
        guard isClosing else {
            dismiss()
            return
        }
        isClosing = false
        reveal()
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        needsInitialKeyHandoff = false
        discardZoomWindow()
        parent?.removeChildWindow(self)
        super.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
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
        switch commandForKey?(event) {
        case .preview:
            if !event.isARepeat { toggleVisibility() }
        case .close:
            if !event.isARepeat { dismiss() }
        default:
            return false
        }
        return true
    }

    private func reveal() {
        ignoresMouseEvents = false
        alphaValue = 1
        discardZoomWindow()
        restoreDeactivationBehavior()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        restoreDeactivationBehavior()
    }

    private func restoreDeactivationBehavior() {
        guard NSApp.isActive, isVisible, alphaValue == 1, zoomWindow == nil, !isClosing else { return }
        hidesOnDeactivate = true
    }

    private func finishInitialKeyHandoff() async {
        guard needsInitialKeyHandoff else { return }
        needsInitialKeyHandoff = false
        guard !NSApp.isActive || !isKeyWindow else { return }

        let deadline = ContinuousClock.now + .milliseconds(750)
        var requestedKey = false
        do {
            while canFinishInitialKeyHandoff, ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if NSApp.isActive, isKeyWindow { return }

                if !requestedKey, zoomWindow == nil {
                    // A system prompt can return folder access before it returns keyboard focus.
                    let returnedToPreviousApp = foregroundApplicationAtOpen != nil
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundApplicationAtOpen
                    if NSApp.isActive || returnedToPreviousApp {
                        requestedKey = true
                        if !NSApp.isActive { NSApp.activate() }
                        makeKeyAndOrderFront(nil)
                    }
                }
                try await Task.sleep(for: .milliseconds(15))
            }
        } catch {
            return
        }
    }

    private var canFinishInitialKeyHandoff: Bool {
        isVisible && !isClosing && (NSApp.keyWindow == nil || NSApp.keyWindow === self)
    }

    private func discardZoomWindow() {
        guard let overlay = zoomWindow else { return }
        zoomWindow = nil
        overlay.orderOut(nil)
        for layer in overlay.contentView?.layer?.sublayers ?? [] { layer.removeAllAnimations() }
    }

    private var animationSourceFrame: NSRect? {
        guard animationSpeed != .off, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let source = sourceFrame?(), !source.isEmpty else { return nil }
        return source
    }

    private func animateZoom(from source: NSRect, opening: Bool) -> Bool {
        // Scale a snapshot so the table and title bar keep their layout during the zoom.
        guard let frameView = contentView?.superview else { return false }
        frameView.layoutSubtreeIfNeeded()
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        guard let snapshot = bitmap.cgImage else { return false }

        let destination = frame
        let area = destination.union(source).insetBy(dx: -24, dy: -24)
        let overlay = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = hidesOnDeactivate
        overlay.level = level
        overlay.collectionBehavior = collectionBehavior
        overlay.animationBehavior = .none
        guard let view = overlay.contentView else { return false }
        view.wantsLayer = true
        guard let canvas = view.layer else { return false }
        zoomWindow = overlay

        let start = CGPoint(x: source.midX - area.minX, y: source.midY - area.minY)
        let end = CGPoint(x: destination.midX - area.minX, y: destination.midY - area.minY)
        let previewScale = min(source.width / destination.width, source.height / destination.height)
        let iconScale = max(1, 128 / max(source.width, source.height))
        let preview = CALayer()
        preview.bounds = CGRect(origin: .zero, size: destination.size)
        let image = CALayer()
        image.frame = preview.bounds
        image.contents = snapshot
        if #available(macOS 26, *) { image.cornerRadius = 18 } else { image.cornerRadius = 10 }
        image.masksToBounds = true
        preview.addSublayer(image)
        preview.shadowPath = CGPath(roundedRect: preview.bounds, cornerWidth: image.cornerRadius,
                                    cornerHeight: image.cornerRadius, transform: nil)
        preview.shadowOpacity = 0.28
        preview.shadowRadius = 12
        preview.shadowOffset = CGSize(width: 0, height: -4)

        let icon = CALayer()
        icon.bounds = CGRect(origin: .zero, size: source.size)
        icon.contents = NSWorkspace.shared.icon(forFile: folderURL.path).cgImage(
            forProposedRect: nil, context: nil, hints: nil
        )
        icon.contentsGravity = .resizeAspect

        let finish: @MainActor @Sendable () -> Void = { [weak self, weak overlay] in
            guard let self, let overlay, self.zoomWindow === overlay else { return }
            if opening { self.reveal() } else { self.close() }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(finish)
        canvas.addSublayer(preview)
        canvas.addSublayer(icon)
        let duration = (opening ? 0.24 : 0.19) / animationSpeed.rate
        Self.animate(preview, from: start, to: end, scale: (previewScale, 1),
                     opacity: (0, 1), opening: opening, duration: duration)
        Self.animate(icon, from: start, to: end, scale: (1, iconScale),
                     opacity: (1, 0), opening: opening, duration: duration)
        overlay.order(.above, relativeTo: windowNumber)
        alphaValue = 0
        CATransaction.commit()
        // The preview must settle even when the overlay's animations stop advancing.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.10, execute: finish)
        return true
    }

    private static func animate(_ layer: CALayer, from source: CGPoint, to destination: CGPoint,
                                scale: (CGFloat, CGFloat), opacity: (Float, Float),
                                opening: Bool, duration: TimeInterval) {
        let finalPosition = opening ? destination : source
        let finalScale = opening ? scale.1 : scale.0
        let finalOpacity = opening ? opacity.1 : opacity.0
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = opening ? source : destination
        position.toValue = finalPosition
        let zoom = CABasicAnimation(keyPath: "transform.scale")
        zoom.fromValue = opening ? scale.0 : scale.1
        zoom.toValue = finalScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opening ? opacity.0 : opacity.1
        fade.toValue = finalOpacity
        layer.position = finalPosition
        layer.transform = CATransform3DMakeScale(finalScale, finalScale, 1)
        layer.opacity = finalOpacity

        let transition = CAAnimationGroup()
        let animations = [position, zoom, fade]
        for animation in animations { animation.duration = duration }
        transition.animations = animations
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)
        layer.add(transition, forKey: "zoom")
    }
}
