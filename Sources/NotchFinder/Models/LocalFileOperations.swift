import Foundation

enum LocalFileOperations {
    struct Failure: LocalizedError {
        let errorDescription: String?

        init(_ message: String) { errorDescription = message }
    }

    static func checkedName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw Failure(L10n.text("請輸入有效的名稱"))
        }
        return name
    }

    static func createFolder(named name: String, in folder: URL) throws {
        let destination = folder.appendingPathComponent(try checkedName(name), isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    static func rename(_ item: URL, to name: String) throws {
        let name = try checkedName(name)
        guard name != item.lastPathComponent else { return }
        let directory = item.deletingLastPathComponent()
        let destination = directory.appendingPathComponent(name, isDirectory: item.hasDirectoryPath)
        try FileManager.default.moveItem(at: item, to: destination)
    }

    static func copy(_ items: [URL], into folder: URL) throws {
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL.path
        try perform(items, verb: L10n.text("複製")) { source in
            let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedFolder != resolvedSource,
                  !resolvedFolder.hasPrefix(resolvedSource == "/" ? "/" : resolvedSource + "/") else {
                throw Failure(L10n.text("無法將資料夾複製到自己裡面"))
            }
            let destination = folder.appendingPathComponent(source.lastPathComponent, isDirectory: source.hasDirectoryPath)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    static func trash(_ items: [URL]) throws {
        try perform(items, verb: L10n.text("移到垃圾桶")) {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    }

    private static func perform(_ items: [URL], verb: String, action: (URL) throws -> Void) throws {
        var failures: [String] = []
        for item in items {
            do { try action(item) }
            catch { failures.append("\(item.lastPathComponent)（\(error.localizedDescription)）") }
        }
        if !failures.isEmpty {
            throw Failure(L10n.text("有 %@ 個項目無法%@\n", String(describing: failures.count), String(describing: verb)) + failures.joined(separator: "\n"))
        }
    }
}
