import CoreServices
import Foundation
import UniformTypeIdentifiers

enum RecentFileSearch {
    private static let fallbackPredicate = """
        (kMDItemLastUsedDate = "*") && (
            (kMDItemContentTypeTree = public.content) ||
            (kMDItemContentTypeTree = "com.microsoft.*"cdw) ||
            (kMDItemContentTypeTree = public.archive)
        )
        """
    private static let finderPredicate: String = {
        let savedSearch = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Resources")
            .appending(path: "MyLibraries/myDocuments.cannedSearch/Resources/search.savedSearch")
        guard let data = try? Data(contentsOf: savedSearch),
              let search = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let predicate = search["RawQuery"] as? String, !predicate.isEmpty else {
            return fallbackPredicate
        }
        return predicate
    }()

    static func read(includeHidden: Bool) throws -> [FileEntry] {
        let query = try makeQuery()
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { MDQueryStop(query) }
        return try readResults(of: query, includeHidden: includeHidden)
    }

    static func updates(includeHidden: Bool) -> AsyncThrowingStream<[FileEntry], Error> {
        let (stream, continuation) = AsyncThrowingStream<[FileEntry], Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let search = LiveQuery(includeHidden: includeHidden, continuation: continuation)
        continuation.onTermination = { _ in search.stop() }
        search.start()
        return stream
    }

    private static func makeQuery() throws -> MDQuery {
        let sortFields = [kMDItemLastUsedDate] as CFArray
        guard let query = MDQueryCreate(nil, finderPredicate as CFString, nil, sortFields)
                ?? MDQueryCreate(nil, fallbackPredicate as CFString, nil, sortFields),
              MDQuerySetSortOptionFlagsForAttribute(query, kMDItemLastUsedDate,
                                                   kMDQueryReverseSortOrderFlag.rawValue) else {
            throw CocoaError(.fileReadUnknown)
        }
        MDQuerySetSearchScope(query, [kMDQueryScopeHome] as CFArray, 0)
        return query
    }

    private static func readResults(of query: MDQuery, includeHidden: Bool) throws -> [FileEntry] {
        let keys: [CFString] = [
            kMDItemPath, kMDItemDisplayName, kMDItemKind, kMDItemContentType, kMDItemFSSize,
            kMDItemFSContentChangeDate, kMDItemDateAdded, kMDItemLastUsedDate, kMDItemFSInvisible
        ]
        let manager = FileManager.default
        let dataVolumePrefix = "/System/Volumes/Data"
        let indexedHomePath = dataVolumePrefix + manager.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        // Finder's saved search limits results to user files. Keep cloud storage inside Library.
        let libraryPath = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
            .map { $0.standardizedFileURL.path + "/" }
        var seen: Set<URL> = []
        return try (0..<MDQueryGetResultCount(query)).compactMap { index in
            try Task.checkCancellation()
            guard let pointer = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue()
            guard let values = MDItemCopyAttributes(item, keys as CFArray) as? [String: Any],
                  let path = values[kMDItemPath as String] as? String,
                  path.hasPrefix("/"),
                  let used = values[kMDItemLastUsedDate as String] as? Date else { return nil }
            let filePath = path.hasPrefix(indexedHomePath) ? String(path.dropFirst(dataVolumePrefix.count)) : path
            let url = URL(fileURLWithPath: filePath, isDirectory: false).standardizedFileURL
            if let libraryPath, filePath.hasPrefix(libraryPath),
               !filePath.hasPrefix(libraryPath + "CloudStorage/"),
               !filePath.hasPrefix(libraryPath + "Mobile Documents/") { return nil }
            let hidden = values[kMDItemFSInvisible as String] as? Bool == true
                || url.pathComponents.contains { $0.hasPrefix(".") }
            guard includeHidden || !hidden, seen.insert(url).inserted else { return nil }

            return FileEntry(
                url: url,
                name: values[kMDItemDisplayName as String] as? String ?? url.lastPathComponent,
                isFolder: false,
                isSymbolicLink: values[kMDItemContentType as String] as? String == UTType.symbolicLink.identifier,
                fileKind: (values[kMDItemKind as String] as? String).map(FileEntry.FileKind.systemDescription) ?? .file,
                fileSize: (values[kMDItemFSSize as String] as? NSNumber)?.int64Value ?? -1,
                modified: values[kMDItemFSContentChangeDate as String] as? Date ?? .distantPast,
                added: values[kMDItemDateAdded as String] as? Date ?? .distantPast,
                lastUsed: used
            )
        }
    }

    // The query, observer tokens, and result snapshots are confined to this serial queue.
    private final class LiveQuery: @unchecked Sendable {
        private let queue = DispatchQueue(label: "local.notchfinder.recent-items", qos: .userInitiated)
        private let includeHidden: Bool
        private let continuation: AsyncThrowingStream<[FileEntry], Error>.Continuation
        private var query: MDQuery?
        private var observers: [NSObjectProtocol] = []

        init(includeHidden: Bool, continuation: AsyncThrowingStream<[FileEntry], Error>.Continuation) {
            self.includeHidden = includeHidden
            self.continuation = continuation
        }

        func start() {
            queue.async { [self] in
                do {
                    let query = try RecentFileSearch.makeQuery()
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
                continuation.yield(try RecentFileSearch.readResults(of: query, includeHidden: includeHidden))
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
