import AppKit
import SwiftUI

struct FolderSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let textSize: CGFloat
    let fontStyle: PanelFontStyle

    private var font: NSFont {
        let systemFont = NSFont.systemFont(ofSize: textSize)
        let design: NSFontDescriptor.SystemDesign = switch fontStyle {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        guard let descriptor = systemFont.fontDescriptor.withDesign(design) else { return systemFont }
        return NSFont(descriptor: descriptor, size: textSize) ?? systemFont
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(field: self)
    }

    func makeNSView(context: Context) -> TextField {
        let field = TextField()
        field.isEditable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.didFocus = { [weak coordinator = context.coordinator, weak field] in
            if let field { coordinator?.readFocus(from: field) }
        }
        return field
    }

    func updateNSView(_ field: TextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = self
        let font = font
        if field.font != font { field.font = font }
        field.placeholderString = L10n.text("搜尋")
        field.setAccessibilityLabel(L10n.text("篩選此資料夾"))

        let editor = field.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
            editor?.string = text
        }
        if field.isFocused != focused {
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let window = field.window, let coordinator else { return }
                let focused = coordinator.field.focused
                if field.isFocused != focused { window.makeFirstResponder(focused ? field : nil) }
            }
        }
    }

    static func dismantleNSView(_ field: TextField, coordinator: Coordinator) {
        field.delegate = nil
        field.didFocus = nil
    }

    final class TextField: NSTextField {
        var didFocus: (() -> Void)?
        var isFocused: Bool { currentEditor() != nil || window?.firstResponder === self }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            didFocus?()
            return true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: FolderSearchField

        init(field: FolderSearchField) {
            self.field = field
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let input = notification.object as? TextField,
                  (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if field.text != input.stringValue { field.text = input.stringValue }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let input = notification.object as? TextField { readFocus(from: input) }
        }

        func readFocus(from input: TextField) {
            DispatchQueue.main.async { [weak input, weak self] in
                guard let self, let input, input.window != nil, input.delegate === self else { return }
                let focused = input.isFocused
                if field.focused != focused { field.focused = focused }
            }
        }
    }
}
