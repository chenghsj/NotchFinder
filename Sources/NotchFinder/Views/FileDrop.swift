import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    @ViewBuilder
    func folderDrop(_ folder: URL?, browser: FileBrowser) -> some View {
        if let folder {
            fileDrop(.folder(folder), browser: browser)
        } else {
            self
        }
    }

    func fileDrop(_ destination: FileBrowser.DropDestination, browser: FileBrowser) -> some View {
        overlay(FileDropRegion(scope: .item(destination), browser: browser))
    }
}

struct FileDropRegion: NSViewRepresentable {
    enum Scope {
        case item(FileBrowser.DropDestination)
        case table
    }

    let scope: Scope
    let browser: FileBrowser

    func makeNSView(context: Context) -> Receiver {
        let view = Receiver()
        view.registerForDraggedTypes([.fileURL])
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Receiver, context: Context) {
        view.scope = scope
        view.browser = browser
    }

    static func urls(from board: NSPasteboard) -> [URL]? {
        guard let items = board.pasteboardItems, !items.isEmpty else { return nil }
        var urls: [URL] = []
        for item in items {
            guard let data = item.data(forType: .fileURL),
                  let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
            urls.append(url)
        }
        return urls
    }

    static func operation(for destination: FileBrowser.DropDestination, allowed: NSDragOperation,
                          optionDown: Bool, sameVolume: Bool) -> NSDragOperation {
        switch destination {
        case .trash:
            if allowed.contains(.delete) { return .delete }
            return allowed.contains(.move) ? .move : []
        case .folder:
            if !optionDown, sameVolume, allowed.contains(.move) { return .move }
            return allowed.contains(.copy) ? .copy : []
        }
    }

    final class Receiver: NSView {
        var scope: Scope = .table
        weak var browser: FileBrowser?
        private var sequence: Int?
        private var urls: [URL]?
        private var destination: FileBrowser.DropDestination?
        private var sameVolume = false
        private var highlight: NSRect? {
            didSet { if oldValue != highlight { needsDisplay = true } }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            if let highlight {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()
            }
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { reset() }
        override func draggingEnded(_ sender: any NSDraggingInfo) { reset() }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { reset() }
            let operation = update(sender)
            guard !operation.isEmpty, let browser, let destination, let urls else { return false }
            return browser.acceptFileDrop(into: destination, copies: operation == .copy) { $0(urls) }
        }

        private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard browser?.isUpdatingFiles == false, let target = target(at: sender.draggingLocation) else {
                highlight = nil
                return []
            }
            if sequence != sender.draggingSequenceNumber {
                sequence = sender.draggingSequenceNumber
                urls = FileDropRegion.urls(from: sender.draggingPasteboard)
                destination = nil
            }
            guard let urls else { highlight = nil; return [] }
            if destination != target.destination {
                destination = target.destination
                if case .folder(let folder) = target.destination {
                    let volume = try? folder.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeURLKey]).volume
                    sameVolume = volume != nil && urls.allSatisfy {
                        let parent = $0.deletingLastPathComponent().resolvingSymlinksInPath()
                        return (try? parent.resourceValues(forKeys: [.volumeURLKey]).volume) == volume
                    }
                }
            }
            let operation = FileDropRegion.operation(for: target.destination, allowed: sender.draggingSourceOperationMask,
                                                     optionDown: NSEvent.modifierFlags.contains(.option), sameVolume: sameVolume)
            highlight = operation.isEmpty ? nil : target.rect
            return operation
        }

        private func target(at point: NSPoint) -> (destination: FileBrowser.DropDestination, rect: NSRect)? {
            switch scope {
            case .item(let destination): return (destination, bounds)
            case .table:
                guard let window, let table = window.table(at: point),
                      let entry = window.fileDragSource(at: point, in: table)?.entry, entry.canExpand else { return nil }
                let row = table.row(at: table.convert(point, from: nil))
                return (.folder(entry.url), convert(table.rect(ofRow: row), from: table))
            }
        }

        private func reset() {
            sequence = nil
            urls = nil
            destination = nil
            highlight = nil
        }
    }
}

@MainActor
final class DropURLLoader {
    private var urls: [URL?]
    private var remaining: Int
    private let completion: @MainActor ([URL]) -> Void

    private init(count: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        urls = Array(repeating: nil, count: count)
        remaining = count
        self.completion = completion
    }

    static func load(_ providers: [NSItemProvider], as type: (NSItemProvider) -> UTType,
                     completion: @escaping @MainActor ([URL]) -> Void) {
        guard !providers.isEmpty else { completion([]); return }
        let loader = DropURLLoader(count: providers.count, completion: completion)
        for (index, provider) in providers.enumerated() {
            provider.loadDataRepresentation(forTypeIdentifier: type(provider).identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in loader.finish(url?.isFileURL == true ? url : nil, at: index) }
            }
        }
    }

    private func finish(_ url: URL?, at index: Int) {
        urls[index] = url
        remaining -= 1
        if remaining == 0 {
            let loaded = urls.compactMap { $0 }
            completion(loaded.count == urls.count ? loaded : [])
        }
    }
}
