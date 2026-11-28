import Darwin
import Foundation

enum ZipArchive {
    static func create(in folder: URL, names: [String]) throws -> URL {
        var template = folder.appendingPathComponent(".notchfinder-zip.XXXXXXXX").path.utf8CString
        guard let stagingFolder = template.withUnsafeMutableBufferPointer({ buffer in
            mkdtemp(buffer.baseAddress).map {
                URL(fileURLWithFileSystemRepresentation: $0, isDirectory: true, relativeTo: nil)
            }
        }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { try? FileManager.default.removeItem(at: stagingFolder) }

        let archive = stagingFolder.appendingPathComponent("archive.zip")
        let selection = stagingFolder.appendingPathComponent("selection")
        // A NUL-delimited list handles newlines in filenames and avoids the process argument limit.
        var paths = Data()
        func include(_ path: String) {
            paths.append(contentsOf: "./\(path)".utf8)
            paths.append(0)
        }
        for name in names {
            include(name)
            do {
                try packMetadata(in: folder, path: name, staging: stagingFolder, depth: 0, include: include)
            } catch {
                throw LocalFileOperations.Failure(L10n.text("無法壓縮項目：%@", name + "（" + error.localizedDescription + "）"))
            }
        }
        try paths.write(to: selection)

        let process = Process()
        let diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.currentDirectoryURL = folder
        // Move only our staged metadata into the ZIP's standard AppleDouble namespace.
        let prefix = "^" + NSRegularExpression.escapedPattern(for: "./" + stagingFolder.lastPathComponent + "/") + "[0-9]*/"
        let nestedSidecar = "," + prefix + #"\(.*/\)\([^/]*\)$,__MACOSX/\1._\2,S"#
        let rootSidecar = "," + prefix + #"\([^/]*\)$,__MACOSX/._\1,S"#
        process.arguments = ["-c", "--no-mac-metadata", "--format", "zip", "--options", "zip:compression=deflate,zip:hdrcharset=UTF-8",
                             "-s", nestedSidecar, "-s", rootSidecar, "-f", archive.path, "--null", "-T", selection.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics
        try process.run()
        let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // tar can skip an unsupported entry and report it on stderr with a successful exit status.
        if !data.isEmpty {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalFileOperations.Failure(L10n.text("無法壓縮項目：%@", message))
        }
        guard process.terminationStatus == 0 else {
            throw LocalFileOperations.Failure(L10n.text("無法壓縮項目"))
        }

        let defaultName = L10n.text("壓縮檔")
        return try publish(archive, in: folder, named: names.count == 1 ? names[0] : defaultName, fallbackName: defaultName)
    }

    private static func packMetadata(in folder: URL, path: String, staging: URL, depth: Int,
                                     include: (String) -> Void) throws {
        let source = folder.appendingPathComponent(path)
        let metadata = copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR | COPYFILE_NOFOLLOW_SRC)
        let needed = copyfile(source.path, nil, nil, metadata | copyfile_flags_t(COPYFILE_CHECK))
        guard needed >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if needed != 0 {
            // Separate levels let a directory and its children have sidecars, even for 255-byte names.
            let relative = "\(depth)/" + path
            let packed = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: packed.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard copyfile(source.path, packed.path, nil, metadata | copyfile_flags_t(COPYFILE_PACK)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            include(staging.lastPathComponent + "/" + relative)
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
                try packMetadata(in: folder, path: path + "/" + name, staging: staging, depth: depth + 1, include: include)
            }
        }
    }

    private static func publish(_ archive: URL, in folder: URL, named name: String, fallbackName: String) throws -> URL {
        var stem = name
        var number = 1
        while true {
            let filename = number == 1 ? "\(stem).zip" : "\(stem) \(number).zip"
            let destination = folder.appendingPathComponent(filename)
            do {
                try LocalFileOperations.moveWithoutReplacing(archive, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            } catch let error as POSIXError where error.code == .ENAMETOOLONG && stem != fallbackName {
                stem = fallbackName
                number = 1
            }
        }
    }
}
