import SwiftUI

struct FileColumns: View {
    let browser: FileBrowser
    let listing: FileListing
    let settings: NotchSettings
    let onFileDragEnded: () -> Void

    private var defaultColumnWidth: CGFloat { 164 + 8 * (settings.interfaceSize.panelText - FileDisplaySize.small.panelText) }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(listing.columns) { column in
                        let title = column.id.map(browser.name(for:)) ?? browser.title
                        ResizableFileColumn(title: title, defaultWidth: defaultColumnWidth,
                                            content: columnView(column).accessibilityLabel(title))
                            .id(column.id.map(FileBrowser.Destination.folder) ?? browser.destination)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            // Leave room for the panel's outer resize handle when scrolled to the last column.
            .padding(.trailing, 8)
            .onChange(of: browser.columnPath.last, initial: true) { _, folder in
                scroll.scrollTo(folder.map(FileBrowser.Destination.folder) ?? browser.destination, anchor: folder == nil ? .leading : .trailing)
            }
        }
    }

    private func columnView(_ column: FileListing.Column) -> some View {
        let selection = Binding(
            get: { column.selected(from: browser.selection) },
            set: { browser.selectColumnItems($0, in: column.id) }
        )
        return List(selection: selection) {
            ForEach(column.entries) { entry in
                row(entry)
                    .background(FileDragSource(entry: entry, entries: column.entries, browser: browser,
                                               didEnd: onFileDragEnded,
                                               selectOnPress: { browser.selectColumnItems([entry.id], in: column.id) }))
                    .tag(entry.id)
                    .itemProvider { NSItemProvider(object: entry.url as NSURL) }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowBackground(Color.accentColor.opacity(column.revealedFolder == entry.id ? 0.13 : 0))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ColumnClickTarget { browser.selectColumnItems([], in: column.id) })
        .contextMenu(forSelectionType: URL.self) { items in
            FileCommands(browser: browser, items: items, cleanupInstaller: settings.cleansDiskImageAfterInstall)
        } primaryAction: { items in
            browser.openItems(items)
        }
        .overlay {
            if column.id != nil && column.entries.isEmpty {
                if column.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(L10n.text("載入中…"))
                } else {
                    Text(L10n.text("沒有項目"))
                        .font(settings.panelFont(size: settings.interfaceSize.panelText))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func row(_ entry: FileEntry) -> some View {
        let size = settings.interfaceSize
        return HStack(spacing: 6) {
            BrowserFileIcon(entry: entry, side: size.row.icon, loadsFileIcon: browser.fileIconsEnabled)
            Text(entry.name)
                .font(settings.panelFont(size: size.panelText))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.name)
            Spacer(minLength: 0)
            if entry.canExpand {
                Image(systemName: "chevron.forward")
                    .font(.system(size: max(8, size.panelIcon - 5), weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: size.row.height)
        .folderDrop(entry.canExpand ? entry.url : nil, browser: browser)
    }
}

private struct ResizableFileColumn<Content: View>: View {
    let title: String
    let defaultWidth: CGFloat
    let content: Content

    @State private var widthOverride: CGFloat?
    @GestureState private var dragOffset: CGFloat = 0

    private var baseWidth: CGFloat { widthOverride ?? defaultWidth }
    private var width: CGFloat { clampedWidth(baseWidth + dragOffset) }

    var body: some View {
        HStack(spacing: 0) {
            content.frame(width: width)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .frame(width: 7)
                .contentShape(.rect)
                .columnResizePointer()
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($dragOffset) { drag, offset, _ in offset = drag.translation.width }
                        .onEnded { drag in widthOverride = clampedWidth(baseWidth + drag.translation.width) }
                )
                .accessibilityElement()
                .accessibilityLabel(L10n.text("「%@」欄寬", title))
                .accessibilityValue(L10n.text("%@ 點", String(Int(width.rounded()))))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: widthOverride = clampedWidth(width + 10)
                    case .decrement: widthOverride = clampedWidth(width - 10)
                    @unknown default: break
                    }
                }
        }
    }

    private func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(480, max(112, width))
    }
}

struct ColumnClickTarget: NSViewRepresentable {
    let clearSelection: () -> Void

    func makeNSView(context: Context) -> Target { Target() }

    func updateNSView(_ view: Target, context: Context) {
        view.clearSelection = clearSelection
    }

    final class Target: NSView {
        var clearSelection: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
