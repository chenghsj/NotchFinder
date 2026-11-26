import SwiftUI

struct FileColumns: View {
    let browser: FileBrowser
    let listing: FileListing
    let settings: NotchSettings

    private var columnWidth: CGFloat { 164 + 8 * (settings.interfaceSize.panelText - FileDisplaySize.small.panelText) }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(listing.columns) { column in
                        let id = column.id ?? browser.directory
                        columnView(column)
                            .frame(width: columnWidth)
                            .id(id)
                        Divider()
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .onChange(of: browser.columnPath.last, initial: true) { _, folder in
                scroll.scrollTo(folder ?? browser.directory, anchor: folder == nil ? .leading : .trailing)
            }
        }
    }

    private func columnView(_ column: FileListing.Column) -> some View {
        let ids = Set(column.entries.map(\.id))
        let selection = Binding(
            get: { browser.selection.intersection(ids) },
            set: { browser.selectColumnItems($0, in: column.id) }
        )
        let revealedFolder = column.id.flatMap { browser.columnPath.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let revealed = browser.columnPath.indices.contains(revealedFolder) ? browser.columnPath[revealedFolder] : nil

        return List(selection: selection) {
            ForEach(column.entries) { entry in
                row(entry)
                    .tag(entry.id)
                    .itemProvider { NSItemProvider(object: entry.url as NSURL) }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowBackground(Color.accentColor.opacity(revealed == entry.id ? 0.13 : 0))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ColumnClickTarget { browser.selectColumnItems([], in: column.id) })
        .accessibilityLabel(column.id.map(browser.name(for:)) ?? browser.title)
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
            if entry.canExpand && !browser.showsRecentItems {
                Image(systemName: "chevron.forward")
                    .font(.system(size: max(8, size.panelIcon - 5), weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: size.row.height)
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
