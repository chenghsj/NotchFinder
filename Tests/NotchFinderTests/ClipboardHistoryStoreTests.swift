import AppKit
import Testing
@testable import NotchFinder

@MainActor
struct ClipboardHistoryStoreTests {
    @Test func oldHistoryMigratesAndDuplicateCopiesReusePayloadFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entries = fixture.entries
        try fixture.writeLegacy(entries)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: board, defaults: fixture.defaults, storageURL: fixture.archive)
        history.finishSaving()
        #expect(history.entries == entries)

        let store = ClipboardHistoryStore(url: fixture.archive)
        let migrated = try store.load()
        #expect(migrated.entries == entries)
        #expect(!migrated.needsRewrite)
        let indexSize = try fixture.archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(try #require(indexSize) < 4_096)

        let payload = fixture.payloadURL(for: entries[0].id)
        let raw = try Data(contentsOf: payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: payload.path)
        let originalInode = try #require(attributes[.systemFileNumber] as? NSNumber)
        #expect(raw == fixture.image)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        history.setPreviewVisible(true)
        history.setRecording(true)
        let first = try #require(history.timeline.rows.first)
        try #require(history.restore(first) != nil)
        #expect(board.data(forType: .png) == fixture.image)
        history.finishSaving()
        let updated = try store.load()
        #expect(updated.entries.first?.id == entries[0].id)
        #expect(updated.entries.first?.copiedAt != entries[0].copiedAt)
        let newAttributes = try FileManager.default.attributesOfItem(atPath: payload.path)
        #expect(newAttributes[.systemFileNumber] as? NSNumber == originalInode)

        history.clear()
        history.finishSaving()
        #expect(try store.load().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(history.timeline.current?.contents == entries[0].contents)
        history.setRecording(false)
        history.setPreviewVisible(false)
    }

    @Test func failedMigrationPreservesOriginalArchiveForRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entries = fixture.entries
        try fixture.writeLegacy(entries)
        let original = try Data(contentsOf: fixture.archive)
        try Data([1]).write(to: fixture.payloadDirectory)

        let store = ClipboardHistoryStore(url: fixture.archive)
        #expect(throws: CocoaError.self) { try store.save(entries) }
        #expect(try Data(contentsOf: fixture.archive) == original)
        #expect(try store.load().entries == entries)

        try FileManager.default.removeItem(at: fixture.payloadDirectory)
        try store.save(entries)
        #expect(try store.load().entries == entries)
        #expect(try !store.load().needsRewrite)
    }

    @Test func missingPayloadKeepsOtherEntriesAndCleansUnreferencedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let entries = fixture.entries
        let store = ClipboardHistoryStore(url: fixture.archive)
        try store.save(entries)
        let orphan = fixture.payloadURL(for: UUID())
        try Data([1]).write(to: orphan)
        try FileManager.default.removeItem(at: fixture.payloadURL(for: entries[0].id))

        let loaded = try store.load()
        #expect(loaded.entries == Array(entries.dropFirst()))
        #expect(loaded.needsRewrite)
        try store.save(loaded.entries)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try !store.load().needsRewrite)
    }

    @Test func rapidUpdatesPersistTheLatestEntriesAndClearWins() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: board, defaults: fixture.defaults, storageURL: fixture.archive)
        let store = ClipboardHistoryStore(url: fixture.archive)
        history.setRecording(true)
        for index in 0..<44 {
            board.clearContents()
            try #require(board.setString("Item \(index)", forType: .string))
            history.sample(allowPrompt: true)
        }
        history.finishSaving()
        #expect(try store.load().entries.map(\.contents) == (14..<44).reversed().map { .text("Item \($0)") })

        for index in 44..<64 {
            board.clearContents()
            try #require(board.setString("Item \(index)", forType: .string))
            history.sample(allowPrompt: true)
        }
        history.clear()
        history.finishSaving()
        #expect(try store.load().entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.payloadDirectory.path).isEmpty)
        history.setRecording(false)
    }

    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        private let name = "local.notchfinder.clipboard-store-test." + UUID().uuidString
        let image = Data(repeating: 0xBA, count: 512 * 1024)

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
            defaults = try #require(UserDefaults(suiteName: name))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        var archive: URL { directory.appending(path: "History.plist") }
        var payloadDirectory: URL { directory.appending(path: "History.plist.payloads", directoryHint: .isDirectory) }

        var entries: [ClipboardHistory.Entry] {
            let date = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) - 120)
            return [
                .init(copiedAt: date, contents: .image(type: "public.png", data: image)),
                .init(copiedAt: date.addingTimeInterval(-10), contents: .text("測試文字")),
                .init(copiedAt: date.addingTimeInterval(-20), contents: .files([directory.appending(path: "example.txt")]))
            ]
        }

        func payloadURL(for id: UUID) -> URL {
            payloadDirectory.appending(path: id.uuidString + ".blob")
        }

        func writeLegacy(_ entries: [ClipboardHistory.Entry]) throws {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(entries).write(to: archive)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
