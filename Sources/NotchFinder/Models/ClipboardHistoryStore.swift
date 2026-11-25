import Foundation

struct ClipboardHistoryStore: Sendable {
    static let defaultURL = URL.applicationSupportDirectory
        .appending(path: "Notch Finder", directoryHint: .isDirectory)
        .appending(path: "Clipboard History", directoryHint: .isDirectory)
        .appending(path: "History.plist", directoryHint: .notDirectory)

    static let maxEntries = 30
    static let maxPayloadBytes = 32 * 1024 * 1024
    private static let maxArchiveBytes = 64 * 1024 * 1024

    struct LoadedHistory {
        let entries: [ClipboardHistory.Entry]
        let needsRewrite: Bool
    }

    private struct Index: Codable {
        let version: Int
        let records: [Record]
    }

    private struct Record: Codable {
        enum Kind: Codable {
            case files
            case text
            case image(type: String)
        }

        let id: UUID
        let copiedAt: Date
        let kind: Kind
        let byteCount: Int

        init?(entry: ClipboardHistory.Entry) {
            switch entry.contents {
            case .files: kind = .files
            case .text: kind = .text
            case .image(let type, _): kind = .image(type: type)
            case .empty: return nil
            }
            id = entry.id
            copiedAt = entry.copiedAt
            byteCount = entry.contents.byteCount
        }
    }

    let url: URL
    private var files: FileManager { .default }

    private var payloadDirectory: URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".payloads", directoryHint: .isDirectory)
    }

    func load() throws -> LoadedHistory {
        guard let bytes = try regularFileSize(at: url) else {
            return LoadedHistory(entries: [], needsRewrite: try !payloadFiles().isEmpty)
        }
        guard bytes <= Self.maxArchiveBytes else { throw CocoaError(.fileReadCorruptFile) }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as CocoaError where Self.isMissing(error) {
            return LoadedHistory(entries: [], needsRewrite: try !payloadFiles().isEmpty)
        }
        let decoder = PropertyListDecoder()
        guard let index = try? decoder.decode(Index.self, from: data) else {
            let legacy = try decoder.decode([ClipboardHistory.Entry].self, from: data)
            return LoadedHistory(entries: legacy, needsRewrite: true)
        }
        guard index.version == 1 else { throw CocoaError(.fileReadCorruptFile) }

        let onDisk = try payloadFiles()
        var entries: [ClipboardHistory.Entry] = []
        var ids: Set<UUID> = []
        var remaining = Self.maxPayloadBytes
        for record in index.records.prefix(Self.maxEntries) {
            guard (0...remaining).contains(record.byteCount), !ids.contains(record.id),
                  let payload = onDisk[record.id] else { continue }
            do {
                let contents = try readPayload(at: payload, record: record)
                entries.append(ClipboardHistory.Entry(id: record.id, copiedAt: record.copiedAt, contents: contents))
                ids.insert(record.id)
                remaining -= record.byteCount
            } catch let error as CocoaError where Self.isMissing(error) || error.code == .fileReadCorruptFile {
                // Recover the remaining entries when an individual payload is missing or truncated.
                continue
            }
        }
        return LoadedHistory(entries: entries,
                             needsRewrite: entries.count != index.records.count || ids.count != onDisk.count)
    }

    func save(_ entries: [ClipboardHistory.Entry]) throws {
        if entries.isEmpty {
            if try regularFileSize(at: url) != nil { try files.removeItem(at: url) }
            try removeObsoletePayloads(keeping: [])
            return
        }

        try prepareDirectory(url.deletingLastPathComponent())
        try prepareDirectory(payloadDirectory)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var records: [Record] = []
        var ids: Set<UUID> = []

        for entry in entries {
            guard let record = Record(entry: entry) else { continue }
            guard ids.insert(entry.id).inserted else { throw CocoaError(.fileWriteUnknown) }
            let destination = payloadURL(for: entry.id)
            if try regularFileSize(at: destination) == nil {
                // A history entry's ID identifies its immutable contents. Recopies update its date only.
                let data: Data
                switch entry.contents {
                case .image(_, let image): data = image
                case .text(let text): data = Data(text.utf8)
                case .files(let urls): data = try encoder.encode(urls)
                case .empty: continue
                }
                try write(data, to: destination)
            }
            records.append(record)
        }

        // Keep the old index and its payloads readable until every new payload exists.
        try write(encoder.encode(Index(version: 1, records: records)), to: url)
        try removeObsoletePayloads(keeping: ids)
    }

    private func readPayload(at url: URL, record: Record) throws -> ClipboardContents {
        let maxSize = switch record.kind {
        case .files: Self.maxArchiveBytes
        case .text, .image: record.byteCount
        }
        guard let size = try regularFileSize(at: url), size <= maxSize else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let contents: ClipboardContents
        switch record.kind {
        case .image(let type): contents = .image(type: type, data: data)
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            contents = .text(text)
        case .files:
            guard let urls = try? PropertyListDecoder().decode([URL].self, from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            contents = .files(urls)
        }
        guard contents.byteCount == record.byteCount else { throw CocoaError(.fileReadCorruptFile) }
        return contents
    }

    private func payloadURL(for id: UUID) -> URL {
        payloadDirectory.appending(path: id.uuidString + ".blob", directoryHint: .notDirectory)
    }

    private func payloadFiles() throws -> [UUID: URL] {
        do {
            let info = try payloadDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let urls = try files.contentsOfDirectory(at: payloadDirectory, includingPropertiesForKeys: nil)
            return urls.reduce(into: [UUID: URL]()) { found, url in
                guard url.pathExtension == "blob",
                      let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      url.lastPathComponent == id.uuidString + ".blob" else { return }
                found[id] = url
            }
        } catch let error as CocoaError where Self.isMissing(error) {
            return [:]
        }
    }

    private func removeObsoletePayloads(keeping ids: Set<UUID>) throws {
        for (id, payload) in try payloadFiles() where !ids.contains(id) {
            if try regularFileSize(at: payload) != nil { try files.removeItem(at: payload) }
        }
    }

    private func prepareDirectory(_ directory: URL) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw CocoaError(.fileWriteUnknown) }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func regularFileSize(at url: URL) throws -> Int? {
        do {
            // The index is atomically replaced or removed between reads.
            let file = URL(fileURLWithPath: url.path)
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return size
        } catch let error as CocoaError where Self.isMissing(error) {
            return nil
        }
    }

    private func write(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}
