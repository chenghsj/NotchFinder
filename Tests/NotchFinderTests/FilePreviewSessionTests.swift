import Foundation
import Testing
@testable import NotchFinder

@MainActor
struct FilePreviewSessionTests {
    @Test(arguments: [false, true])
    func lateNativeReleaseHonorsTheLatestSelectionAndDismissal(dismiss: Bool) async throws {
        let windows = PreviewWindows()
        let session = FilePreviewSession(windows: windows)
        let first = entry("First.txt"), folder = entry("Folder", folder: true), last = entry("Last.txt")

        session.show([first])
        session.show([folder], followingSelection: true)
        #expect(windows.visibleFolder == folder.id && windows.nativeState == .closing)
        session.show([first], followingSelection: true)
        session.show([last], followingSelection: true)
        #expect(windows.visibleFolder == nil && windows.presented == [[first.id]])

        windows.nativeState = .closed
        session.nativeControlEnded { true }
        if dismiss { session.close() }
        // Let the queued native reopen run after the user action.
        await Task { @MainActor in }.value
        #expect(windows.presented == (dismiss ? [[first.id]] : [[first.id], [last.id]]))
        #expect(session.isVisible == !dismiss)
    }

    @Test func queuedSelectionCannotUndoCloseOrReopenARemovedFile() async {
        let windows = PreviewWindows()
        let session = FilePreviewSession(windows: windows)
        let folder = entry("Folder", folder: true), file = entry("Gone.txt")
        session.show([folder])
        session.selectionDidChange { [file] }
        session.close()
        await Task { @MainActor in }.value
        #expect(!session.isVisible && windows.presented.isEmpty)

        session.show([folder])
        session.selectionDidChange { [] }
        await Task { @MainActor in }.value
        #expect(!session.isVisible)
    }

    private func entry(_ name: String, folder: Bool = false) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/fixture/" + name, isDirectory: folder), name: name,
                  isFolder: folder, isSymbolicLink: false, fileKind: folder ? .folder : .file,
                  fileSize: -1, modified: .distantPast, added: .distantPast)
    }
}

@MainActor
private final class PreviewWindows: FilePreviewWindows {
    let canPresent = true
    var visibleFolder: URL?
    var folderIsClosing = false
    var nativeState = FilePreviewSession.NativeState.closed
    var presented: [[URL]] = []

    func presentFolder(_ folder: FileEntry, followingSelection: Bool) { visibleFolder = folder.id }
    func dismissFolder(_ disposition: FilePreviewSession.FolderDismissal) { visibleFolder = nil }
    func reopenFolder() { folderIsClosing = false }
    func presentFiles(_ urls: [URL], followingSelection: Bool) {
        presented.append(urls)
        nativeState = .open
    }
    func dismissNative(followingSelection: Bool) { nativeState = .closing }
}
