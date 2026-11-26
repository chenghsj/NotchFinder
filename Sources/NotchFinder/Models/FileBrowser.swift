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
        case folder(URL), recentItems

        var displayModeKey: String {
            switch self {
            case .folder(let folder): "folder:\(folder.standardizedFileURL.path)"
            case .recentItems: "recents"
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
    private(set) var destination: Destination
    private var lastFolder: URL
    private(set) var entries: [FileEntry] = []
    private(set) var expandedFolders: [URL: [FileEntry]] = [:]
    private var inlineExpansions: Set<URL> = []
    private(set) var columnPath: [URL] = []
    private(set) var activeColumn: URL?
    private(set) var isLoading = false
    private(set) var readError: String?
    private(set) var openError: String?
    private(set) var fileIconsEnabled = false
    private(set) var showsHidden: Bool
    private(set) var editing: BrowserEdit?
    private(set) var isUpdatingFiles = false {
        didSet { if !isUpdatingFiles { scheduleFolderRefresh() } }
    }
    @ObservationIgnored var onDirectoryChange: (() -> Void)?
    @ObservationIgnored var onPreview: ((Set<URL>) -> Void)?
    var selection: Set<URL> = []
    var filter = "" {
        didSet {
            if !columnPath.isEmpty { pruneExpandedFolders() }
        }
    }
    var editText = ""
    private var tableSort: (preferred: FileSort, grouped: Bool, order: [KeyPathComparator<FileEntry>])?

    private var backHistory: [Destination] = []
    private var forwardHistory: [Destination] = []
    @ObservationIgnored private var hasLoadedContents = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var activationRefreshTask: Task<Void, Never>?
    private var folderTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var contentMonitoringEnabled = false
    @ObservationIgnored private var folderMonitor: FolderChangeMonitor?
    @ObservationIgnored private var monitoredDirectory: URL?
    @ObservationIgnored private var pendingFolderRefreshes: Set<URL> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(initialDirectory: URL? = nil, sidebar: SidebarLocations? = nil, defaults: UserDefaults = .standard) {
        self.sidebar = sidebar ?? SidebarLocations(defaults: defaults)
        self.defaults = defaults
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL
        let folder = initialDirectory ?? home
        destination = .folder(folder)
        lastFolder = folder
        showsHidden = defaults.bool(forKey: "showsHiddenItems")
    }

    deinit { loadTask?.cancel() }

    var directory: URL { lastFolder }
    var showsRecentItems: Bool { destination == .recentItems }

    var title: String {
        if showsRecentItems { return L10n.text("最近項目") }
        if let location = sidebar.items.first(where: { $0.url == directory }) { return location.name }
        return name(for: directory)
    }

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var canGoUp: Bool { !showsRecentItems && directory.path != "/" }
    var canPinFolder: Bool { !showsRecentItems && sidebar.canFavorite(directory) }
    var isPinned: Bool { !showsRecentItems && sidebar.isFavorite(directory) }

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

    func listedEntries(from roots: [FileEntry], orderChildren: ([FileEntry]) -> [FileEntry] = { $0 }) -> [FileEntry] {
        listedEntries(from: roots, expanding: inlineExpansions, orderChildren: orderChildren)
    }

    private func listedEntries(from roots: [FileEntry], expanding folders: Set<URL>,
                               orderChildren: ([FileEntry]) -> [FileEntry] = { $0 }) -> [FileEntry] {
        guard !folders.isEmpty else { return roots }
        var result: [FileEntry] = []
        func append(_ entries: [FileEntry]) {
            for entry in entries {
                result.append(entry)
                if entry.canExpand, folders.contains(entry.url), let children = expandedFolders[entry.url] {
                    append(orderChildren(children))
                }
            }
        }
        append(roots)
        return result
    }

    func entries(matching items: Set<URL>) -> [FileEntry] {
        guard !items.isEmpty else { return [] }
        return listedEntries(from: displayedEntries, expanding: inlineExpansions.union(columnPath))
            .filter { items.contains($0.url) }
    }

    func groupsFilesByAddedDate(for settings: NotchSettings) -> Bool {
        guard settings.groupsByAddedDate, case .folder(let folder) = destination else { return false }
        return Self.dateGroupedPaths.contains(folder.standardizedFileURL.path)
    }

    func tableSortOrder(for settings: NotchSettings) -> [KeyPathComparator<FileEntry>] {
        guard let tableSort, tableSort.preferred == settings.fileSort,
              tableSort.grouped == groupsFilesByAddedDate(for: settings) else { return [] }
        return tableSort.order
    }

    func setTableSortOrder(_ order: [KeyPathComparator<FileEntry>], for settings: NotchSettings) {
        tableSort = order.isEmpty ? nil : (settings.fileSort, groupsFilesByAddedDate(for: settings), order)
    }

    func toggleExpansion(of folder: FileEntry) {
        guard folder.canExpand else { return }
        if inlineExpansions.remove(folder.url) != nil {
            pruneExpandedFolders()
        } else {
            inlineExpansions.insert(folder.url)
            expand(folder.url)
        }
    }

    func isExpandedInList(_ folder: URL) -> Bool { inlineExpansions.contains(folder) }

    func isLoadingContents(of folder: URL) -> Bool { folderTasks[folder] != nil }

    func selectColumnItems(_ items: Set<URL>, in folder: URL?) {
        let parentPath: [URL]
        let siblings: [FileEntry]
        if let folder {
            guard let index = columnPath.firstIndex(of: folder) else { return }
            parentPath = Array(columnPath[...index])
            siblings = expandedFolders[folder] ?? []
        } else {
            parentPath = []
            siblings = displayedEntries
        }
        let child = items.count == 1 && !showsRecentItems
            ? siblings.first { items.contains($0.id) && $0.canExpand }?.url
            : nil
        activeColumn = folder
        selection = items
        let path = child.map { parentPath + [$0] } ?? parentPath
        guard columnPath != path else { return }
        columnPath = path
        pruneExpandedFolders()
        if let child { expand(child) }
    }

    func resetColumns() {
        guard !columnPath.isEmpty else { return }
        columnPath = []
        activeColumn = nil
        pruneExpandedFolders()
    }

    private func expand(_ folder: URL) {
        guard expandedFolders[folder] == nil else { return }
        expandedFolders[folder] = []
        openError = nil
        loadExpandedFolder(folder, includeHidden: showsHidden)
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
        reload()
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
        if showsRecentItems {
            lastFolder = fallback
            onDirectoryChange?()
            reload(quietly: true)
        } else {
            load(.folder(fallback))
        }
    }

    func showRecentItems() {
        if showsRecentItems { reload() }
        else { navigate(to: .recentItems) }
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
        if !items.isEmpty { onPreview?(items) }
    }

    func activate() {
        let includeHidden = defaults.bool(forKey: "showsHiddenItems")
        let hiddenItemsChanged = showsHidden != includeHidden
        showsHidden = includeHidden
        enableFileIcons()
        if showsRecentItems || hiddenItemsChanged || (!hasLoadedContents && loadTask == nil) {
            reload()
            return
        }

        openError = nil
        // Inactive folders are unwatched. Revalidate once the tab stays active.
        activationRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            await self.loadTask?.value
            guard !Task.isCancelled else { return }
            self.activationRefreshTask = nil
            self.reload(quietly: self.hasLoadedContents)
        }
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
        guard !showsRecentItems else { return }
        pasteItems(ClipboardContents.fileURLs(from: .general), cleanupInstaller: cleanupInstaller)
    }

    func pasteItems(_ sources: [URL], cleanupInstaller: Bool) {
        guard !showsRecentItems else { return }
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

    func installApplication(_ app: URL, cleanupInstaller: Bool) {
        guard !isUpdatingFiles else { return }
        let origin = destination
        let applications = DiskImageInstall.applicationsDirectory
        isUpdatingFiles = true
        openError = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DiskImageInstall.install(app, into: applications, cleanup: cleanupInstaller) }
            }.value
            guard let self else { return }
            self.isUpdatingFiles = false
            switch result {
            case .success(let warning):
                if self.destination == origin, origin != .folder(applications) { self.navigate(to: applications) }
                else if self.destination == .folder(applications) { self.reload() }
                self.openError = warning
            case .failure(let error):
                self.openError = error.localizedDescription
            }
        }
    }

    func setContentMonitoring(_ enabled: Bool) {
        if !enabled { cancelActivationRefresh() }
        guard contentMonitoringEnabled != enabled else { return }
        contentMonitoringEnabled = enabled
        if enabled {
            updateFolderMonitoring()
        } else {
            stopFolderMonitoring()
            if showsRecentItems {
                loadTask?.cancel()
                loadTask = nil
                isLoading = false
            }
        }
    }

    private func cancelActivationRefresh() {
        activationRefreshTask?.cancel()
        activationRefreshTask = nil
    }

    private func updateFolderMonitoring() {
        if showsRecentItems { stopFolderMonitoring(); return }
        guard contentMonitoringEnabled, monitoredDirectory != directory else { return }

        stopFolderMonitoring()
        let watched = directory
        folderMonitor = FolderChangeMonitor(directory: watched) { [weak self] paths, rescan in
            self?.receiveFolderChanges(paths, rescan: rescan, for: watched)
        }
        if folderMonitor != nil { monitoredDirectory = watched }
    }

    private func stopFolderMonitoring() {
        folderMonitor = nil
        monitoredDirectory = nil
        refreshTask?.cancel()
        refreshTask = nil
        pendingFolderRefreshes.removeAll()
    }

    private func receiveFolderChanges(_ paths: [String], rescan: Bool, for watched: URL) {
        guard contentMonitoringEnabled, monitoredDirectory == watched else { return }
        if rescan {
            pendingFolderRefreshes.insert(watched)
        } else {
            var affected: Set<String> = []
            for path in paths {
                affected.insert(path)
                affected.insert((path as NSString).deletingLastPathComponent)
            }
            for folder in [watched] + expandedFolders.keys {
                let path = folder.resolvingSymlinksInPath().path
                // FSEvents can report the /private path of macOS system folders.
                let privatePath = "/private" + path
                if affected.contains(path) ||
                    (affected.contains(privatePath) &&
                     URL(fileURLWithPath: privatePath, isDirectory: true).resolvingSymlinksInPath().path == path) {
                    pendingFolderRefreshes.insert(folder)
                }
            }
        }
        scheduleFolderRefresh()
    }

    private func scheduleFolderRefresh() {
        guard !pendingFolderRefreshes.isEmpty, refreshTask == nil, loadTask == nil, !isUpdatingFiles else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            guard self.loadTask == nil, !self.isUpdatingFiles else { return }

            let folders = self.pendingFolderRefreshes
            self.pendingFolderRefreshes.removeAll()
            if folders.contains(self.directory) {
                self.reload(quietly: true)
            } else {
                for folder in folders where self.expandedFolders[folder] != nil {
                    self.loadExpandedFolder(folder, includeHidden: self.showsHidden)
                }
            }
        }
    }

    func trashItems(_ items: Set<URL>) {
        let chosen = urls(for: items)
        guard !chosen.isEmpty else { return }
        updateFiles { try LocalFileOperations.trash(chosen) }
    }

    func beginEditing(_ request: BrowserEdit) {
        guard !isUpdatingFiles, request != .createFolder || !showsRecentItems else { return }
        switch request {
        case .createFolder: editText = L10n.text("未命名資料夾")
        case .rename(let item): editText = item.lastPathComponent
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

    private func updateFiles(operation: @escaping @Sendable () throws -> Void) {
        guard !isUpdatingFiles else { return }
        let origin = destination
        isUpdatingFiles = true
        openError = nil
        Task { [weak self] in
            let error = await Task.detached(priority: .userInitiated) {
                do { try operation(); return nil as String? }
                catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            self.isUpdatingFiles = false
            if self.destination == origin { self.reload() }
            self.openError = error
        }
    }

    func reload() { reload(quietly: false) }

    func reload(quietly: Bool) {
        cancelActivationRefresh()
        loadTask?.cancel()
        let target = destination
        let includeHidden = showsHidden
        let tracksRecentItems = target == .recentItems && contentMonitoringEnabled
        if !quietly {
            isLoading = true
            readError = nil
            openError = nil
        }

        loadTask = Task { [weak self] in
            defer {
                if let self, !Task.isCancelled {
                    self.loadTask = nil
                    self.scheduleFolderRefresh()
                }
            }
            do {
                if tracksRecentItems {
                    try Task.checkCancellation()
                    for try await files in RecentFileSearch.updates(includeHidden: includeHidden) {
                        try Task.checkCancellation()
                        guard let self else { return }
                        self.applyLoadedFiles(files, includeHidden: includeHidden)
                    }
                } else {
                    let files = try await Self.readContents(at: target, includeHidden: includeHidden)
                    try Task.checkCancellation()
                    self?.applyLoadedFiles(files, includeHidden: includeHidden)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.entries = []
                self?.hasLoadedContents = false
                self?.pruneExpandedFolders()
                self?.readError = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    private func applyLoadedFiles(_ files: [FileEntry], includeHidden: Bool) {
        if entries != files { entries = files }
        hasLoadedContents = true
        readError = nil
        pruneExpandedFolders()
        for expanded in Array(expandedFolders.keys) {
            loadExpandedFolder(expanded, includeHidden: includeHidden)
        }
        isLoading = false
    }

    private func loadExpandedFolder(_ folder: URL, includeHidden: Bool) {
        folderTasks[folder]?.cancel()
        folderTasks[folder] = Task { [weak self] in
            do {
                let children = try await Self.readContents(of: folder, includeHidden: includeHidden)
                try Task.checkCancellation()
                guard let self, self.expandedFolders[folder] != nil else { return }
                self.folderTasks[folder] = nil
                self.expandedFolders[folder] = children
                self.pruneExpandedFolders()
            } catch {
                guard !Task.isCancelled, let self, self.expandedFolders[folder] != nil else { return }
                self.folderTasks[folder] = nil
                self.expandedFolders[folder] = nil
                self.inlineExpansions.remove(folder)
                if let index = self.columnPath.firstIndex(of: folder) {
                    self.columnPath.removeSubrange(index...)
                }
                self.openError = L10n.text("無法展開「%@」：%@", String(describing: self.name(for: folder)), String(describing: error.localizedDescription))
                self.pruneExpandedFolders()
            }
        }
    }

    private func pruneExpandedFolders() {
        let listEntries = listedEntries(from: entries)
        if !inlineExpansions.isEmpty {
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
            folderTasks.removeValue(forKey: folder)?.cancel()
            expandedFolders[folder] = nil
        }
        if !selection.isEmpty {
            let reachable = hadColumnPath ? activeColumn.flatMap { expandedFolders[$0] } ?? columnRoots : listEntries
            selection.formIntersection(reachable.lazy.map(\.url))
        }
    }

    func enableFileIcons() {
        if !fileIconsEnabled { fileIconsEnabled = true }
    }

    private func load(_ target: Destination) {
        if showsRecentItems != (target == .recentItems) { tableSort = nil }
        if case .folder(let folder) = target { lastFolder = folder }
        destination = target
        entries = []
        hasLoadedContents = false
        columnPath = []
        activeColumn = nil
        pruneExpandedFolders()
        editing = nil
        filter = ""
        updateFolderMonitoring()
        onDirectoryChange?()
        reload()
    }

    nonisolated static func readContents(of folder: URL, includeHidden: Bool) async throws -> [FileEntry] {
        try await readContents(at: .folder(folder), includeHidden: includeHidden)
    }

    private nonisolated static func readContents(at destination: Destination, includeHidden: Bool) async throws -> [FileEntry] {
        let reader = Task.detached(priority: .userInitiated) {
            switch destination {
            case .folder(let folder): try read(folder, includeHidden: includeHidden)
            case .recentItems: try RecentFileSearch.read(includeHidden: includeHidden)
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
