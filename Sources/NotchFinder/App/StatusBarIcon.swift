import AppKit

@MainActor
func makeStatusBarIcon() -> NSImage {
    let folder = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))

    let size = NSSize(width: 18, height: 17)
    let image = NSImage(size: size, flipped: false) { _ in
        if let folder {
            let origin = NSPoint(x: (size.width - folder.size.width) / 2, y: 0)
            folder.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }

        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 6, y: 14, width: 6, height: 2),
            xRadius: 1,
            yRadius: 1
        ).fill()
        return true
    }
    image.accessibilityDescription = "Notch Finder"
    image.isTemplate = true
    return image
}
