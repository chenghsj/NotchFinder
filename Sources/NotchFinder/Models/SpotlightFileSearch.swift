import CoreServices
import Foundation
import UniformTypeIdentifiers

enum SpotlightFileSearch {
    enum Scope: Equatable, Sendable {
        case recents, tag(String)
    }

    private static let fallbackRecentsPredicate = """
        (kMDItemLastUsedDate = "*") && (
            (kMDItemContentTypeTree = public.content) ||
            (kMDItemContentTypeTree = "com.microsoft.*"cdw) ||
            (kMDItemContentTypeTree = public.archive)
        )
        """
    private static let finderRecentsPredicate: String = {
        let savedSearch = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Resources")
            .appending(path: "MyLibraries/myDocuments.cannedSearch/Resources/search.savedSearch")
        guard let data = try? Data(contentsOf: savedSearch),
              let search = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let predicate = search["RawQuery"] as? String, !predicate.isEmpty else {
            return fallbackRecentsPredicate
        }
        return predicate
    }()

    static func read(in scope: Scope, includeHidden: Bool) throws -> [FileEntry] {
        let query = try makeQuery(in: scope)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { MDQueryStop(query) }
        return try readResults(of: query, in: scope, includeHidden: includeHidden)
    }

    static func updates(in scope: Scope, includeHidden: Bool) -> AsyncThrowingStream<[FileEntry], Error> {
        let (stream, continuation) = AsyncThrowingStream<[FileEntry], Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let search = LiveQuery(scope: scope, includeHidden: includeHidden, continuation: continuation)
        continuation.onTermination = { _ in search.stop() }
        search.start()
        return stream
    }

