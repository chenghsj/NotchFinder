import AppKit
import SwiftUI

struct FileList: View {
    @Bindable var browser: FileBrowser
    let settings: NotchSettings
    let listing: FileListing
    let releaseSearchFocus: () -> Void
    let onFileDragEnded: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelStyle) private var panelStyle

    private var stripeColor: NSColor? {
        listing.groups == nil ? nil : panelStyle.listStripeColor(for: colorScheme)
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            listContent.onDragSessionUpdated { session in
                if case .ended = session.phase { onFileDragEnded() }
            }
        } else {
            listContent
        }
    }

    private var listContent: some View {
        contents
            .id(browser.destination)
            .onChange(of: settings.fileSort) { _, _ in browser.setTableSortOrder([], for: settings) }
            .onChange(of: browser.groupsFilesByAddedDate(for: settings)) { _, _ in browser.setTableSortOrder([], for: settings) }
            .onChange(of: listing.displayMode) { _, _ in
                browser.selection.formIntersection(listing.visibleIDs)
            }
            .onChange(of: browser.selection) { _, selection in
                if !selection.isEmpty { releaseSearchFocus() }
            }
            .overlay {
                if listing.entries.isEmpty { emptyState.allowsHitTesting(false) }
            }
    }

    @ViewBuilder
    private var contents: some View {
        switch listing.displayMode {
        case .icons:
            FileTiles(browser: browser, entries: listing.entries, settings: settings,
                      layout: .grid, releaseSearchFocus: releaseSearchFocus)
        case .list:
            withFileActions(detailTable)
        case .columns:
            FileColumns(browser: browser, listing: listing, settings: settings)
        case .gallery:
            FileGallery(browser: browser, entries: listing.entries, settings: settings,
                        releaseSearchFocus: releaseSearchFocus, onFileDragEnded: onFileDragEnded)
        }
    }

    private func fileRow(_ entry: FileEntry, stripe: NSColor? = nil, fillsTableWidth: Bool = false) -> some View {
        let depth = browser.showsRecentItems ? 0 : max(0, entry.url.pathComponents.count - browser.directory.pathComponents.count - 1)
        return FileRow(entry: entry, depth: depth, interfaceSize: settings.interfaceSize,
                       loadsFileIcon: browser.fileIconsEnabled, fontDesign: settings.appearance.fontStyle.design,
                       expanded: browser.isExpandedInList(entry.url),
                       toggleExpansion: { browser.toggleExpansion(of: entry) })
            .background {
                if let stripe { NativeFileRowBackground(stripe: stripe) }
                NativeFileListLayout(fillsTableWidth: fillsTableWidth)
            }
            .listRowSeparator(listing.groups == nil ? .automatic : .hidden)
            .tag(entry.id)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(settings.panelFont(size: max(10, settings.interfaceSize.panelText - 1), weight: .medium))
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var detailTable: some View {
        let grouped = listing.groups != nil
        let stripe = stripeColor
        let filtersLargeFolder = browser.entries.count >= 10_000 &&
            !browser.filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let date: (title: String, key: KeyPath<FileEntry, Date>, showsTime: Bool) = if browser.showsRecentItems {
            (L10n.text("上次使用日期"), \.lastUsed, true)
        } else if grouped {
            (L10n.text("加入日期"), \.added, true)
        } else {
            (L10n.text("修改日期"), \.modified, false)
        }
        let table = Table(of: FileEntry.self, selection: $browser.selection, sortOrder: tableSort) {
            TableColumn(L10n.text("名稱"), value: \.name) { entry in
                fileRow(entry, stripe: stripe, fillsTableWidth: !grouped)
            }
            .width(min: 130, ideal: 180)
            TableColumn(L10n.text("大小"), value: \.fileSize) { entry in
                Text(entry.fileSize < 0 ? "—" : ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))
                    .monospacedDigit()
                    .font(settings.panelFont(size: settings.interfaceSize.panelText))
                    .foregroundStyle(grouped ? Color.secondary : Color.primary)
            }
            .width(min: 50, ideal: 60, max: 88)
            TableColumn(L10n.text("種類"), value: \.kind) { entry in
                Text(entry.kind).lineLimit(1)
                    .font(settings.panelFont(size: settings.interfaceSize.panelText))
                    .foregroundStyle(grouped ? Color.secondary : Color.primary)
            }
            .width(min: 62, ideal: 76, max: 110)
            TableColumn(date.title, value: date.key) { entry in
                let value = entry[keyPath: date.key]
                Text(value == .distantPast ? "—" : value.formatted(date: .numeric, time: date.showsTime ? .shortened : .omitted))
                    .lineLimit(1)
                    .font(settings.panelFont(size: settings.interfaceSize.panelText))
                    .foregroundStyle(grouped ? Color.secondary : Color.primary)
            }
            .width(min: 72, ideal: date.showsTime ? 110 : 92, max: date.showsTime ? 160 : 130)
        } rows: {
            if let groups = listing.groups {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries, content: tableRow)
                    } header: {
                        groupHeader(group.title)
                    }
                }
            } else {
                ForEach(listing.entries, content: tableRow)
            }
        }
        .alternatingRowBackgrounds(grouped && stripe == nil ? .enabled : .disabled)
        .scrollContentBackground(.hidden)
        // Recreate the outline when a large filter starts or clears to avoid diffing thousands of rows.
        .id(filtersLargeFolder)
        if grouped {
            table.tableStyle(.inset)
        } else {
            table.tableStyle(.bordered(alternatesRowBackgrounds: false))
        }
    }

    private func tableRow(_ entry: FileEntry) -> some TableRowContent<FileEntry> {
        TableRow(entry)
            .itemProvider { NSItemProvider(object: entry.url as NSURL) }
    }

    private func withFileActions(_ content: some View) -> some View {
        let size: ControlSize = settings.interfaceSize == .small ? .regular : .large
        return content.controlSize(size)
            .scrollIndicators(.never, axes: .horizontal)
            .contextMenu(forSelectionType: URL.self) { items in
                FileCommands(browser: browser, items: items, cleanupInstaller: settings.cleansDiskImageAfterInstall)
            } primaryAction: { items in
                browser.openItems(items)
            }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = browser.readError {
            message(L10n.text(browser.showsRecentItems ? "無法讀取最近項目" : "無法讀取資料夾"),
                    detail: error, symbol: "exclamationmark.circle")
        } else if browser.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.text(browser.showsRecentItems ? "正在讀取最近項目" : "正在讀取資料夾"))
        } else if browser.entries.isEmpty {
            message(L10n.text(browser.showsRecentItems ? "沒有最近使用的檔案" : "這個資料夾是空的"),
                    symbol: browser.showsRecentItems ? "clock" : "folder")
        } else {
            message(L10n.text("找不到符合的項目"), symbol: "magnifyingglass")
        }
    }

    private var tableSort: Binding<[KeyPathComparator<FileEntry>]> {
        Binding(get: { browser.tableSortOrder(for: settings) },
                set: { browser.setTableSortOrder($0, for: settings) })
    }

    private func message(_ title: String, detail: String? = nil, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: settings.interfaceSize.panelIcon + 6, weight: .light))
                .accessibilityHidden(true)
            Text(title)
                .font(settings.panelFont(size: settings.interfaceSize.panelText, weight: .medium))
            if let detail {
                Text(detail)
                    .font(settings.panelFont(size: settings.interfaceSize.panelText - 1))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NativeFileListLayout: NSViewRepresentable {
    let fillsTableWidth: Bool

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor(frame: .zero)
        view.fillsTableWidth = fillsTableWidth
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.fillsTableWidth = fillsTableWidth
        view.updateListLayout()
    }

    final class Anchor: NSView {
        var fillsTableWidth = false
        private var updatePending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateListLayout()
        }

        override func layout() {
            super.layout()
            updateListLayout()
        }

        func updateListLayout() {
            guard !updatePending, window != nil, let scroll = enclosingScrollView,
                  let table = scroll.documentView as? NSTableView,
                  needsScrollerUpdate(scroll, table: table) || needsWidthUpdate(table) else { return }
            updatePending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                updatePending = false
                guard window != nil, let scroll = enclosingScrollView,
                      let table = scroll.documentView as? NSTableView else { return }
                if needsScrollerUpdate(scroll, table: table) {
                    // Keep the native vertical gutter in place when rows begin overflowing.
                    scroll.autohidesScrollers = false
                    scroll.hasVerticalScroller = true
                    if table.headerView != nil, !(table.cornerView is HeaderCorner) {
                        table.cornerView = HeaderCorner()
                    }
                    scroll.tile()
                }
                guard needsWidthUpdate(table) else { return }
                table.sizeLastColumnToFit()
            }
        }

        private func needsScrollerUpdate(_ scroll: NSScrollView, table: NSTableView) -> Bool {
            scroll.scrollerStyle == .legacy && (
                scroll.autohidesScrollers || !scroll.hasVerticalScroller
                    || (table.headerView != nil && !(table.cornerView is HeaderCorner))
            )
        }

        private func needsWidthUpdate(_ table: NSTableView) -> Bool {
            guard fillsTableWidth, table.numberOfColumns > 0, table.visibleRect.width > 0 else { return false }
            let right = table.rect(ofColumn: table.numberOfColumns - 1).maxX
            return right < table.visibleRect.maxX - 1
        }
    }

    private final class HeaderCorner: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            let pixel = 1 / (window?.backingScaleFactor ?? 1)
            NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: pixel).fill()
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let depth: Int
    let interfaceSize: FileDisplaySize
    let loadsFileIcon: Bool
    let fontDesign: Font.Design
    let expanded: Bool
    let toggleExpansion: () -> Void

    private var rowHeight: CGFloat { interfaceSize.row.height }
    private var disclosureWidth: CGFloat { max(14, interfaceSize.panelIcon + 1) }

    var body: some View {
        HStack(spacing: 3) {
            if entry.canExpand {
                let action = expanded ? L10n.text("收合「%@」", String(describing: entry.name)) : L10n.text("展開「%@」", String(describing: entry.name))
                Button(action: toggleExpansion) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: max(8, interfaceSize.panelIcon - 4), weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: disclosureWidth, height: rowHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action)
                .help(action)
            } else {
                Color.clear.frame(width: disclosureWidth, height: 1).accessibilityHidden(true)
            }

            HStack(spacing: 9) {
                BrowserFileIcon(entry: entry, side: interfaceSize.row.icon, loadsFileIcon: loadsFileIcon)
                Text(entry.name)
                    .font(.system(size: interfaceSize.panelText, design: fontDesign))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(entry.name)
        }
        .frame(minHeight: rowHeight)
        .padding(.leading, CGFloat(depth) * disclosureWidth)
    }
}

struct BrowserFileIcon: View {
    let entry: FileEntry
    let side: CGFloat
    let loadsFileIcon: Bool
    var thumbnail: NSImage? = nil
    @Environment(\.quickLookSources) private var quickLookSources
    @State private var fileIcon: NSImage?

    var body: some View {
        Group {
            if let image = thumbnail ?? fileIcon {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: entry.isFolder ? "folder.fill" : "doc")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
            }
        }
        .frame(width: side, height: side)
        .background {
            if let quickLookSources {
                QuickLookSource(url: entry.url, sources: quickLookSources)
                    .frame(width: side, height: side)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
        .task(id: loadsFileIcon ? entry.url : nil) {
            guard loadsFileIcon, fileIcon == nil else { return }
            fileIcon = NSWorkspace.shared.icon(forFile: entry.url.path)
        }
    }
}
