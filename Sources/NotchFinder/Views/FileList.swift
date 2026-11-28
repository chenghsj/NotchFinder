import AppKit
import SwiftUI

struct FileList: View {
    // Offset the cell padding SwiftUI adds around its native table content.
    private static let cellVerticalPadding: CGFloat = -3

    let browser: FileBrowser
    let settings: NotchSettings
    let listing: FileListing
    let releaseSearchFocus: () -> Void
    let onFileDragEnded: () -> Void
    @AppStorage var columnCustomization: TableColumnCustomization<FileEntry>
    @AppStorage(NotchSettings.sharedFileListColumnsKey) private var sharedColumns = TableColumnCustomization<FileEntry>()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelStyle) private var panelStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expansionDuration: TimeInterval? {
        guard !reduceMotion, settings.animation != .off else { return nil }
        return 0.20 / settings.animation.rate
    }

    private var collapseDuration: TimeInterval? { expansionDuration.map { $0 * 0.65 } }

    private var stripeColor: NSColor? {
        panelStyle.listStripeColor(for: colorScheme)
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
            .overlay {
                if listing.entries.isEmpty { emptyState.allowsHitTesting(false) }
            }
    }

    @ViewBuilder
    private var contents: some View {
        switch listing.displayMode {
        case .icons:
            FileTiles(browser: browser, entries: listing.entries, settings: settings,
                      layout: .grid, releaseSearchFocus: releaseSearchFocus, onFileDragEnded: onFileDragEnded)
        case .list:
            withFileActions(detailTable)
        case .columns:
            FileColumns(browser: browser, listing: listing, settings: settings, onFileDragEnded: onFileDragEnded)
        case .gallery:
            FileGallery(browser: browser, entries: listing.entries, settings: settings,
                        releaseSearchFocus: releaseSearchFocus, onFileDragEnded: onFileDragEnded)
        }
    }

    private func fileRow(_ entry: FileEntry, stripe: NSColor? = nil) -> some View {
        let destination = browser.destination
        let expanded = browser.isExpandedInList(entry.url)
        return FileRow(entry: entry, depth: listing.depth(of: entry.id), interfaceSize: settings.interfaceSize,
                       loadsFileIcon: browser.fileIconsEnabled, fontDesign: settings.appearance.fontStyle.design,
                       canExpand: entry.canExpand,
                       expanded: expanded,
                       hasChildren: browser.expandedFolders[entry.id]?.isEmpty == false,
                       isLoadingChildren: expanded && browser.isLoadingContents(of: entry.id),
                       expansionDuration: expansionDuration,
                       collapseDuration: collapseDuration,
                       childRowCount: { min($0, listing.descendantCount(of: entry.id)) },
                       setExpanded: { expanded, animateLayout in
                           guard browser.destination == destination, browser.isExpandedInList(entry.id) != expanded else { return }
                           browser.toggleExpansion(of: entry, animateLayout: animateLayout)
                       })
            .background {
                if let stripe { NativeFileRowBackground(stripe: stripe) }
                FileDragSource(entry: entry, entries: listing.entries, browser: browser, didEnd: onFileDragEnded,
                               selectOnPress: { browser.selectItems([entry.id]) })
            }
            .padding(.vertical, Self.cellVerticalPadding)
            .listRowSeparator(.hidden)
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
        let selection = Binding(get: { browser.selection }, set: browser.selectItems)
        let destination = browser.destination
        // AppKit also updates column widths when the viewport resizes. Keep those defaults shared
        // until the user interacts with this destination's header.
        let columns = Binding {
            settings.hasCustomFileListColumns(for: destination) ? columnCustomization : sharedColumns
        } set: { value in
            if settings.hasCustomFileListColumns(for: destination) { columnCustomization = value }
            else { sharedColumns = value }
        }
        Table(of: FileEntry.self, selection: selection, sortOrder: tableSort, columnCustomization: columns) {
            TableColumn(L10n.text("名稱"), value: \.name) { entry in
                fileRow(entry, stripe: stripe)
            }
            .width(min: 130, ideal: 180)
            .customizationID("name")
            TableColumn(L10n.text("大小"), value: \.fileSize) { entry in
                Text(entry.fileSize < 0 ? "—" : ByteCountFormatter.string(fromByteCount: entry.fileSize, countStyle: .file))
                    .monospacedDigit()
                    .font(settings.panelFont(size: settings.interfaceSize.panelText))
                    .foregroundStyle(grouped ? Color.secondary : Color.primary)
                    .padding(.vertical, Self.cellVerticalPadding)
            }
            .width(min: 50, ideal: 60, max: 88)
            .customizationID("size")
            TableColumn(L10n.text("種類"), value: \.kind) { entry in
                Text(entry.kind).lineLimit(1)
                    .font(settings.panelFont(size: settings.interfaceSize.panelText))
                    .foregroundStyle(grouped ? Color.secondary : Color.primary)
                    .padding(.vertical, Self.cellVerticalPadding)
            }
            .width(min: 62, ideal: 76, max: 110)
            .customizationID("kind")
            TableColumn(date.title, value: date.key) { entry in
                let value = entry[keyPath: date.key]
                Text(value == .distantPast ? "—" : value.formatted(date: .numeric, time: date.showsTime ? .shortened : .omitted))
                    .lineLimit(1)
                    .font(settings.panelFont(size: settings.interfaceSize.panelText))
                    .foregroundStyle(grouped ? Color.secondary : Color.primary)
                    .padding(.vertical, Self.cellVerticalPadding)
            }
            // The trailing column absorbs spare width so restoring the table keeps its dividers in place.
            .width(min: 72, ideal: 110)
            .customizationID("date")
        } rows: {
            if let groups = listing.groups {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { tableRow($0) }
                    } header: {
                        groupHeader(group.title)
                    }
                }
            } else {
                ForEach(listing.entries) { tableRow($0) }
            }
        }
        // Match the native table's estimated row height to its measured cell height.
        .environment(\.defaultMinListRowHeight, settings.interfaceSize.panelIcon + 5)
        .tableStyle(.inset)
        .alternatingRowBackgrounds(stripe == nil ? .enabled : .disabled)
        .scrollContentBackground(.hidden)
        .animation(collapseDuration.map { .easeInOut(duration: $0) }, value: browser.inlineCollapseChange)
        // Recreate the outline when a large filter starts or clears to avoid diffing thousands of rows.
        .id(filtersLargeFolder)
        // Reserve the same scrollbar space even while the destination has no rows.
        .overlay(NativeFileListLayout(fillsTableWidth: !grouped))
        .overlay(FileDropRegion(scope: .table, browser: browser))
    }

    private func tableRow(_ entry: FileEntry) -> some TableRowContent<FileEntry> {
        TableRow(entry).itemProvider { NSItemProvider(object: entry.url as NSURL) }
    }

    private func withFileActions(_ content: some View) -> some View {
        content.controlSize(.small)
            .scrollIndicators(.never, axes: .horizontal)
            .contextMenu(forSelectionType: URL.self) { items in
                FileCommands(browser: browser, items: items, cleanupInstaller: settings.cleansDiskImageAfterInstall)
            } primaryAction: { items in
                if let panel = NSApp.currentEvent?.window as? NotchPanel,
                   panel.isReselectingDismissedFolder(items) { return }
                browser.openItems(items)
            }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = browser.readError {
            let title = switch browser.destination {
            case .folder: "無法讀取資料夾"
            case .recentItems: "無法讀取最近項目"
            case .tag: "無法讀取標籤結果"
            }
            message(L10n.text(title), detail: error, symbol: "exclamationmark.circle")
        } else if browser.isLoading {
            let title = switch browser.destination {
            case .folder: "正在讀取資料夾"
            case .recentItems: "正在讀取最近項目"
            case .tag: "正在讀取…"
            }
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.text(title))
        } else if browser.entries.isEmpty {
            switch browser.destination {
            case .folder:
                message(L10n.text("這個資料夾是空的"), symbol: "folder")
            case .recentItems:
                message(L10n.text("沒有最近使用的檔案"), symbol: "clock")
            case .tag:
                message(L10n.text("找不到符合的項目"), symbol: "tag")
            }
        } else {
            message(L10n.text("找不到符合的項目"), symbol: "magnifyingglass")
        }
    }

    private var tableSort: Binding<[KeyPathComparator<FileEntry>]> {
        Binding(get: { browser.tableSortOrder }, set: browser.setTableSortOrder)
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
            guard !updatePending, window != nil else { return }
            updatePending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                updatePending = false
                guard let window, !bounds.isEmpty else { return }
                let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
                guard let table = window.table(at: center),
                      let scroll = table.enclosingScrollView else { return }
                if needsScrollerUpdate(scroll, table: table) {
                    // Keep the native vertical gutter in place when rows begin overflowing.
                    scroll.autohidesScrollers = false
                    scroll.hasVerticalScroller = true
                    if table.headerView != nil, !(table.cornerView is HeaderCorner) {
                        table.cornerView = HeaderCorner()
                    }
                    scroll.tile()
                }
                guard fillsTableWidth, table.numberOfColumns > 0, table.visibleRect.width > 0 else { return }
                let right = table.rect(ofColumn: table.numberOfColumns - 1).maxX
                if right < table.visibleRect.maxX - 1 {
                    table.sizeLastColumnToFit()
                }
            }
        }

        private func needsScrollerUpdate(_ scroll: NSScrollView, table: NSTableView) -> Bool {
            scroll.scrollerStyle == .legacy && (
                scroll.autohidesScrollers || !scroll.hasVerticalScroller
                    || (table.headerView != nil && !(table.cornerView is HeaderCorner))
            )
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
    let canExpand: Bool
    let expanded: Bool
    let hasChildren: Bool
    let isLoadingChildren: Bool
    let expansionDuration: TimeInterval?
    let collapseDuration: TimeInterval?
    let childRowCount: (Int) -> Int
    let setExpanded: @MainActor @Sendable (_ expanded: Bool, _ animateLayout: Bool) -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.panelStyle) private var panelStyle
    @State private var motion = FileDisclosureHitArea.Motion()

    private var rowHeight: CGFloat { interfaceSize.panelIcon + 3 }
    private var disclosureWidth: CGFloat { interfaceSize.panelIcon - 3 }
    private var disclosureDuration: TimeInterval? { expanded ? expansionDuration : collapseDuration }

    var body: some View {
        HStack(spacing: 2) {
            if canExpand {
                let action = expanded ? L10n.text("收合「%@」", String(describing: entry.name)) : L10n.text("展開「%@」", String(describing: entry.name))
                Button {
                    motion.cancel()
                    if expanded, let collapseDuration {
                        motion.closeRows(duration: collapseDuration, background: NSColor(panelStyle.contentColor),
                                         childCount: childRowCount) { animateLayout in setExpanded(false, animateLayout) }
                        return
                    }
                    if !expanded, expansionDuration != nil { motion.prepareToOpen(background: NSColor(panelStyle.contentColor)) }
                    setExpanded(!expanded, true)
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: disclosureWidth - 4, weight: .medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? (layoutDirection == .leftToRight ? 90 : -90) : 0))
                        .animation(disclosureDuration.map { .easeInOut(duration: $0) }, value: expanded)
                        .frame(width: disclosureWidth, height: rowHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action)
                .help(action)
                .background(FileDisclosureHitArea(motion: motion, folder: entry.id, expanded: expanded,
                                                  hasChildren: hasChildren, isLoadingChildren: isLoadingChildren,
                                                  duration: expansionDuration,
                                                  background: NSColor(panelStyle.contentColor), childCount: childRowCount))
            } else {
                Color.clear.frame(width: disclosureWidth, height: 1).accessibilityHidden(true)
            }

            HStack(spacing: 5) {
                BrowserFileIcon(entry: entry, side: interfaceSize.panelIcon + 1, loadsFileIcon: loadsFileIcon)
                Text(entry.name)
                    .font(.system(size: interfaceSize.panelText, design: fontDesign))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(entry.name)
        }
        .frame(minHeight: rowHeight)
        .padding(.leading, CGFloat(depth) * (disclosureWidth + 2))
    }
}

