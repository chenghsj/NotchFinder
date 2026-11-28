import Foundation
import Observation

@MainActor
@Observable
final class BrowserContentRefresh {
    enum Revalidation {
        case immediately, quietly, afterDelay
    }

    enum Change {
        case loading, paused
        case root(Result<[FileEntry], Error>)
        case folder(URL, Result<[FileEntry], Error>)
    }

    @MainActor
    struct Source {
        var read: @MainActor (FileBrowser.Destination, Bool) async throws -> [FileEntry]
        var searchUpdates: @MainActor (SpotlightFileSearch.Scope, Bool) -> AsyncThrowingStream<[FileEntry], Error>

        static let live = Self(read: FileBrowser.readContents(at:includeHidden:),
                               searchUpdates: SpotlightFileSearch.updates(in:includeHidden:))
    }

    private(set) var loadingFolders: Set<URL> = []
    @ObservationIgnored private let source: Source
    @ObservationIgnored private let deliver: (Change) -> Void
    @ObservationIgnored private var destination: FileBrowser.Destination
    @ObservationIgnored private var includeHidden: Bool
    @ObservationIgnored private var active = false
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private let fileOperationInProgress: () -> Bool
    @ObservationIgnored private var expandedFolders: Set<URL> = []
    @ObservationIgnored private var folderMonitor: FolderChangeMonitor?
    @ObservationIgnored private var watchedFolders: Set<URL> = []
    @ObservationIgnored private var watchID: UUID?
    @ObservationIgnored private var pendingFolders: Set<URL> = []
    @ObservationIgnored private var rootTask: Task<Void, Never>?
    @ObservationIgnored private var folderTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(destination: FileBrowser.Destination, includeHidden: Bool, source: Source,
         fileOperationInProgress: @escaping () -> Bool, deliver: @escaping (Change) -> Void) {
        self.destination = destination
        self.includeHidden = includeHidden
        self.source = source
        self.fileOperationInProgress = fileOperationInProgress
        self.deliver = deliver
    }

    deinit {
        rootTask?.cancel()
        catchUpTask?.cancel()
        refreshTask?.cancel()
        folderTasks.values.forEach { $0.cancel() }
    }

