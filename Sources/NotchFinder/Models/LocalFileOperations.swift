import Darwin
import Foundation

enum LocalFileOperations {
    struct Failure: LocalizedError {
        let errorDescription: String?
        let reversals: [FileReversal]
        let trashRecovery: TrashRemovalRequest?

        init(_ message: String, reversals: [FileReversal] = [], trashRecovery: TrashRemovalRequest? = nil) {
            errorDescription = message
            self.reversals = reversals
            self.trashRecovery = trashRecovery
        }
    }

    static func checkedName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw Failure(L10n.text("請輸入有效的名稱"))
        }
        return name
    }

    static func createFolder(named name: String, in folder: URL) throws -> [FileReversal] {
        let destination = folder.appendingPathComponent(try checkedName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return [.removeNewItem(destination, emptyFolderOnly: true)]
    }

    static func rename(_ item: URL, to name: String) throws -> [FileReversal] {
        let name = try checkedName(name)
        guard name != item.lastPathComponent else { return [] }
        let directory = item.deletingLastPathComponent()
        let destination = directory.appendingPathComponent(name, isDirectory: item.hasDirectoryPath)
        return [try .move(item, to: destination)]
    }

    static func copy(_ items: [URL], into folder: URL) throws -> [FileReversal] {
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return try perform(items, verb: L10n.text("複製")) { source in
            let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedFolder != resolvedSource,
                  !resolvedFolder.hasPrefix(resolvedSource == "/" ? "/" : resolvedSource + "/") else {
                throw Failure(L10n.text("無法將資料夾複製到自己裡面"))
            }
            return try copyItem(source, into: folder)
        }
    }

    @discardableResult
    static func drop(_ items: [URL], into folder: URL, copies: Bool) throws -> [FileReversal] {
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        let folderValues = try folder.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeURLKey])
        var ancestorIdentifiers: [any NSObjectProtocol] = []
        var ancestor = folder
        while true {
            if let identifier = try ancestor.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
                ancestorIdentifiers.append(identifier)
            }
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }

        return try perform(topLevelSources(items), verb: L10n.text("放入資料夾")) { source in
            let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let parentValues = try parent.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeURLKey])
            let sameParent = parent.path == folder.path ||
                folderValues.fileResourceIdentifier?.isEqual(parentValues.fileResourceIdentifier) == true
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey])
            if values.isDirectory == true && values.isSymbolicLink != true {
                let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
                let isAncestor = ancestorIdentifiers.contains { $0.isEqual(values.fileResourceIdentifier) }
                guard !isAncestor, folder.path != resolvedSource,
                      !folder.path.hasPrefix(resolvedSource == "/" ? "/" : resolvedSource + "/") else {
                    throw Failure(L10n.text("無法將資料夾放入自己或其子資料夾"))
                }
            }

            if sameParent {
                return copies ? try copyItem(source, into: folder, duplicate: true) : nil
            }
            if !copies, let volume = folderValues.volume, volume == parentValues.volume {
                let destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: source.hasDirectoryPath)
                return try .move(source, to: destination)
            }
            return try copyItem(source, into: folder)
        }
    }

    private static func copyItem(_ source: URL, into folder: URL, duplicate: Bool = false) throws -> FileReversal {
        let manager = FileManager.default
        let name = source.lastPathComponent
        let destination = folder.appendingPathComponent(name, isDirectory: source.hasDirectoryPath)
        if !duplicate, manager.fileExists(atPath: destination.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }

        // An interrupted recursive copy can leave a partial tree. Publish only the completed item.
        let staging = folder.appendingPathComponent(".notchfinder-copy-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let draft = staging.appendingPathComponent("item", isDirectory: source.hasDirectoryPath)
        let copy = Result {
            try manager.copyItem(at: source, to: draft)
            return try publishCopy(draft, to: destination, duplicate: duplicate)
        }
        do {
            try removeCopyStaging(staging)
        } catch {
            let cleanupError = "\(staging.path): \(error.localizedDescription)"
            switch copy {
            case .success(let change):
                throw Failure(cleanupError, reversals: [change])
            case .failure(let failure):
                throw Failure(failure.localizedDescription + "\n" + cleanupError, reversals: (failure as? Failure)?.reversals ?? [])
            }
        }
        return try copy.get()
    }

    private static func publishCopy(_ draft: URL, to destination: URL, duplicate: Bool) throws -> FileReversal {
        // Keep the descriptor across the rename so the lock is restored on the copied inode.
        let descriptor = open(draft.path, O_EVTONLY | O_SYMLINK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let unlocked = info.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND)
        if unlocked != info.st_flags, fchflags(descriptor, unlocked) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var number = 2
        while true {
            let target = duplicate
                ? destination.deletingLastPathComponent().appendingPathComponent(
                    duplicateName(for: destination.lastPathComponent, number: number), isDirectory: destination.hasDirectoryPath)
                : destination
            do {
                try moveWithoutReplacing(draft, to: target)
                let reversal = FileReversal.removeNewItem(target)
                if unlocked != info.st_flags, fchflags(descriptor, info.st_flags) != 0 {
                    let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    throw Failure(error.localizedDescription, reversals: [reversal])
                }
                return reversal
            } catch let error as CocoaError where duplicate && error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }

    private static func removeCopyStaging(_ staging: URL) throws {
        let manager = FileManager.default
        do { try manager.removeItem(at: staging) }
        catch {
            // A partial copy can include read-only directories and locked descendants.
            func unlock(_ path: String) throws {
                var info = stat()
                guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let flags = info.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND)
                if flags != info.st_flags, lchflags(path, flags) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard info.st_mode & S_IFMT == S_IFDIR else { return }
                if info.st_mode & 0o700 != 0o700, chmod(path, info.st_mode | 0o700) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                for name in try manager.contentsOfDirectory(atPath: path) { try unlock(path + "/" + name) }
            }
            try unlock(staging.path)
            try manager.removeItem(at: staging)
        }
    }

    private static func duplicateName(for name: String, number: Int) -> String {
        var stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = ext.isEmpty ? " \(number)" : " \(number).\(ext)"
        if suffix.utf8.count >= Int(NAME_MAX) {
            stem = name
            suffix = " \(number)"
        }
        while stem.utf8.count + suffix.utf8.count > Int(NAME_MAX) { stem.removeLast() }
        return stem + suffix
    }

    static func moveWithoutReplacing(_ source: URL, to destination: URL) throws {
        let code = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        switch code {
        case 0: return
        case EEXIST: throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        case ENOTSUP: try FileManager.default.moveItem(at: source, to: destination)
        default: throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    static func compress(_ items: [URL]) throws -> [FileReversal] {
        let sources = topLevelSources(items)
        guard let first = sources.first else { return [] }
        let folder = first.deletingLastPathComponent()
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard sources.allSatisfy({ source in
            source.path != "/" &&
                source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == resolvedFolder
        }) else {
            throw Failure(L10n.text("請選擇同一個資料夾內的項目來壓縮"))
        }

        let archive = try ZipArchive.create(in: folder, names: sources.map(\.lastPathComponent))
        return [.removeNewItem(archive)]
    }

    static func trash(_ items: [URL]) throws -> [FileReversal] {
        try perform(topLevelSources(items), verb: L10n.text("移到垃圾桶")) { try .trash($0) }
    }

    static func emptyTrash(at directory: URL, retrying request: TrashRemovalRequest? = nil, authorize: (TrashRemovalRequest) throws -> Void = {
        try $0.removeWithAdministratorPrivileges()
    }) throws {
        // Keep deletion rooted in the opened Trash even if its path changes during the operation.
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        var root = stat()
        guard fstat(descriptor, &root) == 0 else { throw POSIXError(.EIO) }
        let items: [(name: String, expectedInode: ino_t?)]
        if let request {
            guard directory.standardizedFileURL == request.directory.standardizedFileURL,
                  root.st_dev == request.device, root.st_ino == request.inode else { throw POSIXError(.ESTALE) }
            items = try request.remainingItems().map { ($0.name, $0.inode) }
        } else {
            items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .map { ($0.lastPathComponent, nil) }
        }
        var snapshot: [TrashRemovalRequest.Item] = []
        var failures: [String] = []
        for (name, expectedInode) in items {
            var info = stat()
            let code: Int32
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                code = errno
            } else if info.st_dev != root.st_dev {
                code = EBUSY
            } else {
                if expectedInode == nil || expectedInode == info.st_ino {
                    snapshot.append(.init(name: name, inode: info.st_ino))
                }
                continue
            }
            if code != ENOENT {
                let error = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                failures.append("\(name)（\(error.localizedDescription)）")
            }
        }
        let removal = TrashRemovalRequest(directory: directory, device: root.st_dev, inode: root.st_ino, items: snapshot)
        var deniedNames: Set<String> = []
        for failure in try removal.remove() {
            if failure.code == EACCES || failure.code == EPERM { deniedNames.insert(failure.name) }
            else { failures.append("\(failure.name)（\(failure.message)）") }
        }
        let denied = snapshot.filter { deniedNames.contains($0.name) }

        if !denied.isEmpty {
            let request = TrashRemovalRequest(directory: directory, device: root.st_dev, inode: root.st_ino, items: denied)
            do { try authorize(request) }
            catch let error as Failure {
                failures.append(error.localizedDescription)
                throw Failure(failures.joined(separator: "\n"), trashRecovery: error.trashRecovery)
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw Failure(failures.joined(separator: "\n")) }
    }

    private static func topLevelSources(_ items: [URL]) -> [URL] {
        var seen: Set<String> = []
        var folders: Set<String> = []
        var sources: [(url: URL, parent: URL)] = []
        for source in items where source.isFileURL && source.path.hasPrefix("/") {
            // Resolve parent aliases without following a selected symbolic link itself.
            let parent = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let path = parent.appendingPathComponent(source.lastPathComponent).path
            guard seen.insert(path).inserted else { continue }
            sources.append((source, parent))
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true { folders.insert(path) }
        }
        guard !folders.isEmpty else { return sources.map(\.url) }
        return sources.compactMap { source, parent in
            var ancestor = parent
            while ancestor.path != "/" {
                if folders.contains(ancestor.path) { return nil }
                ancestor.deleteLastPathComponent()
            }
            return source
        }
    }

    private static func perform(_ items: [URL], verb: String, action: (URL) throws -> FileReversal?) throws -> [FileReversal] {
        var reversals: [FileReversal] = []
        var failures: [String] = []
        for item in items {
            do {
                if let reversal = try action(item) { reversals.append(reversal) }
            } catch {
                if let failure = error as? Failure { reversals.append(contentsOf: failure.reversals) }
                failures.append("\(item.lastPathComponent)（\(error.localizedDescription)）")
            }
        }
        if !failures.isEmpty {
            let message = L10n.text("有 %@ 個項目無法%@\n", String(describing: failures.count), verb)
            throw Failure(message + failures.joined(separator: "\n"), reversals: reversals)
        }
        return reversals
    }
}
