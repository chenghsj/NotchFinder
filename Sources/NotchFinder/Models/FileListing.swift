import Foundation

struct FileListing {
    let entries: [FileEntry]
    let groups: [FileDateGroup]?

    @MainActor
    init(browser: FileBrowser, settings: NotchSettings) {
        let sortOrder = browser.tableSortOrder(for: settings)
        let preferred = settings.fileSort
        let foldersFirst = settings.foldersFirst
        let sizeOrder: SortOrder?
        if sortOrder.isEmpty {
            sizeOrder = preferred == .size ? .reverse : nil
        } else if sortOrder.count == 1, let primary = sortOrder.first,
                  primary == KeyPathComparator(\FileEntry.fileSize, order: primary.order) {
            sizeOrder = primary.order
        } else {
            sizeOrder = nil
        }

        func ordered(_ entries: [FileEntry]) -> [FileEntry] {
            // Folder reads already supply localized names; Recents starts in last-opened order.
            if sortOrder.isEmpty, preferred == .name, foldersFirst || browser.showsRecentItems { return entries }
            let result: [FileEntry]
            switch sizeOrder {
            case .forward:
                result = entries.sorted { $0.fileSize < $1.fileSize }
            case .reverse:
                result = entries.sorted { $0.fileSize > $1.fileSize }
            case nil:
                let comparator: KeyPathComparator<FileEntry> = switch preferred {
                case .name: KeyPathComparator(\.name, comparator: .localizedStandard)
                case .kind: KeyPathComparator(\.kind, comparator: .localizedStandard)
                case .size: KeyPathComparator(\.fileSize, order: .reverse)
                case .modified: KeyPathComparator(\.modified, order: .reverse)
                }
                result = entries.sorted(using: sortOrder.isEmpty ? [comparator] : sortOrder)
            }
            return foldersFirst ? result.filter(\.isFolder) + result.filter { !$0.isFolder } : result
        }

        let roots = ordered(browser.displayedEntries)
        if settings.displayMode == .icons {
            groups = nil
            entries = roots
        } else if browser.groupsFilesByAddedDate(for: settings) {
            let dateGroups = FileDateGroup.byDateAdded(roots).map { group in
                FileDateGroup(title: group.title,
                              entries: browser.listedEntries(from: group.entries, orderChildren: ordered))
            }
            groups = dateGroups
            entries = dateGroups.flatMap(\.entries)
        } else {
            groups = nil
            entries = browser.listedEntries(from: roots, orderChildren: ordered)
        }
    }

    var visibleIDs: Set<URL> { Set(entries.map(\.url)) }

    func selected(_ ids: Set<URL>) -> [FileEntry] {
        guard !ids.isEmpty else { return [] }
        return entries.filter { ids.contains($0.url) }
    }
}