    private static func makeQuery(in scope: Scope) throws -> MDQuery {
        switch scope {
        case .recents:
            let sortFields = [kMDItemLastUsedDate] as CFArray
            guard let query = MDQueryCreate(nil, finderRecentsPredicate as CFString, nil, sortFields)
                    ?? MDQueryCreate(nil, fallbackRecentsPredicate as CFString, nil, sortFields),
                  MDQuerySetSortOptionFlagsForAttribute(query, kMDItemLastUsedDate,
                                                       kMDQueryReverseSortOrderFlag.rawValue) else {
                throw CocoaError(.fileReadUnknown)
            }
            MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
            return query
        case .tag(let name):
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "?", with: "\\?")
            let predicate = "kMDItemUserTags == \"\(escaped)\""
            guard let query = MDQueryCreate(nil, predicate as CFString, nil, nil) else {
                throw CocoaError(.fileReadUnknown)
            }
            MDQuerySetSearchScope(query, [kMDQueryScopeAllIndexed] as CFArray, 0)
            return query
        }
    }

    private static func readResults(of query: MDQuery, in scope: Scope, includeHidden: Bool) throws -> [FileEntry] {
        let keys: [CFString] = [
            kMDItemPath, kMDItemDisplayName, kMDItemKind, kMDItemContentType, kMDItemFSSize,
            kMDItemFSContentChangeDate, kMDItemDateAdded, kMDItemLastUsedDate, kMDItemFSInvisible
        ]
        let manager = FileManager.default
        let dataVolumePrefix = "/System/Volumes/Data"
        let dataVolumePath = if scope == .recents {
            dataVolumePrefix + manager.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        } else {
            dataVolumePrefix + "/"
        }
        // Finder's saved search limits results to user files. Keep cloud storage inside Library.
        let libraryPath = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
            .map { $0.standardizedFileURL.path + "/" }
        var seen: Set<URL> = []
        let files = try (0..<MDQueryGetResultCount(query)).compactMap { index -> FileEntry? in
            try Task.checkCancellation()
            guard let pointer = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue()
            guard let values = MDItemCopyAttributes(item, keys as CFArray) as? [String: Any],
                  let path = values[kMDItemPath as String] as? String,
                  path.hasPrefix("/") else { return nil }
            let filePath = path.hasPrefix(dataVolumePath) ? String(path.dropFirst(dataVolumePrefix.count)) : path
            let lastUsed = values[kMDItemLastUsedDate as String] as? Date
            if scope == .recents {
                guard lastUsed != nil else { return nil }
                if let libraryPath, filePath.hasPrefix(libraryPath),
                   !filePath.hasPrefix(libraryPath + "CloudStorage/"),
                   !filePath.hasPrefix(libraryPath + "Mobile Documents/") { return nil }
            }
            var url = URL(fileURLWithPath: filePath, isDirectory: false).standardizedFileURL
            let hidden = values[kMDItemFSInvisible as String] as? Bool == true
                || url.pathComponents.contains { $0.hasPrefix(".") }
            guard includeHidden || !hidden, seen.insert(url).inserted else { return nil }
            let isLink = values[kMDItemContentType as String] as? String == UTType.symbolicLink.identifier
            let isFolder: Bool
            if case .tag = scope {
                let target = isLink ? url.resolvingSymlinksInPath() : url
                let properties = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                isFolder = properties?.isDirectory == true && properties?.isPackage == false
                if isFolder { url = URL(fileURLWithPath: filePath, isDirectory: true).standardizedFileURL }
            } else {
                isFolder = false
            }

            return FileEntry(
                url: url,
                name: values[kMDItemDisplayName as String] as? String ?? url.lastPathComponent,
                isFolder: isFolder,
                isSymbolicLink: isLink,
                fileKind: isFolder ? .folder :
                    (values[kMDItemKind as String] as? String).map(FileEntry.FileKind.systemDescription) ?? .file,
                fileSize: isFolder ? -1 : (values[kMDItemFSSize as String] as? NSNumber)?.int64Value ?? -1,
                modified: values[kMDItemFSContentChangeDate as String] as? Date ?? .distantPast,
                added: values[kMDItemDateAdded as String] as? Date ?? .distantPast,
                lastUsed: lastUsed ?? .distantPast
            )
        }
        guard case .tag = scope else { return files }
        return files.sorted { first, second in
            if first.isFolder != second.isFolder { return first.isFolder }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    // The query, observer tokens, and result snapshots are confined to this serial queue.
    private final class LiveQuery: @unchecked Sendable {
        private let queue = DispatchQueue(label: "local.notchfinder.spotlight-search", qos: .userInitiated)
        private let scope: Scope
        private let includeHidden: Bool
        private let continuation: AsyncThrowingStream<[FileEntry], Error>.Continuation
        private var query: MDQuery?
        private var observers: [NSObjectProtocol] = []

        init(scope: Scope, includeHidden: Bool, continuation: AsyncThrowingStream<[FileEntry], Error>.Continuation) {
            self.scope = scope
            self.includeHidden = includeHidden
            self.continuation = continuation
        }

        func start() {
            queue.async { [self] in
                do {
                    let query = try SpotlightFileSearch.makeQuery(in: scope)
                    self.query = query
                    MDQuerySetDispatchQueue(query, self.queue)
                    let names = [kMDQueryDidFinishNotification as String, kMDQueryDidUpdateNotification as String]
                    self.observers = names.map { [self] name in
                        NotificationCenter.default.addObserver(forName: .init(name), object: query, queue: nil) {
                            [weak self] _ in self?.publishResults()
                        }
                    }
                    guard MDQueryExecute(query, CFOptionFlags(kMDQueryWantsUpdates.rawValue)) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                } catch {
                    self.continuation.finish(throwing: error)
                }
            }
        }

        func stop() {
            queue.async {
                for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
                self.observers.removeAll()
                if let query = self.query { MDQueryStop(query) }
                self.query = nil
            }
        }

        private func publishResults() {
            guard let query else { return }
            MDQueryDisableUpdates(query)
            defer { MDQueryEnableUpdates(query) }
            do {
                continuation.yield(try SpotlightFileSearch.readResults(of: query, in: scope, includeHidden: includeHidden))
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
