import Foundation

enum DiskImageInstall {
    struct Outcome: Sendable {
        let reversals: [FileReversal]
        let warning: String?
    }

    struct Image {
        let file: URL
        let device: String?
    }

    private struct ImageInfo: Decodable {
        let images: [MountedImage]

        struct MountedImage: Decodable {
            let path: String?
            let entities: [Entity]?

            enum CodingKeys: String, CodingKey {
                case path = "image-path"
                case entities = "system-entities"
            }

            var backingDevice: String? {
                // The image device precedes its partitions and synthesized APFS devices.
                entities?.lazy.compactMap(\.device).first {
                    $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil
                }
            }
        }

        struct Entity: Decodable {
            let mountPoint: String?
            let device: String?

            enum CodingKeys: String, CodingKey {
                case mountPoint = "mount-point"
                case device = "dev-entry"
            }
        }
    }

    static var applicationsDirectory: URL {
        FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
            ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
    }

    static func canInstall(_ source: URL, into directory: URL = applicationsDirectory) -> Bool {
        source.isFileURL && source.pathExtension.lowercased() == "app"
            && source.deletingLastPathComponent().standardizedFileURL.path != directory.standardizedFileURL.path
    }

    static func install(_ source: URL, into directory: URL = applicationsDirectory, cleanup: Bool) throws -> Outcome {
        let manager = FileManager.default
        guard canInstall(source, into: directory),
              let info = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              info.isDirectory == true, info.isSymbolicLink != true,
              Bundle(url: source)?.executableURL != nil else {
            throw LocalFileOperations.Failure(L10n.text("請選擇有效的 macOS 應用程式"))
        }

        let name = source.lastPathComponent
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        let cleanupCandidate = Result { () -> (Image, NSObject)? in
            guard cleanup, let volume = try? source.resourceValues(forKeys: [.volumeURLKey]).volume,
                  volume.path != "/",
                  let image = try mountedImage(at: volume, in: imageInfo()) else { return nil }
            return (image, try imageIdentifier(image.file))
        }

        var reversals: [FileReversal] = []
        if manager.fileExists(atPath: destination.path) {
            let info = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard try cleanupCandidate.get() != nil,
                  info?.isDirectory == true, info?.isSymbolicLink != true,
                  manager.contentsEqual(atPath: source.path, andPath: destination.path) else {
                throw LocalFileOperations.Failure(L10n.text("「應用程式」裡已有「%@」", String(describing: name)))
            }
        } else {
            let scratch = directory.appendingPathComponent(".notchfinder-install-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: scratch) }
            let draft = scratch.appendingPathComponent(name, isDirectory: true)
            try manager.copyItem(at: source, to: draft)
            try manager.moveItem(at: draft, to: destination)
            reversals.append(.removeNewItem(destination))
        }

        let warning: String?
        do {
            guard let (image, identifier) = try cleanupCandidate.get() else { return Outcome(reversals: reversals, warning: nil) }
            try eject(image, identifier: identifier)
            guard try mountedRecords(for: image.file, in: imageInfo()).isEmpty,
                  try imageIdentifier(image.file).isEqual(identifier) else {
                throw LocalFileOperations.Failure(L10n.text("無法確認安裝磁碟已退出或映像檔仍是同一個檔案"))
            }
            reversals.append(try .trash(image.file))
            warning = nil
        } catch {
            warning = L10n.text("已安裝「%@」，安裝磁碟清理未完成：%@", name, error.localizedDescription)
        }
        return Outcome(reversals: reversals, warning: warning)
    }

    static func ejectMountedImage(at volume: URL) throws -> Bool {
        guard let data = try? imageInfo(),
              let image = try? mountedImage(at: volume, in: data, dmgOnly: false),
              let device = image.device else { return false }
        // Eject the backing device so APFS disk images detach along with their mounted volumes.
        _ = try runDiskCommand("/usr/sbin/diskutil", ["eject", device],
                               failure: L10n.text("磁碟可能正在使用中。請關閉磁碟上的檔案或 App 後再試一次。"))
        return true
    }

    static func mountedImage(at volume: URL, in data: Data, dmgOnly: Bool = true) throws -> Image? {
        let info = try PropertyListDecoder().decode(ImageInfo.self, from: data)
        let expectedVolume = volume.resolvingSymlinksInPath().path
        return info.images.lazy.compactMap { image -> Image? in
            guard let path = image.path, path.hasPrefix("/"),
                  !dmgOnly || URL(fileURLWithPath: path).pathExtension.lowercased() == "dmg",
                  image.entities?.contains(where: { entity in
                      guard let mount = entity.mountPoint else { return false }
                      return URL(fileURLWithPath: mount).resolvingSymlinksInPath().path == expectedVolume
                  }) == true else { return nil }
            return Image(file: URL(fileURLWithPath: path).standardizedFileURL, device: image.backingDevice)
        }.first
    }

    private static func eject(_ image: Image, identifier: NSObject) throws {
        guard let device = image.device else {
            throw LocalFileOperations.Failure(L10n.text("無法確認安裝映像檔對應的磁碟裝置"))
        }
        let retryDelays: [TimeInterval] = [0, 0.35, 0.7, 1]
        for (attempt, delay) in retryDelays.enumerated() {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let records = try mountedRecords(for: image.file, in: imageInfo())
            guard try imageIdentifier(image.file).isEqual(identifier) else {
                throw LocalFileOperations.Failure(L10n.text("安裝映像檔已變更"))
            }
            if records.isEmpty { return }
            guard records.contains(where: { $0.backingDevice == device }) else {
                throw LocalFileOperations.Failure(L10n.text("安裝磁碟已變更"))
            }

            do {
                _ = try runDiskCommand("/usr/sbin/diskutil", ["eject", device],
                                       failure: L10n.text("無法退出安裝磁碟。關閉從磁碟開啟的項目後，可再次選擇安裝以重試。"))
                return
            } catch is LocalFileOperations.Failure where attempt < retryDelays.count - 1 {
                continue
            }
        }
    }

    private static func mountedRecords(for file: URL, in data: Data) throws -> [ImageInfo.MountedImage] {
        let info = try PropertyListDecoder().decode(ImageInfo.self, from: data)
        let expected = file.resolvingSymlinksInPath().path
        return info.images.filter { image in
            guard let path = image.path else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected
        }
    }

    private static func imageIdentifier(_ file: URL) throws -> NSObject {
        let metadata = try URL(fileURLWithPath: file.path)
            .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              let identifier = metadata.fileResourceIdentifier as? NSObject else {
            throw LocalFileOperations.Failure(L10n.text("無法確認對應的 .dmg 檔案"))
        }
        return identifier
    }

    private static func imageInfo() throws -> Data {
        try runDiskCommand("/usr/bin/hdiutil", ["info", "-plist"], failure: L10n.text("無法取得安裝磁碟資訊"))
    }

    private static func runDiskCommand(_ executable: String, _ arguments: [String], failure: String) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalFileOperations.Failure(failure)
        }
        return data
    }
}