    func setActive(_ active: Bool, includeHidden: Bool, revalidation: Revalidation) {
        guard active != self.active else { return }
        self.active = active
        guard active else {
            stopWatching()
            cancelReads()
            deliver(.paused)
            return
        }

        let hiddenItemsChanged = self.includeHidden != includeHidden
        self.includeHidden = includeHidden
        updateWatch()
        if revalidation == .immediately || hiddenItemsChanged || destination.spotlightSearch != nil || (!hasLoaded && rootTask == nil) {
            reload()
        } else if revalidation == .quietly {
            reload(quietly: hasLoaded)
        } else {
            // A quickly cycled tab can display its cached listing without starting a new read.
            catchUpTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await self?.rootTask?.value
                guard let self, !Task.isCancelled else { return }
                catchUpTask = nil
                reload(quietly: hasLoaded)
            }
        }
    }

    func navigate(to destination: FileBrowser.Destination) {
        stopWatching()
        cancelReads()
        self.destination = destination
        hasLoaded = false
        updateWatch()
        reload()
    }

    func setIncludesHidden(_ value: Bool) {
        includeHidden = value
        reload()
    }

    func reload(quietly: Bool = false) {
        cancelReads()
        let target = destination
        let includeHidden = includeHidden
        let liveSearch = active ? target.spotlightSearch : nil
        if !quietly { deliver(.loading) }

        rootTask = Task { [weak self, source] in
            defer {
                if let self, !Task.isCancelled {
                    rootTask = nil
                    scheduleRefresh()
                }
            }
            do {
                try Task.checkCancellation()
                if let liveSearch {
                    for try await files in source.searchUpdates(liveSearch, includeHidden) {
                        try Task.checkCancellation()
                        self?.applyRoot(.success(files))
                    }
                } else {
                    let files = try await source.read(target, includeHidden)
                    try Task.checkCancellation()
                    self?.applyRoot(.success(files))
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyRoot(.failure(error))
            }
        }
    }

    func expand(_ folder: URL) {
        expandedFolders.insert(folder)
        updateWatch()
        readExpandedFolder(folder)
    }

    func retainExpandedFolders(_ folders: Set<URL>) {
        for folder in expandedFolders.subtracting(folders) {
            folderTasks.removeValue(forKey: folder)?.cancel()
            loadingFolders.remove(folder)
            pendingFolders.remove(folder)
        }
        expandedFolders = folders
        updateWatch()
    }

    private func cancelReads() {
        catchUpTask?.cancel()
        catchUpTask = nil
        rootTask?.cancel()
        rootTask = nil
        for task in folderTasks.values { task.cancel() }
        folderTasks.removeAll()
        if !loadingFolders.isEmpty { loadingFolders.removeAll() }
    }

    private func applyRoot(_ result: Result<[FileEntry], Error>) {
        switch result {
        case .success:
            hasLoaded = true
            deliver(.root(result))
            for folder in expandedFolders { readExpandedFolder(folder) }
        case .failure:
            hasLoaded = false
            deliver(.root(result))
        }
    }

    private func readExpandedFolder(_ folder: URL) {
        folderTasks[folder]?.cancel()
        loadingFolders.insert(folder)
        let includeHidden = includeHidden
        folderTasks[folder] = Task { [weak self, source] in
            let result: Result<[FileEntry], Error>
            do {
                try Task.checkCancellation()
                result = .success(try await source.read(.folder(folder), includeHidden))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, expandedFolders.contains(folder) else { return }
            folderTasks[folder] = nil
            loadingFolders.remove(folder)
            deliver(.folder(folder, result))
        }
    }

    private func updateWatch() {
        guard active else { return }
        let roots: Set<URL> = switch destination {
        case .folder(let root): [root]
        case .tag: expandedFolders
        case .recentItems: []
        }
        guard roots != watchedFolders else { return }
        let retained = watchedFolders.intersection(roots)
        if roots.isEmpty {
            stopWatching()
            return
        }
        let id = UUID()
        folderMonitor = FolderChangeMonitor(directories: roots) { [weak self] paths, rescan in
            guard let self, watchID == id else { return }
            receiveFolderChanges(paths, rescan: rescan)
        }
        watchedFolders = folderMonitor == nil ? [] : roots
        watchID = folderMonitor == nil ? nil : id
        // Events still queued on the retired stream may not reach its callback.
        pendingFolders.formUnion(retained)
        scheduleRefresh()
    }

    private func stopWatching() {
        watchID = nil
        folderMonitor = nil
        watchedFolders = []
        refreshTask?.cancel()
        refreshTask = nil
        pendingFolders.removeAll()
    }

    private func receiveFolderChanges(_ paths: [String], rescan: Bool) {
        if rescan {
            pendingFolders.formUnion(watchedFolders)
        } else {
            var affected: Set<String> = []
            for path in paths {
                affected.insert(path)
                affected.insert((path as NSString).deletingLastPathComponent)
            }
            for folder in watchedFolders.union(expandedFolders) {
                let path = folder.resolvingSymlinksInPath().path
                // FSEvents can report the /private path of macOS system folders.
                let privatePath = "/private" + path
                if affected.contains(path) ||
                    (affected.contains(privatePath) &&
                     URL(fileURLWithPath: privatePath, isDirectory: true).resolvingSymlinksInPath().path == path) {
                    pendingFolders.insert(folder)
                }
            }
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !pendingFolders.isEmpty, refreshTask == nil, canRefreshFolders else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            refreshTask = nil
            guard canRefreshFolders else { return }
            let folders = pendingFolders
            pendingFolders.removeAll()
            if case .folder(let root) = destination, folders.contains(root) {
                reload(quietly: true)
            } else {
                for folder in folders.intersection(expandedFolders) { readExpandedFolder(folder) }
            }
        }
    }

    // A live Spotlight subscription stays open while its expanded directories change.
    private var canRefreshFolders: Bool {
        (rootTask == nil || destination.spotlightSearch != nil) && !fileOperationInProgress()
    }
}
