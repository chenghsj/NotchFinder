import AppKit
import Observation
import UniformTypeIdentifiers

struct FileEntry: Identifiable, Equatable, Sendable {
    enum FileKind: Equatable, Sendable {
        case folder, file, systemDescription(String)

        var title: String {
            switch self {
            case .folder: L10n.text("資料夾")
            case .file: L10n.text("檔案")
            case .systemDescription(let description): description
            }
        }
    }

    let url: URL
    let name: String
    let isFolder: Bool
    let isSymbolicLink: Bool
    let fileKind: FileKind
    let fileSize: Int64
    let modified: Date
    let added: Date
    var lastUsed = Date.distantPast

    var id: URL { url }
    var kind: String { fileKind.title }
    var canExpand: Bool { isFolder && !isSymbolicLink }
}

enum BrowserEdit: Equatable {
    case createFolder, rename(URL), goToFolder

    var title: String {
        switch self {
        case .createFolder: L10n.text("新增資料夾")
        case .rename: L10n.text("重新命名")
        case .goToFolder: L10n.text("前往資料夾")
        }
    }
}

@MainActor
@Observable
final class FileBrowser {
    enum Destination: Hashable, Sendable {
        case folder(URL), recentItems, tag(String)

        var preferenceKey: String {
            switch self {
            case .folder(let folder): "folder:\(folder.standardizedFileURL.path)"
            case .recentItems: "recents"
            case .tag(let name): "tag:\(name)"
            }
        }

        var spotlightSearch: SpotlightFileSearch.Scope? {
            switch self {
            case .folder: nil
            case .recentItems: .recents
            case .tag(let name): .tag(name)
            }
        }
    }

    private static let dateGroupedPaths = Set(
        [FileManager.SearchPathDirectory.downloadsDirectory, .trashDirectory].compactMap { directory in
            FileManager.default.urls(for: directory, in: .userDomainMask).first?.standardizedFileURL.path
        }
    )

    let sidebar: SidebarLocations
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let settings: NotchSettings
    @ObservationIgnored private let fileHistory: FileOperationHistory
    private(set) var destination: Destination
    private(set) var displayMode: FileDisplayMode
    @ObservationIgnored private var installedApplicationsFolder: URL?
    private var lastFolder: URL
    private(set) var entries: [FileEntry] = []
    private(set) var expandedFolders: [URL: [FileEntry]] = [:]
    private var inlineExpansions: Set<URL> = []
    private(set) var inlineCollapseChange = 0
    private(set) var columnPath: [URL] = []
    private(set) var activeColumn: URL?
    private(set) var isLoading = false
    private(set) var readError: String?
    private var localError: String?
    private(set) var openError: String? {
        get { localError ?? (showsTrash ? fileHistory.trashFailure?.message : nil) }
        set { localError = newValue }
    }
    var trashRecovery: TrashRemovalRequest? { fileHistory.trashFailure?.request }
    private(set) var fileIconsEnabled = false
    private(set) var showsHidden: Bool
    private(set) var editing: BrowserEdit?
    var isUpdatingFiles: Bool { fileHistory.isRunning }
    @ObservationIgnored var onDirectoryChange: (() -> Void)?
    @ObservationIgnored var onPreview: (([FileEntry]) -> Void)?
    private(set) var selection: Set<URL> = []
    var filter = "" {
        didSet {
            if filter != oldValue { pruneExpandedFolders() }
        }
    }
    var editText = ""
    private var tableSort: (preferred: FileSort, grouped: Bool, order: [KeyPathComparator<FileEntry>])?

    private var backHistory: [Destination] = []
    private var forwardHistory: [Destination] = []
    @ObservationIgnored private let contentSource: BrowserContentRefresh.Source
    @ObservationIgnored private lazy var contentRefresh = BrowserContentRefresh(
        destination: destination, includeHidden: showsHidden, source: contentSource,
        fileOperationInProgress: { [fileHistory] in fileHistory.isRunning }
    ) { [weak self] change in
        self?.applyContentChange(change)
    }

