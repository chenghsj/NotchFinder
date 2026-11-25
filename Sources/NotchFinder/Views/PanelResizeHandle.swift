import AppKit
import SwiftUI

struct PanelResizeHandle: NSViewRepresentable {
    enum Edge {
        case left, right, bottomLeft, bottomRight

        var isCorner: Bool { self == .bottomLeft || self == .bottomRight }

        func resizeDelta(from start: CGPoint, to end: CGPoint) -> CGSize {
            let horizontal = end.x - start.x
            let growsToLeft = self == .left || self == .bottomLeft
            return CGSize(width: growsToLeft ? -horizontal : horizontal, height: isCorner ? end.y - start.y : 0)
        }

        var cursor: NSCursor {
            if #available(macOS 15, *) {
                switch self {
                case .left: .frameResize(position: .left, directions: .all)
                case .right: .frameResize(position: .right, directions: .all)
                case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
                case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
                }
            } else {
                isCorner ? .crosshair : .resizeLeftRight
            }
        }
    }

    let begin: () -> Void
    let update: (CGSize) -> Void
    let end: () -> Void
    var edge: Edge = .bottomRight

    func at(_ edge: Edge) -> Self {
        var grip = self
        grip.edge = edge
        return grip
    }

    func makeNSView(context: Context) -> Grip {
        Grip(edge: edge)
    }

    func updateNSView(_ view: Grip, context: Context) {
        view.begin = begin
        view.update = update
        view.end = end
    }

    final class Grip: NSView {
        let edge: Edge
        var begin: (() -> Void)?
        var update: ((CGSize) -> Void)?
        var end: (() -> Void)?
        private var startPoint: CGPoint?

        init(edge: Edge) {
            self.edge = edge
            super.init(frame: .zero)
            toolTip = L10n.text("拖曳以調整視窗大小")
            setAccessibilityElement(edge == .bottomRight)
            setAccessibilityRole(.growArea)
            setAccessibilityLabel(L10n.text("調整視窗大小"))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: edge.cursor)
        }

        override func mouseDown(with event: NSEvent) {
            startPoint = screenPoint(for: event)
            begin?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startPoint else { return }
            update?(edge.resizeDelta(from: startPoint, to: screenPoint(for: event)))
        }

        override func mouseUp(with event: NSEvent) {
            startPoint = nil
            end?()
        }

        private func screenPoint(for event: NSEvent) -> CGPoint {
            event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        }
    }
}
