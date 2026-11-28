import AppKit
import SwiftUI

@MainActor
enum FileClickTracking {
    static let checkInterval: TimeInterval = 0.05
    static var isButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    static func forwardToAppKit(_ mouseEvent: NSEvent,
                               isPressed: @escaping @MainActor () -> Bool = { isButtonDown },
                               postRelease: @escaping @MainActor (NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) },
                               send: () -> Void) {
        let windowNumber = mouseEvent.windowNumber
        let location = mouseEvent.locationInWindow
        let modifiers = mouseEvent.modifierFlags
        let eventNumber = mouseEvent.eventNumber
        let clickCount = mouseEvent.clickCount
        let timer = Timer(timeInterval: checkInterval, repeats: true) { timer in
            let postedRelease = MainActor.assumeIsolated {
                // A delayed table mouseDown can reach AppKit after the real mouseUp was consumed.
                guard !isPressed() else { return false }
                guard let release = NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                                                       modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: windowNumber, context: nil, eventNumber: eventNumber,
                                                       clickCount: clickCount, pressure: 0) else { return false }
                postRelease(release)
                return true
            }
            if postedRelease { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        send()
    }
}

struct FileDragSource: NSViewRepresentable {
    let entry: FileEntry
    let entries: [FileEntry]
    let browser: FileBrowser
    var allowsMovingSelection = false
    let didEnd: () -> Void
    var selectOnPress: (() -> Void)? = nil

    func makeNSView(context: Context) -> FileDragTarget { FileDragTarget() }

    func updateNSView(_ view: FileDragTarget, context: Context) {
        view.entry = entry
        view.files = {
            let selection = browser.selection
            guard selection.count > 1, selection.contains(entry.id) else { return [entry.url] }
            return entries.filter { selection.contains($0.id) }.map(\.url)
        }
        view.allowsMovingSelection = allowsMovingSelection
        view.didEnd = didEnd
        view.selectOnPress = selectOnPress
    }
}

final class FileDragTarget: NSView, NSDraggingSource {
    var entry: FileEntry?
    var files: () -> [URL] = { [] }
    var allowsMovingSelection = false
    var didEnd: () -> Void = {}
    var selectOnPress: (() -> Void)?
    private var externalOperations: NSDragOperation = .copy

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func beginDrag(with event: NSEvent) -> Bool {
        guard let entry, let window, window === event.window else { return false }
        let urls = files()
        guard !urls.isEmpty else { return false }
        externalOperations = allowsMovingSelection && urls.count > 1 ? [.copy, .move, .link] : .copy
        let pointer = convert(event.locationInWindow, from: nil)
        let iconFrame = NSRect(x: pointer.x - 16, y: pointer.y - 16, width: 32, height: 32)
        let items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            if url == entry.url {
                addPreview(to: item, icon: icon, frame: iconFrame, name: entry.name)
            } else {
                item.setDraggingFrame(iconFrame, contents: icon)
            }
            return item
        }
        beginDraggingSession(with: items, event: event, source: self).draggingFormation = .pile
        return true
    }

    private func addPreview(to item: NSDraggingItem, icon: NSImage, frame: NSRect, name: String) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ])
        let textSize = text.size()
        let inset: CGFloat = 8
        let labelSize = NSSize(width: min(240, ceil(textSize.width)) + 2 * inset, height: 24)
        let label = NSImage(size: labelSize, flipped: false) { bounds in
            NSColor(white: 0.13, alpha: 0.94).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            text.draw(with: NSRect(x: inset, y: floor((bounds.height - ceil(textSize.height)) / 2),
                                   width: bounds.width - 2 * inset, height: ceil(textSize.height)),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        let labelFrame = NSRect(x: frame.width + 4, y: (frame.height - labelSize.height) / 2,
                                width: labelSize.width, height: labelSize.height)
        item.draggingFrame = NSRect(origin: frame.origin, size: NSSize(width: labelFrame.maxX, height: frame.height))
        item.imageComponentsProvider = {
            let iconComponent = NSDraggingImageComponent(key: .icon)
            iconComponent.frame = NSRect(origin: .zero, size: frame.size)
            iconComponent.contents = icon
            let labelComponent = NSDraggingImageComponent(key: .label)
            labelComponent.frame = labelFrame
            labelComponent.contents = label
            return [iconComponent, labelComponent]
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move, .delete] : externalOperations
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        didEnd()
    }
}

extension NSWindow {
    func fileDragSource(at point: NSPoint, in table: NSTableView?) -> FileDragTarget? {
        if let table {
            let localPoint = table.convert(point, from: nil)
            let row = table.row(at: localPoint)
            guard row >= 0, table.column(at: localPoint) >= 0,
                  let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { return nil }
            return fileDragSource(in: rowView)
        }
        return interactionTarget(FileDragTarget.self, at: point)
    }

    private func fileDragSource(in view: NSView) -> FileDragTarget? {
        if let target = view as? FileDragTarget { return target }
        return view.subviews.lazy.compactMap { self.fileDragSource(in: $0) }.first
    }

    func interactionTarget<T: NSView>(_ type: T.Type, at point: NSPoint) -> T? {
        func find(in view: NSView) -> T? {
            let localPoint = view.convert(point, from: nil)
            guard !view.isHidden, view.visibleRect.contains(localPoint) else { return nil }
            // SwiftUI's AppKit hosts can report a visible rect wider than the represented view.
            if let target = view as? T, view.bounds.contains(localPoint) { return target }
            return view.subviews.reversed().lazy.compactMap { find(in: $0) }.first
        }
        return contentView.flatMap { find(in: $0) }
    }

    func table(at point: NSPoint, onHeader: (() -> Void)? = nil) -> NSTableView? {
        guard let contentView else { return nil }
        let location = contentView.superview?.convert(point, from: nil) ?? point
        var hit = contentView.hitTest(location)
        while let view = hit {
            if let table = view as? NSTableView { return table }
            if view is NSTableHeaderView {
                onHeader?()
                return nil
            }
            if view is NSScroller { return nil }
            if let scrollView = view as? NSScrollView,
               let table = scrollView.documentView as? NSTableView,
               scrollView.contentView.bounds.contains(scrollView.contentView.convert(point, from: nil)) {
                return table
            }
            hit = view.superview
        }
        return nil
    }
}
