import AppKit
import SwiftUI

struct ThemePresetPicker: NSViewRepresentable {
    @Binding var selection: PanelStylePreset
    let scheme: ColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectPreset(_:))
        button.setAccessibilityLabel(L10n.text("主題"))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        if coordinator.scheme != scheme {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.font = .systemFont(ofSize: 14)
            for preset in PanelStylePreset.available(in: scheme) {
                let item = NSMenuItem(title: preset.title, action: nil, keyEquivalent: "")
                item.representedObject = preset.rawValue
                item.image = badge(for: preset)
                if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
                menu.addItem(item)
            }
            button.menu = menu
            coordinator.scheme = scheme
        }
        if let item = button.itemArray.first(where: { $0.representedObject as? String == selection.rawValue }) {
            button.select(item)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        let font = button.font ?? .controlContentFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func titleWidth(_ title: String) -> CGFloat {
            (title as NSString).size(withAttributes: attributes).width
        }

        guard let widestTitle = button.itemTitles.map(titleWidth).max() else { return nil }
        let nativeSize = button.intrinsicContentSize
        let width = ceil(nativeSize.width - widestTitle + titleWidth(selection.title))
        return CGSize(width: width, height: nativeSize.height)
    }

    private func badge(for preset: PanelStylePreset) -> NSImage {
        let (surface, accent) = preset.previewColors(for: scheme)
        let badgeBounds = NSRect(x: 0, y: 0, width: 24, height: 24)
        let imageSize = NSSize(width: badgeBounds.width + 4, height: badgeBounds.height)
        return NSImage(size: imageSize, flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: badgeBounds.insetBy(dx: 0.5, dy: 0.5))
            surface.setFill()
            circle.fill()
            accent.withAlphaComponent(0.3).setStroke()
            circle.lineWidth = 1
            circle.stroke()

            let letters = NSAttributedString(string: "Aa", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: accent
            ])
            let size = letters.size()
            letters.draw(at: NSPoint(x: badgeBounds.midX - size.width / 2, y: badgeBounds.midY - size.height / 2))
            return true
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<PanelStylePreset>
        var scheme: ColorScheme?

        init(selection: Binding<PanelStylePreset>) {
            self.selection = selection
        }

        @objc func selectPreset(_ button: NSPopUpButton) {
            guard let id = button.selectedItem?.representedObject as? String,
                  let preset = PanelStylePreset(rawValue: id) else { return }
            selection.wrappedValue = preset
        }
    }
}
