import Foundation

struct FileListing {
    struct Column: Identifiable {
        let id: URL?
        let entries: [FileEntry]
        let isLoading: Bool
        let isActive: Bool
        let index: Int
        let revealedFolder: URL?

        @MainActor
        init?(folder: URL?, browser: FileBrowser, order: ([FileEntry]) -> [FileEntry] = { $0 }) {
            if let folder {
                guard let folderIndex = browser.columnPath.firstIndex(of: folder) else { return nil }
                index = folderIndex + 1
                entries = order(browser.expandedFolders[folder] ?? [])
                isLoading = browser.isLoadingContents(of: folder)
            } else {
                index = 0
                entries = order(browser.displayedEntries)
                isLoading = browser.isLoading
            }
            id = folder
            isActive = browser.activeColumn == folder
            revealedFolder = browser.columnPath.indices.contains(index) ? browser.columnPath[index] : nil
        }

        func selected(from ids: Set<URL>) -> Set<URL> {
            isActive ? matchingIDs(ids) : []
        }

        func matchingIDs(_ ids: Set<URL>) -> Set<URL> {
            FileListing.matchingIDs(ids, in: entries)
        }
    }

    struct Outline {
        let expanded: Set<URL>
        let childrenByFolder: [URL: [FileEntry]]
        let overlappingRoots: Bool

        func rows(from roots: [FileEntry], orderChildren: ([FileEntry]) -> [FileEntry] = { $0 },
                  record: (URL, Int, Int) -> Void = { _, _, _ in }) -> [FileEntry] {
            guard !expanded.isEmpty else { return roots }
            var topLevel = roots
            if overlappingRoots {
                // Spotlight can return both a folder and an item visible inside that folder.
                var nested: Set<URL> = []
                func collectChildren(of folder: URL) {
                    guard expanded.contains(folder), let children = childrenByFolder[folder] else { return }
                    for child in children where nested.insert(child.id).inserted {
                        if child.canExpand { collectChildren(of: child.id) }
                    }
                }
                for root in roots where root.canExpand { collectChildren(of: root.id) }
                topLevel.removeAll { nested.contains($0.id) }
            }

            var result: [FileEntry] = []
            func append(_ entries: [FileEntry], depth: Int) {
                for entry in entries {
                    result.append(entry)
                    let index = result.count
                    if entry.canExpand, expanded.contains(entry.url), let children = childrenByFolder[entry.url] {
                        append(orderChildren(children), depth: depth + 1)
                    }
                    record(entry.id, depth, result.count - index)
                }
            }
            append(topLevel, depth: 0)
            return result
        }
    }

    let displayMode: FileDisplayMode
    let entries: [FileEntry]
    let groups: [FileDateGroup]?
    let columns: [Column]
    private var depths: [URL: Int] = [:]
    private var descendantCounts: [URL: Int] = [:]

    @MainActor
    init(browser: FileBrowser, settings: NotchSettings, inDisplayOrder: Bool = true) {
        displayMode = browser.displayMode
        let sortOrder = browser.tableSortOrder
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
            // Membership checks on clicks use the same rows without sorting or date grouping.
            guard inDisplayOrder else { return entries }
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

        switch displayMode {
        case .icons, .gallery:
            columns = []
            groups = nil
            entries = ordered(browser.displayedEntries)
        case .columns:
            let folders: [URL?] = [nil] + browser.columnPath.map(Optional.some)
            columns = folders.compactMap { Column(folder: $0, browser: browser, order: ordered) }
            groups = nil
            let visible = columns.flatMap(\.entries)
            if case .tag = browser.destination, columns.count > 1 {
                var seen: Set<URL> = []
                entries = visible.filter { seen.insert($0.id).inserted }
            } else {
                entries = visible
            }
        case .list:
            let roots = ordered(browser.displayedEntries)
            columns = []
            let outline = browser.outline
            var depths: [URL: Int] = [:]
            var counts: [URL: Int] = [:]
            func rows(_ roots: [FileEntry]) -> [FileEntry] {
                outline.rows(from: roots, orderChildren: ordered) { url, depth, descendants in
                    if inDisplayOrder {
                        if depth > 0 { depths[url] = depth }
                        if descendants > 0 { counts[url] = descendants }
                    }
                }
            }
            if inDisplayOrder && browser.groupsFilesByAddedDate {
                let dateGroups = FileDateGroup.byDateAdded(roots).map {
                    FileDateGroup(title: $0.title, entries: rows($0.entries))
                }
                groups = dateGroups
                entries = dateGroups.flatMap(\.entries)
            } else {
                groups = nil
                entries = rows(roots)
            }
            self.depths = depths
            descendantCounts = counts
        }
    }

    func depth(of item: URL) -> Int { depths[item, default: 0] }

    func descendantCount(of folder: URL) -> Int { descendantCounts[folder, default: 0] }

    func visibleSelection(_ ids: Set<URL>) -> Set<URL> {
        if displayMode == .columns {
            return columns.first(where: \.isActive)?.matchingIDs(ids) ?? []
        }
        return Self.matchingIDs(ids, in: entries)
    }

    private static func matchingIDs(_ ids: Set<URL>, in entries: [FileEntry]) -> Set<URL> {
        guard !ids.isEmpty else { return [] }
        var result: Set<URL> = []
        for entry in entries where ids.contains(entry.id) {
            result.insert(entry.id)
            if result.count == ids.count { break }
        }
        return result
    }

    var visibleIDs: Set<URL> { Set(entries.map(\.url)) }

    func entries(in column: URL?) -> [FileEntry] {
        columns.first { $0.id == column }?.entries ?? []
    }

    func selected(_ ids: Set<URL>) -> [FileEntry] {
        guard !ids.isEmpty else { return [] }
        return entries.filter { ids.contains($0.url) }
    }
}