    init(initialDirectory: URL? = nil, sidebar: SidebarLocations? = nil, settings: NotchSettings,
         contentSource: BrowserContentRefresh.Source = .live, fileHistory: FileOperationHistory = FileOperationHistory()) {
        let defaults = settings.defaults
        self.sidebar = sidebar ?? SidebarLocations(defaults: defaults)
        self.defaults = defaults
        self.settings = settings
        self.contentSource = contentSource
        self.fileHistory = fileHistory
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL
        let folder = initialDirectory ?? home
        destination = .folder(folder)
        displayMode = settings.displayMode(for: .folder(folder))
        lastFolder = folder
        showsHidden = defaults.bool(forKey: "showsHiddenItems")
    }

    var directory: URL { lastFolder }
    var isBrowsingFolder: Bool { destination.spotlightSearch == nil }
    var showsRecentItems: Bool { destination == .recentItems }
    var showsTrash: Bool { isBrowsingFolder && directory.path == sidebar.trashDirectory?.path }

    var title: String {
        if showsRecentItems { return L10n.text("最近項目") }
        if case .tag(let name) = destination { return name }
        if let location = sidebar.items.first(where: { $0.url == directory }) { return location.name }
        return name(for: directory)
    }

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var canGoUp: Bool { isBrowsingFolder && directory.path != "/" }
    var canPinFolder: Bool { isBrowsingFolder && sidebar.canFavorite(directory) }
    var isPinned: Bool { isBrowsingFolder && sidebar.isFavorite(directory) }

    var breadcrumbs: [URL] {
        var path = directory
        var chain = [path]
        while path.path != "/" {
            path = path.deletingLastPathComponent()
            chain.append(path)
        }
        return chain.reversed()
    }

