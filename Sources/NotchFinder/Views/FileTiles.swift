import AppKit
import QuickLookThumbnailing
import SwiftUI

struct FileTiles: View {
    enum Layout { case grid, filmstrip }

    let browser: FileBrowser
    let entries: [FileEntry]
    let settings: NotchSettings
    let layout: Layout
    let releaseSearchFocus: () -> Void
    var onFileDragEnded: () -> Void = {}
    @State private var anchor: URL?

    private var interfaceSize: FileDisplaySize { settings.interfaceSize }
    private var filmstripSide: CGFloat { interfaceSize.row.icon + 16 }

    var body: some View {
        switch layout {
        case .grid: grid
        case .filmstrip: filmstrip
        }
    }

    private var grid: some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: interfaceSize.grid.width), spacing: 8)], spacing: 9) {
                    ForEach(entries) { entry in
                        tile(entry, side: interfaceSize.grid.icon, nameLines: 2)
                            .frame(maxWidth: .infinity)
                            .frame(height: interfaceSize.grid.height)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture {
                            browser.selection.removeAll()
                            anchor = nil
                        }
                }
            }
        }
    }

    private var filmstrip: some View {
        let selected = entries.first { browser.selection.contains($0.id) }?.id
        return ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(entries) { entry in
                        tile(entry, side: filmstripSide, nameLines: 1)
                            .frame(width: filmstripSide + 44)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: filmstripSide + interfaceSize.panelText + 32)
            .onChange(of: selected, initial: true) { _, item in
                if let item { scroll.scrollTo(item, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func tile(_ entry: FileEntry, side: CGFloat, nameLines: Int) -> some View {
        let selected = browser.selection.contains(entry.id)
        let button = Button { select(entry.id) } label: {
            VStack(spacing: 6) {
                if layout == .filmstrip && !entry.isFolder {
                    GalleryThumbnail(entry: entry, side: side, loadsFileIcon: browser.fileIconsEnabled)
                } else {
                    BrowserFileIcon(entry: entry, side: side, loadsFileIcon: browser.fileIconsEnabled)
                }
                Text(entry.name)
                    .font(settings.panelFont(size: interfaceSize.panelText))
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .lineLimit(nameLines)
            }
            .padding(4)
        }
        .buttonStyle(PanelButtonStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .simultaneousGesture(TapGesture(count: 2).onEnded { browser.openItems([entry.id]) })
        .contextMenu {
            FileCommands(browser: browser, items: selected ? browser.selection : [entry.id],
                         cleanupInstaller: settings.cleansDiskImageAfterInstall)
        }
        .help(entry.name)

        if layout == .filmstrip && selected && browser.selection.count > 1 {
            button.background(FileTileDragSource(files: {
                entries.filter { browser.selection.contains($0.id) }.map(\.url)
            }, didEnd: onFileDragEnded))
        } else {
            button.onDrag { NSItemProvider(object: entry.url as NSURL) }
        }
    }

    private func select(_ item: URL) {
        releaseSearchFocus()
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor,
           let first = entries.firstIndex(where: { $0.id == anchor }),
           let last = entries.firstIndex(where: { $0.id == item }) {
            let range = Set(entries[min(first, last)...max(first, last)].map(\.id))
            browser.selection = modifiers.contains(.command) ? browser.selection.union(range) : range
            return
        }
        if modifiers.contains(.command) {
            if browser.selection.contains(item) { browser.selection.remove(item) }
            else { browser.selection.insert(item) }
        } else {
            browser.selection = [item]
        }
        anchor = item
    }
}

private struct FileTileDragSource: NSViewRepresentable {
    let files: () -> [URL]
    let didEnd: () -> Void

    func makeNSView(context: Context) -> FileTileDragTarget { FileTileDragTarget() }

    func updateNSView(_ view: FileTileDragTarget, context: Context) {
        view.files = files
        view.didEnd = didEnd
    }
}

final class FileTileDragTarget: NSView, NSDraggingSource {
    var files: () -> [URL] = { [] }
    var didEnd: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func beginDrag(with event: NSEvent) -> Bool {
        guard let window, window === event.window else { return false }
        let pointer = convert(event.locationInWindow, from: nil)
        let iconFrame = NSRect(x: pointer.x - 16, y: pointer.y - 16, width: 32, height: 32)
        let items = files().map { file in
            let item = NSDraggingItem(pasteboardWriter: file as NSURL)
            item.setDraggingFrame(iconFrame, contents: NSWorkspace.shared.icon(forFile: file.path))
            return item
        }
        guard !items.isEmpty else { return false }
        beginDraggingSession(with: items, event: event, source: self).draggingFormation = .pile
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        didEnd()
    }
}

private struct GalleryThumbnail: View {
    let entry: FileEntry
    let side: CGFloat
    let loadsFileIcon: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        BrowserFileIcon(entry: entry, side: side, loadsFileIcon: loadsFileIcon, thumbnail: thumbnail)
            .task(id: entry) {
                thumbnail = nil
                let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: side, height: side),
                                                           scale: displayScale, representationTypes: .thumbnail)
                let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                if !Task.isCancelled { thumbnail = representation?.nsImage }
            }
    }
}
