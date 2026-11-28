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
        let base = interfaceSize.grid
        let iconSide = CGFloat(settings.gridIconSize)
        let tileWidth = base.width + (iconSide - base.icon)
        let tileHeight = base.height + (iconSide - base.icon)
        return GeometryReader { viewport in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 8)], spacing: 9) {
                    ForEach(entries) { entry in
                        tile(entry, side: iconSide, nameLines: 2)
                            .frame(maxWidth: .infinity)
                            .frame(height: tileHeight)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture {
                            browser.selectItems([])
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

    private func tile(_ entry: FileEntry, side: CGFloat, nameLines: Int) -> some View {
        let selected = browser.selection.contains(entry.id)
        return Button { select(entry.id) } label: {
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
        .folderDrop(entry.canExpand ? entry.url : nil, browser: browser)
        .background(FileDragSource(entry: entry, entries: entries, browser: browser,
                                   allowsMovingSelection: true, didEnd: onFileDragEnded,
                                   selectOnPress: { select(entry.id) }))
    }

    private func select(_ item: URL) {
        releaseSearchFocus()
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor,
           let first = entries.firstIndex(where: { $0.id == anchor }),
           let last = entries.firstIndex(where: { $0.id == item }) {
            let range = Set(entries[min(first, last)...max(first, last)].map(\.id))
            browser.selectItems(modifiers.contains(.command) ? browser.selection.union(range) : range)
            return
        }
        if modifiers.contains(.command) {
            browser.selectItems(browser.selection.symmetricDifference([item]))
        } else {
            browser.selectItems([item])
        }
        anchor = item
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