    var displayedEntries: [FileEntry] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            if entry.name.localizedStandardContains(query) { return true }
            let filename = entry.url.lastPathComponent
            return filename != entry.name && filename.localizedStandardContains(query)
        }
    }

    var listing: FileListing { FileListing(browser: self, settings: settings) }

    func setDisplayMode(_ mode: FileDisplayMode) {
        settings.setDisplayMode(mode, for: destination)
        filePresentationDidChange()
    }

    func filePresentationDidChange() {
        if let tableSort, tableSort.preferred != settings.fileSort || tableSort.grouped != groupsFilesByAddedDate {
            self.tableSort = nil
        }
        let mode = settings.displayMode(for: destination)
        guard displayMode != mode else { return }
        displayMode = mode
        if mode != .columns, !columnPath.isEmpty || activeColumn != nil {
            columnPath = []
            activeColumn = nil
            pruneExpandedFolders()
        } else if !selection.isEmpty {
            selectItems(selection)
        }
    }

    func selectItems(_ items: Set<URL>) {
        guard !items.isEmpty else {
            if !selection.isEmpty { selection = [] }
            return
        }
        let visibleItems = FileListing(browser: self, settings: settings, inDisplayOrder: false).visibleSelection(items)
        if selection != visibleItems { selection = visibleItems }
    }

    func selectAll() {
        let listing = self.listing
        if listing.displayMode == .columns {
            selectColumnItems(Set(listing.entries(in: activeColumn).map(\.id)), in: activeColumn)
        } else {
            selection = listing.visibleIDs
        }
    }

    func moveGallerySelection(by offset: Int) -> Bool {
        guard displayMode == .gallery else { return false }
        let entries = listing.entries
        guard !entries.isEmpty else { return false }
        let current = entries.firstIndex { selection.contains($0.id) } ?? 0
        selection = [entries[min(entries.count - 1, max(0, current + offset))].id]
        return true
    }

    var outline: FileListing.Outline {
        let overlappingRoots = if case .tag = destination { true } else { false }
        return FileListing.Outline(expanded: inlineExpansions, childrenByFolder: expandedFolders, overlappingRoots: overlappingRoots)
    }

    func entries(matching items: Set<URL>) -> [FileEntry] {
        guard !items.isEmpty else { return [] }
        return listing.selected(items)
    }

    var groupsFilesByAddedDate: Bool {
        guard settings.groupsByAddedDate, case .folder(let folder) = destination else { return false }
        return Self.dateGroupedPaths.contains(folder.standardizedFileURL.path)
    }

    var tableSortOrder: [KeyPathComparator<FileEntry>] {
        guard let tableSort, tableSort.preferred == settings.fileSort,
              tableSort.grouped == groupsFilesByAddedDate else { return [] }
        return tableSort.order
    }

    func setTableSortOrder(_ order: [KeyPathComparator<FileEntry>]) {
        tableSort = order.isEmpty ? nil : (settings.fileSort, groupsFilesByAddedDate, order)
    }

    func toggleExpansion(of folder: FileEntry, animateLayout: Bool = true) {
        guard folder.canExpand else { return }
        if inlineExpansions.remove(folder.url) != nil {
            if animateLayout { inlineCollapseChange += 1 }
            pruneExpandedFolders()
        } else {
            inlineExpansions.insert(folder.url)
            expand(folder.url)
        }
    }

    func isExpandedInList(_ folder: URL) -> Bool { inlineExpansions.contains(folder) }

    func isLoadingContents(of folder: URL) -> Bool { contentRefresh.loadingFolders.contains(folder) }

    func selectColumnItems(_ items: Set<URL>, in folder: URL?) {
        guard displayMode == .columns, let column = FileListing.Column(folder: folder, browser: self) else { return }
        let visibleItems = column.matchingIDs(items)
        let child = visibleItems.count == 1
            ? column.entries.first { visibleItems.contains($0.id) && $0.canExpand }?.url
            : nil
        activeColumn = folder
        selection = visibleItems
        let parentPath = columnPath.prefix(column.index)
        let path = Array(parentPath) + (child.map { [$0] } ?? [])
        guard columnPath != path else { return }
        columnPath = path
        pruneExpandedFolders()
        if let child { expand(child) }
    }

    private func expand(_ folder: URL) {
        guard expandedFolders[folder] == nil else { return }
        expandedFolders[folder] = []
        openError = nil
        contentRefresh.expand(folder)
    }

    func name(for url: URL) -> String {
        url.path == "/" ? L10n.text("根目錄") : url.lastPathComponent
    }

    func toggleFavorite() {
        if canPinFolder { sidebar.toggleFavorite(directory) }
    }

    func setShowsHidden(_ value: Bool) {
        guard showsHidden != value else { return }
        showsHidden = value
        defaults.set(value, forKey: "showsHiddenItems")
        contentRefresh.setIncludesHidden(value)
    }

    func navigate(to destination: URL) {
        navigate(to: .folder(destination.standardizedFileURL))
    }

    func volumeDidUnmount(at volume: URL) {
        let root = volume.standardizedFileURL.path
        guard root != "/" else { return }
        func belongsToVolume(_ folder: URL) -> Bool {
            folder.path == root || folder.path.hasPrefix(root + "/")
        }
        func isUnavailable(_ target: Destination) -> Bool {
            guard case .folder(let folder) = target else { return false }
            return belongsToVolume(folder)
        }
        backHistory.removeAll(where: isUnavailable)
        forwardHistory.removeAll(where: isUnavailable)

        guard belongsToVolume(directory) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let fallback = belongsToVolume(home) ? URL(fileURLWithPath: "/", isDirectory: true) : home
        if !isBrowsingFolder {
            lastFolder = fallback
            onDirectoryChange?()
            contentRefresh.reload(quietly: true)
        } else {
            load(.folder(fallback))
        }
    }

    func showRecentItems() {
        showSearch(.recentItems)
    }

    func showTag(_ name: String) {
        showSearch(.tag(name))
    }

    private func showSearch(_ target: Destination) {
        if destination == target { reload() }
        else { navigate(to: target) }
    }

    private func navigate(to target: Destination) {
        guard target != destination else { return }
        backHistory.append(destination)
        forwardHistory.removeAll()
        load(target)
    }

    func goBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(destination)
        load(previous)
    }

    func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(destination)
        load(next)
    }

    func goUp() {
        if canGoUp { navigate(to: directory.deletingLastPathComponent()) }
    }

    func open(_ entry: FileEntry) {
        if entry.isFolder {
            navigate(to: entry.url)
        } else {
            openError = NSWorkspace.shared.open(entry.url) ? nil : L10n.text("無法開啟「%@」", String(describing: entry.name))
        }
    }

    func openItems(_ items: Set<URL>) {
        let chosen = entries(matching: items)
        if chosen.count == 1, let item = chosen.first { open(item); return }
        for item in chosen where !NSWorkspace.shared.open(item.url) {
            openError = L10n.text("無法開啟「%@」", String(describing: item.name))
        }
    }

    func showPreview(_ items: Set<URL>) {
        let entries = entries(matching: items)
        if !entries.isEmpty { onPreview?(entries) }
    }

    func setContentActive(_ active: Bool, revalidation: BrowserContentRefresh.Revalidation) {
        if active {
            showsHidden = defaults.bool(forKey: "showsHiddenItems")
            openError = nil
        }
        contentRefresh.setActive(active, includeHidden: showsHidden, revalidation: revalidation)
        if active { _ = visitInstalledApplicationsFolder() }
    }

    func revealInFinder(_ items: Set<URL>) {
        let chosen = urls(for: items)
        if !chosen.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(chosen) }
    }

    func copyItems(_ items: Set<URL>) {
        let chosen = urls(for: items)
        guard !chosen.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.writeObjects(chosen.map { $0 as NSURL })
    }

    func copyPaths(_ items: Set<URL>) {
        let chosen = urls(for: items)
        guard !chosen.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(chosen.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func pasteItems(cleanupInstaller: Bool = false) {
        guard isBrowsingFolder else { return }
        pasteItems(ClipboardContents.fileURLs(from: .general), cleanupInstaller: cleanupInstaller)
    }

    func pasteItems(_ sources: [URL], cleanupInstaller: Bool) {
        guard isBrowsingFolder else { return }
        guard !sources.isEmpty else { openError = L10n.text("剪貼簿裡沒有檔案"); return }
        let folder = directory
        if cleanupInstaller, sources.count == 1, let app = sources.first,
           folder.resolvingSymlinksInPath().path == DiskImageInstall.applicationsDirectory.resolvingSymlinksInPath().path,
           DiskImageInstall.canInstall(app) {
            installApplication(app, cleanupInstaller: true)
            return
        }
        updateFiles { try LocalFileOperations.copy(sources, into: folder) }
    }

    enum DropDestination: Equatable, Sendable {
        case folder(URL)
        case trash
    }

    func acceptFileDrop(into destination: DropDestination, copies: Bool,
                        load: (@escaping @MainActor ([URL]) -> Void) -> Void) -> Bool {
        guard let execute = fileHistory.reserve(from: self) else { return false }
        load { [fileHistory] urls in
            execute {
                guard !urls.isEmpty else { return .files(L10n.text("無法讀取拖放的檔案")) }
                return .files(await fileHistory.perform {
                    switch destination {
                    case .folder(let folder): try LocalFileOperations.drop(urls, into: folder, copies: copies)
                    case .trash: try LocalFileOperations.trash(urls)
                    }
                })
            }
        }
        return true
    }

    func installSelectedApplication(_ app: URL, cleanupInstaller: Bool) {
        guard !entries(matching: [app]).isEmpty else { return }
        installApplication(app, cleanupInstaller: cleanupInstaller)
    }

    private func installApplication(_ app: URL, cleanupInstaller: Bool) {
        let origin = destination
        let applications = DiskImageInstall.applicationsDirectory
        runFileOperation { [fileHistory] in
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try DiskImageInstall.install(app, into: applications, cleanup: cleanupInstaller)
                }.value
                fileHistory.record(outcome.reversals)
                return .installed(from: origin, into: applications, warning: outcome.warning)
            } catch {
                return .files(error.localizedDescription)
            }
        }
    }

    func compressItems(_ items: Set<URL>) {
        let chosen = urls(for: items)
        guard !chosen.isEmpty else { return }
        updateFiles { try LocalFileOperations.compress(chosen) }
    }

    func trashItems(_ items: Set<URL>) {
        let chosen = urls(for: items)
        guard !chosen.isEmpty else { return }
        updateFiles { try LocalFileOperations.trash(chosen) }
    }

    func emptyTrash(retrying request: TrashRemovalRequest? = nil,
                    authorize: @escaping @Sendable (TrashRemovalRequest) throws -> Void = { try $0.removeWithAdministratorPrivileges() }) {
        guard let directory = sidebar.trashDirectory else { return }
        runFileOperation {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try LocalFileOperations.emptyTrash(at: directory, retrying: request, authorize: authorize)
                }.value
                return .emptiedTrash(nil, nil)
            } catch let error as LocalFileOperations.Failure {
                return .emptiedTrash(error.localizedDescription, error.trashRecovery)
            } catch {
                return .emptiedTrash(error.localizedDescription, nil)
            }
        }
    }

    func revealRemainingTrashItems() {
        guard let request = trashRecovery else { return }
        do {
            let urls = try request.remainingItems().map { request.directory.appendingPathComponent($0.name, isDirectory: false) }
            if urls.isEmpty { fileHistory.clearTrashFailure(); reload() }
            else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        } catch {
            fileHistory.clearTrashFailure()
            reload()
            openError = error.localizedDescription
        }
    }

    func replayFileOperation(_ direction: FileOperationHistory.Direction) {
        guard fileHistory.canReplay(direction) else { return }
        runFileOperation { [fileHistory] in .files(await fileHistory.replay(direction)) }
    }

    func beginEditing(_ request: BrowserEdit) {
        guard !isUpdatingFiles, request != .createFolder || isBrowsingFolder else { return }
        switch request {
        case .createFolder: editText = L10n.text("未命名資料夾")
        case .rename(let item):
            guard !entries(matching: [item]).isEmpty else { return }
            editText = item.lastPathComponent
        case .goToFolder: editText = directory.path
        }
        editing = request
    }

    func cancelEditing() { editing = nil }

    func commitEditing() {
        guard let editing else { return }
        let input = editText
        let folder = directory
        if editing != .goToFolder, (try? LocalFileOperations.checkedName(input)) == nil {
            openError = L10n.text("請輸入有效的名稱")
            return
        }
        self.editing = nil
        switch editing {
        case .createFolder:
            updateFiles { try LocalFileOperations.createFolder(named: input, in: folder) }
        case .rename(let item):
            updateFiles { try LocalFileOperations.rename(item, to: input) }
        case .goToFolder:
            let path = (input.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard !path.isEmpty else { return }
            navigate(to: URL(fileURLWithPath: path, isDirectory: true, relativeTo: folder).absoluteURL)
        }
    }

    private func urls(for items: Set<URL>) -> [URL] {
        entries(matching: items).map(\.url)
    }

    private func updateFiles(operation: @escaping @Sendable () throws -> [FileReversal]) {
        runFileOperation { [fileHistory] in .files(await fileHistory.perform(operation)) }
    }

    private func runFileOperation(_ operation: @escaping FileOperationHistory.Operation) {
        fileHistory.reserve(from: self)?(operation)
    }

    func revealAfterInstall(from source: Destination, into applications: URL) {
        // Only the initiating tab should navigate, even if installation finished while it was hidden.
        if destination == source && source != .folder(applications) { installedApplicationsFolder = applications }
    }

    private func visitInstalledApplicationsFolder() -> Bool {
        guard let folder = installedApplicationsFolder else { return false }
        navigate(to: folder)
        return true
    }

    func receive(_ result: FileOperationHistory.Completion) {
        if !visitInstalledApplicationsFolder() { reload() }
        showOperationMessage(result.message)
    }

    func showOperationMessage(_ message: String?) { openError = message }

    func reload() { contentRefresh.reload() }

    private func applyContentChange(_ change: BrowserContentRefresh.Change) {
        switch change {
        case .loading:
            isLoading = true
            readError = nil
            openError = nil
        case .paused:
            isLoading = false
        case .root(let result):
            switch result {
            case .success(let files):
                if entries != files { entries = files }
                readError = nil
                if showsTrash, let request = trashRecovery,
                   (try? request.remainingItems().isEmpty) == true { fileHistory.clearTrashFailure() }
            case .failure(let error):
                entries = []
                readError = error.localizedDescription
            }
            pruneExpandedFolders()
            isLoading = false
        case .folder(let folder, let result):
            switch result {
            case .success(let children):
                expandedFolders[folder] = children
            case .failure(let error):
                expandedFolders[folder] = nil
                inlineExpansions.remove(folder)
                if let index = columnPath.firstIndex(of: folder) {
                    columnPath.removeSubrange(index...)
                }
                openError = L10n.text("無法展開「%@」：%@", name(for: folder), error.localizedDescription)
            }
            pruneExpandedFolders()
        }
    }

    private func pruneExpandedFolders() {
        if !inlineExpansions.isEmpty {
            let listEntries = outline.rows(from: entries)
            inlineExpansions.formIntersection(listEntries.lazy.filter(\.canExpand).map(\.url))
        }

        let hadColumnPath = !columnPath.isEmpty || activeColumn != nil
        let columnRoots = hadColumnPath ? displayedEntries : []
        var columnEntries = columnRoots
        var validDepth = 0
        for folder in columnPath {
            guard columnEntries.contains(where: { $0.url == folder && $0.canExpand }) else { break }
            validDepth += 1
            columnEntries = expandedFolders[folder] ?? []
        }
        if validDepth < columnPath.count { columnPath.removeSubrange(validDepth...) }
        if let activeColumn, !columnPath.contains(activeColumn) { self.activeColumn = nil }

        let retained = inlineExpansions.union(columnPath)
        for folder in Array(expandedFolders.keys) where !retained.contains(folder) {
            expandedFolders[folder] = nil
        }
        contentRefresh.retainExpandedFolders(Set(expandedFolders.keys))
        if !selection.isEmpty { selectItems(selection) }
    }

    func enableFileIcons() {
        if !fileIconsEnabled { fileIconsEnabled = true }
    }

    private func load(_ target: Destination) {
        installedApplicationsFolder = nil
        let wasGrouped = groupsFilesByAddedDate
        if showsRecentItems != (target == .recentItems) { tableSort = nil }
        if case .folder(let folder) = target { lastFolder = folder }
        destination = target
        displayMode = settings.displayMode(for: target)
        if groupsFilesByAddedDate != wasGrouped { tableSort = nil }
        entries = []
        columnPath = []
        activeColumn = nil
        pruneExpandedFolders()
        editing = nil
        filter = ""
        contentRefresh.navigate(to: target)
        onDirectoryChange?()
    }

    nonisolated static func readContents(of folder: URL, includeHidden: Bool) async throws -> [FileEntry] {
        try await readContents(at: .folder(folder), includeHidden: includeHidden)
    }

    nonisolated static func readContents(at destination: Destination, includeHidden: Bool) async throws -> [FileEntry] {
        let reader = Task.detached(priority: .userInitiated) {
            switch destination {
            case .folder(let folder): try read(folder, includeHidden: includeHidden)
            case .recentItems: try SpotlightFileSearch.read(in: .recents, includeHidden: includeHidden)
            case .tag(let name): try SpotlightFileSearch.read(in: .tag(name), includeHidden: includeHidden)
            }
        }
        return try await withTaskCancellationHandler {
            try await reader.value
        } onCancel: {
            reader.cancel()
        }
    }

    private nonisolated static func read(_ folder: URL, includeHidden: Bool) throws -> [FileEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey,
                                        .isAliasFileKey, .hasHiddenExtensionKey, .fileSizeKey,
                                        .contentModificationDateKey, .addedToDirectoryDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        var fileKinds: [String: FileEntry.FileKind] = [:]
        let files = try urls.map { url in
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: keys)
            let target: URLResourceValues?
            if values?.isSymbolicLink == true {
                target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            } else {
                target = values
            }
            let isFolder = target?.isDirectory == true && target?.isPackage != true
            let fileExtension = url.pathExtension.lowercased()
            let kind: FileEntry.FileKind
            if isFolder {
                kind = .folder
            } else if let cached = fileKinds[fileExtension] {
                kind = cached
            } else {
                let description = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)?.localizedDescription
                kind = description.map(FileEntry.FileKind.systemDescription) ?? .file
                fileKinds[fileExtension] = kind
            }
            let filename = url.lastPathComponent
            // Ordinary files with visible extensions already have their display name.
            let name: String
            if values?.isRegularFile == true, values?.isPackage == false, values?.isSymbolicLink == false,
               values?.isAliasFile == false, values?.hasHiddenExtension == false,
               filename.rangeOfCharacter(from: .controlCharacters) == nil {
                name = filename
            } else {
                name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? filename
            }
            return FileEntry(
                url: url,
                name: name,
                isFolder: isFolder,
                isSymbolicLink: values?.isSymbolicLink == true,
                fileKind: kind,
                fileSize: isFolder ? -1 : Int64(values?.fileSize ?? -1),
                modified: values?.contentModificationDate ?? .distantPast,
                added: values?.addedToDirectoryDate ?? .distantPast
            )
        }
        return files.sorted { first, second in
            if first.isFolder != second.isFolder { return first.isFolder }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }
}
