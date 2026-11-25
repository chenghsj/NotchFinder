import AppKit
import UniformTypeIdentifiers

struct ClipboardSnapshot {
    let contents: ClipboardContents
    let changeCount: Int
    let copiedAt = Date.now
}

enum ClipboardContents: Codable, Equatable, Sendable {
    case files([URL])
    case text(String)
    case image(type: String, data: Data)
    case empty

    var hasFiles: Bool {
        if case .files = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .files(let urls):
            if urls.count == 1, let first = urls.first { return first.lastPathComponent }
            return L10n.text("%@ 個檔案或資料夾", String(describing: urls.count))
        case .text(let text):
            return text.prefix(160).split(whereSeparator: \.isNewline).first.map(String.init) ?? L10n.text("文字")
        case .image:
            return L10n.text("圖片")
        case .empty:
            return L10n.text("剪貼簿")
        }
    }

    var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .text: "doc.text"
        case .image: "photo"
        case .empty: "clipboard"
        }
    }

    var byteCount: Int {
        switch self {
        case .files(let urls): urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
        case .text(let text): text.utf8.count
        case .image(_, let data): data.count
        case .empty: 0
        }
    }

    func matches(_ query: String) -> Bool {
        switch self {
        case .files(let urls): urls.contains { $0.path.localizedStandardContains(query) }
        case .text(let text): text.localizedStandardContains(query)
        case .image, .empty: title.localizedStandardContains(query)
        }
    }

    @MainActor
    static func read(from pasteboard: NSPasteboard, allowImageFallback: Bool = true) -> Self {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) {
            let urls = fileURLs(from: pasteboard)
            if !urls.isEmpty { return .files(urls) }
        }
        if let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL),
           !text.isEmpty { return .text(text) }
        let images = [.png, .tiff] + types.filter { UTType($0.rawValue)?.conforms(to: .image) == true }
        if let type = images.first(where: types.contains), let data = pasteboard.data(forType: type) {
            return .image(type: type.rawValue, data: data)
        }
        if allowImageFallback, let data = NSImage(pasteboard: pasteboard)?.tiffRepresentation {
            return .image(type: NSPasteboard.PasteboardType.tiff.rawValue, data: data)
        }
        return .empty
    }

    @MainActor
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    @MainActor
    func write(to pasteboard: NSPasteboard) -> Bool {
        guard self != .empty else { return false }
        pasteboard.clearContents()
        switch self {
        case .files(let urls): return pasteboard.writeObjects(urls.map { $0 as NSURL })
        case .text(let text): return pasteboard.setString(text, forType: .string)
        case .image(let type, let data): return pasteboard.setData(data, forType: .init(type))
        case .empty: return false
        }
    }
}
