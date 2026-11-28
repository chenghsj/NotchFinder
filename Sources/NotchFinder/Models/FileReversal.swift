import Darwin
import Foundation

struct FileReversal: Sendable {
    private enum Action: Sendable {
        case move(to: URL)
        case trash(emptyFolderOnly: Bool)
        case restore(to: URL, emptyFolderOnly: Bool)
    }

    struct MissingItem: LocalizedError {
        let errorDescription: String?

        init(_ url: URL) {
            errorDescription = L10n.text("「%@」已移動、刪除或替換", url.lastPathComponent)
        }
    }

    private struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let createdSeconds: Int
        let createdNanoseconds: Int

        init(at url: URL) throws {
            var info = stat()
            try url.withUnsafeFileSystemRepresentation { path in
                guard let path else { throw CocoaError(.fileReadInvalidFileName) }
                guard lstat(path, &info) == 0 else {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                    if code == .ENOENT || code == .ENOTDIR { throw MissingItem(url) }
                    throw POSIXError(code)
                }
            }
            device = info.st_dev
            inode = info.st_ino
            createdSeconds = info.st_birthtimespec.tv_sec
            createdNanoseconds = info.st_birthtimespec.tv_nsec
        }

        func matches(_ other: Self, on device: dev_t) -> Bool {
            other.device == device && inode == other.inode &&
                createdSeconds == other.createdSeconds && createdNanoseconds == other.createdNanoseconds
        }
    }

    private struct Volume: Sendable {
        private static let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeUUIDStringKey]
        let root: URL
        let uuid: String?

        init?(containing item: URL) {
            guard let values = try? item.resourceValues(forKeys: Self.keys), let root = values.volume else { return nil }
            self.root = root.resolvingSymlinksInPath().standardizedFileURL
            uuid = values.volumeUUIDString
        }

        func mountedDevice(previousDevice: dev_t) throws -> dev_t {
            let freshRoot = URL(fileURLWithPath: root.path, isDirectory: true)
            guard let current = Self(containing: freshRoot), current.root.path == root.path,
                  let identity = try? Identity(at: freshRoot),
                  uuid.map({ $0 == current.uuid }) ?? (identity.device == previousDevice) else {
                let name = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
                throw LocalFileOperations.Failure(L10n.text("磁碟「%@」目前無法使用", name))
            }
            return identity.device
        }
    }

    let item: URL
    private let identity: Identity?
    private let volume: Volume?
    private let action: Action

    private init(item: URL, action: Action, previousIdentity: Identity? = nil) {
        self.item = item
        identity = (try? Identity(at: item)) ?? previousIdentity
        volume = Volume(containing: item.deletingLastPathComponent())
        self.action = action
    }

    static func move(_ item: URL, to destination: URL) throws -> Self {
        let identity = try? Identity(at: item)
        try FileManager.default.moveItem(at: item, to: destination)
        return Self(item: destination, action: .move(to: item), previousIdentity: identity)
    }

    static func removeNewItem(_ item: URL, emptyFolderOnly: Bool = false) -> Self {
        Self(item: item, action: .trash(emptyFolderOnly: emptyFolderOnly))
    }

    static func trash(_ item: URL) throws -> Self {
        try trash(item, emptyFolderOnly: false, identity: try? Identity(at: item))
    }

    private static func trash(_ item: URL, emptyFolderOnly: Bool, identity: Identity?) throws -> Self {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: item, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw LocalFileOperations.Failure(L10n.text("「%@」已移到垃圾桶，但無法取得其位置", item.lastPathComponent))
        }
        return Self(item: resultingURL as URL, action: .restore(to: item, emptyFolderOnly: emptyFolderOnly),
                    previousIdentity: identity)
    }

    func reverse() throws -> Self {
        guard let identity else { throw MissingItem(item) }
        let current: Identity
        do {
            current = try Identity(at: item)
        } catch let error as MissingItem {
            _ = try volume?.mountedDevice(previousDevice: identity.device)
            throw error
        }
        if current != identity {
            // A remount can assign a new device number to the same volume.
            guard let device = try volume?.mountedDevice(previousDevice: identity.device),
                  identity.matches(current, on: device) else { throw MissingItem(item) }
        }

        switch action {
        case .move(let destination):
            return try Self.move(item, to: destination)
        case .trash(let emptyFolderOnly):
            if emptyFolderOnly, try !FileManager.default.contentsOfDirectory(atPath: item.path).isEmpty {
                throw LocalFileOperations.Failure(L10n.text("「%@」已包含項目，無法復原新增資料夾", item.lastPathComponent))
            }
            return try Self.trash(item, emptyFolderOnly: emptyFolderOnly, identity: current)
        case .restore(let destination, let emptyFolderOnly):
            try FileManager.default.moveItem(at: item, to: destination)
            return Self(item: destination, action: .trash(emptyFolderOnly: emptyFolderOnly), previousIdentity: current)
        }
    }
}
