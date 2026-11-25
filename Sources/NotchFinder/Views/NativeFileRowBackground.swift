import AppKit
import SwiftUI

// Keep the native selection and row reuse while applying borderless theme stripes.
struct NativeFileRowBackground: NSViewRepresentable {
    let stripe: NSColor

    func makeNSView(context: Context) -> Anchor { Anchor(frame: .zero) }

    func updateNSView(_ view: Anchor, context: Context) {
        view.stripe = stripe
        view.applyColor()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.restoreColor()
    }

    final class Anchor: NSView {
        var stripe: NSColor = .clear
        private weak var currentRow: NSTableRowView?
        private var originalColor: NSColor?
        private var appliedColor: NSColor?
        private weak var rowSeparator: NSView?
        private var wasSeparatorHidden = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { restoreColor() }
            else { applyColor() }
        }

        override func layout() {
            super.layout()
            applyColor()
        }

        func applyColor() {
            var ancestor = superview
            while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
            guard let row = ancestor as? NSTableRowView,
                  let table = row.enclosingScrollView?.documentView as? NSTableView else { return }
            let index = table.row(for: row)
            guard index >= 0 else { return }

            if currentRow !== row {
                restoreColor()
                currentRow = row
                originalColor = row.backgroundColor
            }
            let color = index.isMultiple(of: 2) ? NSColor.clear : stripe
            if row.backgroundColor != color { row.backgroundColor = color }
            appliedColor = color

            // AppKit draws a separator for custom stripes even with an empty grid style mask.
            let separator = row.subviews.first { String(describing: type(of: $0)) == "_NSTableRowSeparatorDrawingView" }
            if rowSeparator !== separator {
                restoreSeparator()
                rowSeparator = separator
                wasSeparatorHidden = separator?.isHidden ?? false
            }
            if let separator, !separator.isHidden { separator.isHidden = true }
        }

        func restoreColor() {
            if let row = currentRow, let originalColor, row.backgroundColor == appliedColor {
                row.backgroundColor = originalColor
            }
            currentRow = nil
            originalColor = nil
            appliedColor = nil
            restoreSeparator()
        }

        private func restoreSeparator() {
            rowSeparator?.isHidden = wasSeparatorHidden
            rowSeparator = nil
        }
    }
}
