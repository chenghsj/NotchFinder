import AppKit

struct NotchGeometry {
    static let defaultPanelSize = CGSize(width: 662, height: 410)
    private static let minimumPanelSize = CGSize(width: 540, height: 280)
    private static let sizePreferenceKey = "panelSize"

    let trigger: NSRect
    let centerX: CGFloat
    let width: CGFloat
    let bottom: CGFloat

    @MainActor
    init?(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            topInset: screen.safeAreaInsets.top,
            leftArea: screen.auxiliaryTopLeftArea,
            rightArea: screen.auxiliaryTopRightArea
        )
    }

    static func topCenterTrigger(frame: NSRect, visibleFrame: NSRect) -> NSRect {
        let width = min(124, frame.width)
        let bottom = max(frame.minY, min(frame.maxY - 10, visibleFrame.maxY - 5))
        return NSRect(x: frame.midX - width / 2, y: bottom, width: width, height: frame.maxY - bottom + 1)
    }

    init?(frame: NSRect, topInset: CGFloat, leftArea: NSRect?, rightArea: NSRect?) {
        guard topInset > 0,
              let left = leftArea,
              let right = rightArea,
              right.minX > left.maxX else { return nil }

        bottom = frame.maxY - topInset
        centerX = (left.maxX + right.minX) / 2
        width = right.minX - left.maxX
        trigger = NSRect(
            x: left.maxX - 3,
            y: bottom - 9,
            width: width + 6,
            height: topInset + 10
        )
    }

    @MainActor
    static func panelFrame(on screen: NSScreen, notch: NotchGeometry?, requestedSize: CGSize) -> NSRect {
        panelFrame(in: screen.visibleFrame, notch: notch, requestedSize: requestedSize)
    }

    static func panelFrame(in visibleFrame: NSRect, notch: NotchGeometry?, requestedSize: CGSize) -> NSRect {
        let top = notch?.bottom ?? visibleFrame.maxY
        let left = visibleFrame.minX + 8
        let right = visibleFrame.maxX - 8
        let centerX = notch?.centerX ?? visibleFrame.midX
        let availableWidth = max(1, 2 * min(centerX - left, right - centerX))
        let availableHeight = max(1, top - visibleFrame.minY - 8)
        let width = min(availableWidth, max(minimumPanelSize.width, requestedSize.width))
        let height = min(availableHeight, max(minimumPanelSize.height, requestedSize.height))

        return NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }

    static func savedPanelSize(in defaults: UserDefaults = .standard) -> CGSize {
        guard let values = defaults.array(forKey: sizePreferenceKey) as? [Double], values.count == 2,
              values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return defaultPanelSize }
        return CGSize(width: values[0], height: values[1])
    }

    static func preferencesFrame(size: CGSize, beside panel: NSRect, in visibleFrame: NSRect) -> NSRect {
        let usable = visibleFrame.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 12
        let right = usable.maxX - panel.maxX - gap
        let left = panel.minX - usable.minX - gap
        let x: CGFloat
        let y: CGFloat
        if right >= size.width && right >= left {
            x = panel.maxX + gap
            y = panel.maxY - size.height
        } else if left >= size.width {
            x = panel.minX - gap - size.width
            y = panel.maxY - size.height
        } else {
            x = panel.midX - size.width / 2
            y = panel.minY - gap - size.height
        }

        return NSRect(
            x: max(usable.minX, min(x, usable.maxX - size.width)),
            y: max(usable.minY, min(y, usable.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    static func savePanelSize(_ size: CGSize, in defaults: UserDefaults = .standard) {
        defaults.set([Double(size.width), Double(size.height)], forKey: sizePreferenceKey)
    }
}