struct FileDisclosureHitArea: NSViewRepresentable {
    let motion: Motion
    let folder: URL
    let expanded: Bool
    let hasChildren: Bool
    let isLoadingChildren: Bool
    let duration: TimeInterval?
    let background: NSColor
    let childCount: (Int) -> Int

    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ view: Target, context: Context) {
        motion.anchor = view
        if let duration, expanded, hasChildren {
            motion.openWhenRowsAreReady(folder, duration: duration, background: background, childCount: childCount)
        } else if duration == nil {
            motion.cancel()
        } else if !expanded || !isLoadingChildren {
            motion.discardPendingOpen()
        }
    }

    final class Target: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Motion {
        typealias CloseAction = @MainActor @Sendable (_ animateLayout: Bool) -> Void

        private enum Direction {
            case open(URL)
            case close(CloseAction)
        }

        private struct FollowingRows {
            let rows: NSImageView
            let frame: NSRect
        }

        weak var anchor: Target?
        private weak var snapshot: Snapshot?
        private var pendingOpen = false
        private var openingFollowers: FollowingRows?
        private var openTask: Task<Void, Never>?

        func prepareToOpen(background: NSColor) {
            pendingOpen = true
            guard let anchor, let scroll = anchor.enclosingScrollView,
                  let table = scroll.documentView as? NSTableView else { return }
            let parent = table.row(for: anchor)
            guard parent >= 0, parent + 1 < table.numberOfRows else { return }
            let viewport = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let bounds = viewportBelow(table.rect(ofRow: parent).maxY, in: viewport)
            guard !bounds.isEmpty, let rows = capturedRows(in: table, bounds: bounds, background: background) else { return }
            openingFollowers = FollowingRows(rows: rows, frame: table.convert(bounds, to: scroll))
        }

        func discardPendingOpen() {
            pendingOpen = false
            openingFollowers = nil
            openTask?.cancel()
            openTask = nil
        }

        func cancel() {
            discardPendingOpen()
            snapshot?.removeFromSuperview()
        }

        func closeRows(duration: TimeInterval, background: NSColor, childCount: (Int) -> Int,
                       completion: @escaping CloseAction) {
            if !animateRows(.close(completion), duration: duration, background: background, childCount: childCount) {
                completion(true)
            }
        }

        func openWhenRowsAreReady(_ folder: URL, duration: TimeInterval, background: NSColor,
                                  childCount: @escaping (Int) -> Int) {
            guard pendingOpen else { return }
            pendingOpen = false
            if animateRows(.open(folder), duration: duration, background: background, childCount: childCount) { return }
            // SwiftUI can update the disclosure before it installs the new table rows.
            openTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.openTask = nil
                if !self.animateRows(.open(folder), duration: duration, background: background, childCount: childCount) {
                    self.openingFollowers = nil
                }
            }
        }

        @discardableResult
        private func animateRows(_ direction: Direction, duration: TimeInterval, background: NSColor,
                                 childCount: (Int) -> Int) -> Bool {
            guard let anchor, let scroll = anchor.enclosingScrollView,
                  let table = scroll.documentView as? NSTableView, table.window?.isVisible == true else { return false }
            let row = table.row(for: anchor)
            let viewport = table.convert(scroll.contentView.bounds, from: scroll.contentView)
            let visibleRows = table.rows(in: viewport)
            guard row >= 0, visibleRows.length > 0 else { return false }
            let first = row + 1
            let visibleCapacity = NSMaxRange(visibleRows) - first
            let count = childCount(visibleCapacity)
            guard count > 0 else { return false }
            let last = row + count
            let opening: Bool
            switch direction {
            case .open(let folder):
                guard let firstRow = table.rowView(atRow: first, makeIfNecessary: false),
                      containsChild(of: folder, in: firstRow) else { return false }
                opening = true
            case .close:
                opening = false
            }
            var childBounds = table.rect(ofRow: first).union(table.rect(ofRow: last))
            if opening {
                // An interrupted collapse can leave the inserted rows temporarily compressed.
                let folderRow = table.rect(ofRow: row)
                childBounds.origin.y = folderRow.maxY
                childBounds.size.height = max(childBounds.height, folderRow.height * CGFloat(count))
            }
            let bounds = childBounds.intersection(viewport)
            guard !bounds.isEmpty else { return false }
            let affectedFrame = table.convert(viewportBelow(bounds.minY, in: viewport), to: scroll)
            let followingRows = opening && openingFollowers?.frame.integral == affectedFrame.integral ? openingFollowers?.rows : nil
            if opening { openingFollowers = nil }
            let snapshot = Snapshot(frame: opening && followingRows == nil ? table.convert(bounds, to: scroll) : affectedFrame)
            snapshot.setAccessibilityElement(false)
            snapshot.wantsLayer = true
            snapshot.layer?.masksToBounds = true
            table.effectiveAppearance.performAsCurrentDrawingAppearance {
                snapshot.layer?.backgroundColor = background.cgColor
            }
            scroll.addSubview(snapshot, positioned: .above, relativeTo: scroll.contentView)
            self.snapshot = snapshot

            switch direction {
            case .open:
                // Hold the old rows in place until the inserted cells have been drawn.
                if let followingRows { snapshot.addSubview(followingRows) }
                snapshot.afterDrawingRows { [weak self, weak table, weak snapshot] in
                    guard let snapshot else { return }
                    guard let self, let table, table.window?.isVisible == true,
                          let rows = self.capturedRows(in: table, bounds: bounds, background: background) else {
                        snapshot.removeFromSuperview()
                        return
                    }
                    rows.frame = table.convert(bounds, to: snapshot)
                    self.slide(rows, in: snapshot, from: bounds.height, duration: duration, alongside: followingRows)
                }
            case .close(let completion):
                beginCollapse(in: snapshot, table: table, bounds: bounds, viewport: viewport,
                              duration: duration, background: background, completion: completion)
            }
            return true
        }

        private func beginCollapse(in snapshot: Snapshot, table: NSTableView, bounds: NSRect, viewport: NSRect,
                                   duration: TimeInterval, background: NSColor, completion: CloseAction) {
            guard let children = capturedRows(in: table, bounds: bounds, background: background) else {
                snapshot.removeFromSuperview()
                completion(true)
                return
            }
            let followingBounds = viewportBelow(bounds.maxY, in: viewport)
            if !followingBounds.isEmpty,
               let followingRows = capturedRows(in: table, bounds: followingBounds, background: background) {
                followingRows.frame = table.convert(followingBounds, to: snapshot)
                snapshot.addSubview(followingRows)
            }
            children.frame = table.convert(bounds, to: snapshot)
            snapshot.addSubview(children)
            let originalRowCount = table.numberOfRows
            // Keep the expanded rows visible while SwiftUI lays out the collapsed list.
            completion(false)
            snapshot.afterDrawingRows(when: { [weak table] in
                (table?.numberOfRows ?? 0) < originalRowCount
            }) { [weak self, weak table, weak snapshot] in
                guard let snapshot else { return }
                guard let self, let table, table.numberOfRows < originalRowCount else {
                    snapshot.removeFromSuperview()
                    return
                }
                self.animateCollapse(in: snapshot, table: table, children: children,
                                     duration: duration, background: background)
            }
        }

        private func animateCollapse(in snapshot: Snapshot, table: NSTableView, children: NSImageView,
                                     duration: TimeInterval, background: NSColor) {
            snapshot.afterDrawingRows(waitingFor: 1) { [weak self, weak snapshot, weak table] in
                guard let snapshot else { return }
                guard let self, let table, let anchor = self.anchor, let scroll = table.enclosingScrollView else {
                    snapshot.removeFromSuperview()
                    return
                }
                let parent = table.row(for: anchor)
                guard parent >= 0 else {
                    snapshot.removeFromSuperview()
                    return
                }
                let viewport = table.convert(scroll.contentView.bounds, from: scroll.contentView)
                let bounds = self.viewportBelow(table.rect(ofRow: parent).maxY, in: viewport)
                guard !bounds.isEmpty, let rows = self.capturedRows(in: table, bounds: bounds, background: background) else {
                    snapshot.removeFromSuperview()
                    return
                }
                snapshot.frame = table.convert(bounds, to: scroll)
                let height = children.frame.height
                children.setFrameOrigin(NSPoint(x: children.frame.minX, y: snapshot.bounds.maxY - height))
                for view in snapshot.subviews where view !== children { view.removeFromSuperview() }
                self.slide(rows, in: snapshot, from: -height, duration: duration, timing: .easeOut, alongside: children)
            }
        }

        private func viewportBelow(_ y: CGFloat, in viewport: NSRect) -> NSRect {
            let start = max(viewport.minY, y)
            return NSRect(x: viewport.minX, y: start, width: viewport.width, height: max(0, viewport.maxY - start))
        }

        private func capturedRows(in table: NSTableView, bounds: NSRect, background: NSColor) -> NSImageView? {
            guard let bitmap = table.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            table.cacheDisplay(in: bounds, to: bitmap)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(bitmap)
            let rows = NSImageView(frame: NSRect(origin: .zero, size: bounds.size))
            rows.image = image
            rows.imageScaling = .scaleAxesIndependently
            rows.setAccessibilityElement(false)
            rows.wantsLayer = true
            table.effectiveAppearance.performAsCurrentDrawingAppearance {
                rows.layer?.backgroundColor = background.cgColor
            }
            return rows
        }

        private func slide(_ rows: NSImageView, in snapshot: Snapshot, from offset: CGFloat, duration: TimeInterval,
                           timing: CAMediaTimingFunctionName = .easeInEaseOut, alongside visibleRows: NSImageView? = nil) {
            let destination = rows.frame.origin
            rows.setFrameOrigin(NSPoint(x: destination.x, y: destination.y + offset))
            snapshot.addSubview(rows)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: timing)
                rows.animator().setFrameOrigin(destination)
                if let visibleRows {
                    let origin = visibleRows.frame.origin
                    visibleRows.animator().setFrameOrigin(NSPoint(x: origin.x, y: origin.y - offset))
                }
            } completionHandler: { [weak snapshot] in
                Task { @MainActor in snapshot?.removeFromSuperview() }
            }
        }

        private func containsChild(of folder: URL, in view: NSView) -> Bool {
            if let target = view as? FileDragTarget, let entry = target.entry {
                return entry.url.deletingLastPathComponent().path == folder.path
            }
            return view.subviews.contains { containsChild(of: folder, in: $0) }
        }
    }

    private final class Snapshot: NSView {
        private var tick: CADisplayLink?
        private var refreshesRemaining = 0
        private var rowsAreReady: (() -> Bool)?
        private var onRowsDrawn: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func afterDrawingRows(waitingFor frames: Int = 2, when ready: (() -> Bool)? = nil, _ action: @escaping () -> Void) {
            onRowsDrawn = action
            rowsAreReady = ready
            refreshesRemaining = frames
            let link = displayLink(target: self, selector: #selector(refresh(_:)))
            link.add(to: .main, forMode: .common)
            tick = link
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopWaiting() }
        }

        @objc private func refresh(_ link: CADisplayLink) {
            if refreshesRemaining > 0, rowsAreReady?() != true {
                refreshesRemaining -= 1
                return
            }
            let action = onRowsDrawn
            stopWaiting()
            action?()
        }

        private func stopWaiting() {
            tick?.invalidate()
            tick = nil
            rowsAreReady = nil
            onRowsDrawn = nil
        }
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
