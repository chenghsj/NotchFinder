import AppKit
import Carbon.HIToolbox
import QuickLookUI
import SwiftUI
import Testing
import os
@testable import NotchFinder

// These tests share AppKit's main run loop while waiting for file and window updates.
@Suite(.serialized)
@MainActor
struct ArchitectureRegressionTests {
    @Test func emptyingTrashRemovesHiddenAndNestedItemsWithoutFollowingLinks() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let manager = FileManager.default
        let trash = try fixture.createFolder("Trash")
        let outside = try fixture.createFolder("Outside")
        let nested = trash.appending(path: "Folder", directoryHint: .isDirectory)
        try manager.createDirectory(at: nested, withIntermediateDirectories: false)
        let original = Data("keep me".utf8)
        let keptFile = outside.appending(path: "Kept.txt")
        try original.write(to: keptFile)
        try Data().write(to: trash.appending(path: ".hidden"))
        try Data().write(to: nested.appending(path: "Nested.txt"))
        try manager.createSymbolicLink(at: nested.appending(path: "Linked Folder"), withDestinationURL: outside)

        try LocalFileOperations.emptyTrash(at: trash) { _ in Issue.record("Unexpected authorization request") }
        #expect(try manager.contentsOfDirectory(atPath: trash.path).isEmpty)

        try Data().write(to: trash.appending(path: ".hidden"))
        try LocalFileOperations.emptyTrash(at: trash)
        #expect(try manager.contentsOfDirectory(atPath: trash.path).isEmpty)
        try LocalFileOperations.emptyTrash(at: trash)

        #expect(try Data(contentsOf: keptFile) == original)
    }

    @Test func emptyingTrashRejectsASymbolicLinkAsTheRoot() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("Outside")
        let trash = fixture.directory.appending(path: "Trash", directoryHint: .isDirectory)
        let keptFile = folder.appending(path: "Kept.txt")
        try Data().write(to: keptFile)
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: folder)

        #expect(throws: POSIXError.self) { try LocalFileOperations.emptyTrash(at: trash) }
        #expect(FileManager.default.fileExists(atPath: keptFile.path))
    }

    @Test func emptyingTrashKeepsProtectedItemsWhenAuthorizationIsCancelled() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let manager = FileManager.default
        let trash = try fixture.createFolder("Trash")
        let locked = trash.appending(path: "Read Only", directoryHint: .isDirectory)
        try manager.createDirectory(at: locked, withIntermediateDirectories: false)
        let retained = locked.appending(path: "Retained.txt")
        let removable = trash.appending(path: "Removable.txt")
        try Data().write(to: retained)
        try Data().write(to: removable)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        var requests = 0
        let error = #expect(throws: LocalFileOperations.Failure.self) {
            try LocalFileOperations.emptyTrash(at: trash) { request in
                requests += 1
                #expect(request.items.map(\.name) == [locked.lastPathComponent])
                #expect(!manager.fileExists(atPath: removable.path))
                throw CocoaError(.userCancelled)
            }
        }
        #expect(requests == 1)
        #expect(error?.localizedDescription == CocoaError(.userCancelled).localizedDescription)
        #expect(manager.fileExists(atPath: retained.path))
        #expect(!manager.fileExists(atPath: removable.path))
    }

    @Test func emptyingTrashRetriesOnlyOriginalProtectedItemsAfterAuthorization() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let manager = FileManager.default
        let trash = try fixture.createFolder("Trash ' 路徑")
        let keeper = try fixture.createFolder("Outside")
        let keptFile = keeper.appending(path: "keep")
        try Data().write(to: keptFile)
        let names = ["- '$(echo unsafe) \n.app", "Replaced", "Restored"]
        defer {
            for name in names {
                let folder = trash.appendingPathComponent(name)
                if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false {
                    try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                }
            }
        }
        for name in names {
            let folder = trash.appendingPathComponent(name)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            try manager.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: keeper)
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        }
        let regular = trash.appending(path: "ordinary")
        try Data().write(to: regular)
        var requests = 0

        try LocalFileOperations.emptyTrash(at: trash) { request in
            requests += 1
            #expect(Set(request.items.map(\.name)) == Set(names))
            #expect(!manager.fileExists(atPath: regular.path))
            // Simulate changes made while the system Automation prompt is open.
            for name in names {
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trash.appendingPathComponent(name).path)
            }
            for name in names.dropFirst() {
                try manager.moveItem(at: trash.appendingPathComponent(name), to: fixture.directory.appendingPathComponent(name))
            }
            try manager.createSymbolicLink(at: trash.appending(path: "Replaced"), withDestinationURL: keeper)
            try Data().write(to: trash.appending(path: "new"))
            #expect(try request.remainingItems().map(\.name) == [names[0]])
            for command in request.commands {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
            }
        }
        #expect(requests == 1)
        #expect(Set(try manager.contentsOfDirectory(atPath: trash.path)) == ["Replaced", "new"])
        #expect(manager.fileExists(atPath: fixture.directory.appending(path: "Restored/link/keep").path))
        #expect(manager.fileExists(atPath: keptFile.path))
    }

    @Test func denialAfterAdminAuthorizationOffersRecoveryOnlyForOriginalItems() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let trash = try fixture.createFolder("Trash")
        let item = trash.appending(path: "Protected.app")
        try Data().write(to: item)
        var rootInfo = stat(), itemInfo = stat()
        try #require(lstat(trash.path, &rootInfo) == 0 && lstat(item.path, &itemInfo) == 0)
        let request = TrashRemovalRequest(directory: trash, device: rootInfo.st_dev, inode: rootInfo.st_ino,
                                          items: [.init(name: item.lastPathComponent, inode: itemInfo.st_ino)])
        let error = #expect(throws: LocalFileOperations.Failure.self) {
            try request.checkResult(cancelled: false, errors: ["find: -delete: unlink(./Contents/_CodeSignature/CodeResources): Operation not permitted"])
        }
        #expect(error?.localizedDescription.contains(item.lastPathComponent) == true)
        #expect(error?.trashRecovery?.items.map(\.name) == [item.lastPathComponent])
        let cancelled = #expect(throws: LocalFileOperations.Failure.self) {
            try request.checkResult(cancelled: true, errors: [])
        }
        #expect(cancelled?.trashRecovery == nil)
        let ioFailure = #expect(throws: LocalFileOperations.Failure.self) {
            try request.checkResult(cancelled: false, errors: ["Input/output error"])
        }
        #expect(ioFailure?.trashRecovery == nil)

        let moved = fixture.directory.appending(path: "Moved")
        try FileManager.default.moveItem(at: trash, to: moved)
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: moved)
        #expect(throws: POSIXError.self) {
            _ = try request.remainingItems()
        }
        #expect(FileManager.default.fileExists(atPath: item.path))
    }

    @Test func retryAfterChangingPrivacySettingsUsesNormalAccessAndKeepsNewTrashItems() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let manager = FileManager.default
        let trash = try fixture.createFolder("Trash")
        let app = trash.appending(path: "Test.app", directoryHint: .isDirectory)
        try manager.createDirectory(at: app, withIntermediateDirectories: false)
        try Data().write(to: app.appending(path: "CodeResources"))
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: app.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.path) }
        let failure = #expect(throws: LocalFileOperations.Failure.self) {
            try LocalFileOperations.emptyTrash(at: trash) { request in
                try request.checkResult(cancelled: false, errors: ["Operation not permitted"])
            }
        }
        let retry = try #require(failure?.trashRecovery)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: app.path)
        let newItem = trash.appending(path: "New.txt")
        try Data().write(to: newItem)
        try LocalFileOperations.emptyTrash(at: trash, retrying: retry) { _ in
            Issue.record("Normal access should suffice after the permission change")
        }
        #expect(!manager.fileExists(atPath: app.path))
        #expect(manager.fileExists(atPath: newItem.path))
    }

    @Test func droppingFilesMovesOrCopiesWithoutReplacingExistingItems() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let manager = FileManager.default
        let target = try fixture.createFolder("Destination")
        let moved = fixture.directory.appending(path: "Moved.txt")
        let copied = fixture.directory.appending(path: "Copied.txt")
        let conflicting = fixture.directory.appending(path: "Same.txt")
        let existing = target.appending(path: conflicting.lastPathComponent)
        let original = Data("original".utf8)
        let previous = Data("existing".utf8)
        for url in [moved, copied, conflicting] { try original.write(to: url) }
        try previous.write(to: existing)

        #expect(throws: LocalFileOperations.Failure.self) {
            try LocalFileOperations.drop([moved, conflicting], into: target, copies: false)
        }
        #expect(!manager.fileExists(atPath: moved.path))
        #expect(try Data(contentsOf: target.appending(path: moved.lastPathComponent)) == original)
        #expect(try Data(contentsOf: conflicting) == original)
        #expect(try Data(contentsOf: existing) == previous)

        try LocalFileOperations.drop([copied], into: target, copies: true)
        #expect(try Data(contentsOf: copied) == original)
        #expect(try Data(contentsOf: target.appending(path: copied.lastPathComponent)) == original)

        let child = target.appending(path: "Child", directoryHint: .isDirectory)
        try manager.createDirectory(at: child, withIntermediateDirectories: false)
        for folder in [target, child] {
            #expect(throws: LocalFileOperations.Failure.self) {
                try LocalFileOperations.drop([target], into: folder, copies: true)
            }
            #expect(!manager.fileExists(atPath: folder.appending(path: target.lastPathComponent).path))
        }
    }

    @Test func failedFolderDropCleansUpAndCanBeRetried() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let manager = FileManager.default
        let source = try fixture.createFolder("Source")
        let destination = try fixture.createFolder("Destination")
        let blocked = source.appending(path: "Private.txt")
        let contents = Data("original".utf8)
        try contents.write(to: blocked)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }
        guard !manager.isReadableFile(atPath: blocked.path) else { return }

        #expect(throws: LocalFileOperations.Failure.self) {
            try LocalFileOperations.drop([source], into: destination, copies: true)
        }
        #expect(try manager.contentsOfDirectory(atPath: destination.path).isEmpty)

        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path)
        let changes = try LocalFileOperations.drop([source], into: destination, copies: true)
        #expect(changes.count == 1)
        #expect(try Data(contentsOf: destination.appending(path: "Source/Private.txt")) == contents)
    }

    @Test func copyingIntoTheOriginalFolderCreatesANumberedSibling() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let source = fixture.directory.appending(path: "Note.txt")
        let existing = fixture.directory.appending(path: "Note 2.txt")
        let contents = Data("original".utf8)
        let previous = Data("keep".utf8)
        try contents.write(to: source)
        try previous.write(to: existing)
        #expect(try LocalFileOperations.drop([source], into: fixture.directory, copies: false).isEmpty)

        let reversals = try LocalFileOperations.drop([source], into: fixture.directory, copies: true)
        let copy = try #require(reversals.first?.item)
        #expect(reversals.count == 1 && copy.lastPathComponent == "Note 3.txt")
        #expect(try Data(contentsOf: copy) == contents)
        #expect(try Data(contentsOf: existing) == previous)
        #expect(try Data(contentsOf: source) == contents)
    }

    @Test func copyingALockedFilePreservesBothLocksAndCleansTheDraft() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("Copies")
        let source = fixture.directory.appending(path: "Locked.txt")
        let contents = Data("locked".utf8)
        try contents.write(to: source)
        try #require(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(source.path, 0) }
        let copy = try #require(LocalFileOperations.copy([source], into: folder).first?.item)
        defer { _ = chflags(copy.path, 0) }
        #expect(try Data(contentsOf: copy) == contents)
        for url in [source, copy] {
            var info = stat()
            try #require(lstat(url.path, &info) == 0)
            #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Locked.txt"])
    }

    @Test func failedPublicationRemovesLockedDescendantsOfTheCopy() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let source = try fixture.createFolder("Source")
        let destination = try fixture.createFolder("Destination")
        let child = source.appending(path: "Locked")
        try Data().write(to: child)
        try #require(chflags(child.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(child.path, 0) }
        let existing = destination.appending(path: "Source")
        try FileManager.default.createSymbolicLink(atPath: existing.path, withDestinationPath: "missing")
        #expect(throws: LocalFileOperations.Failure.self) { try LocalFileOperations.copy([source], into: destination) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["Source"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: existing.path) == "missing")
    }

    @Test(arguments: [false, true])
    func droppingASelectedFolderIncludesItsSelectedDescendantsOnlyOnce(copies: Bool) throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("Parent")
        let child = folder.appending(path: "Child.txt")
        let target = try fixture.createFolder("Destination")
        let contents = Data("original".utf8)
        try contents.write(to: child)

        let reversals = try LocalFileOperations.drop([child, folder], into: target, copies: copies)

        #expect(reversals.count == 1)
        #expect(try Data(contentsOf: target.appending(path: "Parent/Child.txt")) == contents)
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "Child.txt").path))
        #expect(FileManager.default.fileExists(atPath: child.path) == copies)
    }

    @Test func compressingMultipleItemsKeepsTheirNamesAndDoesNotOverwriteAnArchive() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("資料夾")
        let child = folder.appending(path: ".hidden")
        let file = fixture.directory.appending(path: "- 檔案\n名稱.txt")
        let contents = Data("original".utf8)
        try contents.write(to: child)
        try contents.write(to: file)
        let resourceFork = Data("resource fork".utf8)
        for item in [child, file] {
            try resourceFork.write(to: item.appending(path: "..namedfork/rsrc"))
        }
        let attribute = "local.notchfinder.archive-test"
        let metadata = Data("directory metadata".utf8)
        let written = metadata.withUnsafeBytes { setxattr(folder.path, attribute, $0.baseAddress, $0.count, 0, 0) }
        try #require(written == 0)
        let link = folder.appending(path: "Link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../")
        let archiveName = L10n.text("壓縮檔")
        let existing = fixture.directory.appending(path: "\(archiveName).zip")
        let previous = Data("previous archive".utf8)
        try previous.write(to: existing)

        let changes = try LocalFileOperations.compress([child, folder, file])
        let archive = try #require(changes.first?.item)
        #expect(changes.count == 1)
        #expect(archive.lastPathComponent == "\(archiveName) 2.zip")
        #expect(try Data(contentsOf: existing) == previous)
        #expect(try Data(contentsOf: file) == contents)

        let output = try fixture.createFolder("Extracted")
        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", archive.path, output.path]
        try extract.run()
        extract.waitUntilExit()
        try #require(extract.terminationStatus == 0)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == [folder.lastPathComponent, file.lastPathComponent])
        #expect(try Data(contentsOf: output.appending(path: "資料夾/.hidden")) == contents)
        #expect(try Data(contentsOf: output.appending(path: file.lastPathComponent)) == contents)
        for path in ["資料夾/.hidden", file.lastPathComponent] {
            #expect(try Data(contentsOf: output.appending(path: path + "/..namedfork/rsrc")) == resourceFork)
        }
        var restored = Data(count: metadata.count)
        let length = restored.withUnsafeMutableBytes {
            getxattr(output.appending(path: folder.lastPathComponent).path, attribute, $0.baseAddress, $0.count, 0, 0)
        }
        #expect(length == metadata.count && restored == metadata)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: output.appending(path: "資料夾/Link").path) == "../")
    }

    @Test func compressingAMissingItemCleansUpThePartialArchive() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let file = fixture.directory.appending(path: "Existing.txt")
        let missing = fixture.directory.appending(path: "Missing.txt")
        try Data().write(to: file)

        #expect(throws: LocalFileOperations.Failure.self) {
            try LocalFileOperations.compress([file, missing])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == [file.lastPathComponent])
    }

    @Test func fileDropUsesOnlyPermittedOperationsAndRequiresEveryFileURL() throws {
        let folder = FileBrowser.DropDestination.folder(URL(filePath: "/tmp"))
        let source = FileDragTarget()
        let allowed = source.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .withinApplication)
        #expect(FileDropRegion.operation(for: folder, allowed: allowed, optionDown: false, sameVolume: true) == .move)
        #expect(FileDropRegion.operation(for: folder, allowed: allowed, optionDown: true, sameVolume: true) == .copy)
        #expect(FileDropRegion.operation(for: folder, allowed: .copy, optionDown: false, sameVolume: true) == .copy)
        #expect(FileDropRegion.operation(for: folder, allowed: [.copy, .move], optionDown: false, sameVolume: true) == .move)
        #expect(FileDropRegion.operation(for: folder, allowed: [.copy, .move], optionDown: true, sameVolume: true) == .copy)
        #expect(FileDropRegion.operation(for: folder, allowed: [.copy, .move], optionDown: false, sameVolume: false) == .copy)
        #expect(FileDropRegion.operation(for: folder, allowed: .move, optionDown: false, sameVolume: false).isEmpty)
        #expect(FileDropRegion.operation(for: .trash, allowed: .copy, optionDown: false, sameVolume: true).isEmpty)
        #expect(FileDropRegion.operation(for: .trash, allowed: .delete, optionDown: false, sameVolume: true) == .delete)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let file = URL(filePath: "/tmp/Notch Finder item")
        let good = NSPasteboardItem()
        good.setData(file.dataRepresentation, forType: .fileURL)
        try #require(board.writeObjects([good]))
        #expect(FileDropRegion.urls(from: board) == [file])

        board.clearContents()
        let other = NSPasteboardItem()
        other.setString("invalid", forType: .string)
        let valid = NSPasteboardItem()
        valid.setData(file.dataRepresentation, forType: .fileURL)
        try #require(board.writeObjects([valid, other]))
        #expect(FileDropRegion.urls(from: board) == nil)
    }

    @Test func acceptingADropReservesTheFileOperationWhileItsURLsLoad() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let settings = NotchSettings(defaults: fixture.defaults)
        let history = FileOperationHistory()
        let first = FileBrowser(initialDirectory: fixture.directory, settings: settings, fileHistory: history)
        let second = FileBrowser(initialDirectory: fixture.directory, settings: settings, fileHistory: history)
        let target = try fixture.createFolder("Destination")
        var complete: (@MainActor ([URL]) -> Void)?

        let accepted = first.acceptFileDrop(into: .folder(target), copies: false) { complete = $0 }
        #expect(accepted)
        #expect(second.isUpdatingFiles)
        let rejected = second.acceptFileDrop(into: .trash, copies: false) { _ in
            Issue.record("Rejected drops must leave providers untouched")
        }
        #expect(!rejected)
        let source = fixture.directory.appending(path: "Item.txt")
        try Data().write(to: source)
        #expect(!second.acceptFileDrop(into: .folder(target), copies: false) { $0([source]) })
        #expect(FileManager.default.fileExists(atPath: source.path))

        let finishLoading = try #require(complete)
        finishLoading([])
        try await waitUntil { !second.isUpdatingFiles }
        #expect(first.openError != nil)

        let retried = second.acceptFileDrop(into: .folder(target), copies: false) { $0([source]) }
        #expect(retried)
        try await waitUntil { !second.isUpdatingFiles }
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "Item.txt").path))
    }

    @Test func undoAndRedoTrackSuccessfulMovesAcrossTabsAndRetryConflicts() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let source = fixture.directory
        let target = try fixture.createFolder("Destination")
        let moved = source.appending(path: "Moved.txt")
        let rejected = source.appending(path: "Rejected.txt")
        let movedTarget = target.appending(path: moved.lastPathComponent)
        let rejectedTarget = target.appending(path: rejected.lastPathComponent)
        let original = Data("original".utf8)
        let existing = Data("existing".utf8)
        try original.write(to: moved)
        try original.write(to: rejected)
        try existing.write(to: rejectedTarget)

        let settings = NotchSettings(defaults: fixture.defaults)
        let clipboard = ClipboardHistory(defaults: fixture.defaults, storageURL: source.appending(path: "clipboard.plist"))
        let tabs = BrowserTabs(initialDirectory: source, settings: settings, clipboardHistory: clipboard)
        let originalTab = tabs.active
        let accepted = originalTab.browser.acceptFileDrop(into: .folder(target), copies: false) { $0([moved, rejected]) }
        #expect(accepted)
        tabs.add()
        let browser = tabs.active.browser
        #expect(browser.isUpdatingFiles)
        tabs.close(originalTab.id)
        try await waitUntil { !browser.isUpdatingFiles }
        #expect(browser.openError != nil)
        #expect(try Data(contentsOf: movedTarget) == original)

        try existing.write(to: moved)
        browser.replayFileOperation(.undo)
        try await waitUntil { !browser.isUpdatingFiles }
        #expect(browser.openError != nil)
        #expect(try Data(contentsOf: moved) == existing)
        #expect(try Data(contentsOf: movedTarget) == original)

        try FileManager.default.removeItem(at: moved)
        browser.replayFileOperation(.undo)
        try await waitUntil { !browser.isUpdatingFiles }
        #expect(browser.openError == nil)
        #expect(try Data(contentsOf: moved) == original)
        #expect(!FileManager.default.fileExists(atPath: movedTarget.path))

        browser.replayFileOperation(.redo)
        try await waitUntil { !browser.isUpdatingFiles }
        #expect(try Data(contentsOf: movedTarget) == original)
        #expect(try Data(contentsOf: rejected) == original)
        #expect(try Data(contentsOf: rejectedTarget) == existing)
    }

    @Test(arguments: [false, true])
    func trashRetrySurvivesClosingTheOriginatingTab(panelVisible: Bool) async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let trash = try fixture.createFolder("Trash")
        let protected = trash.appending(path: "Protected.app", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: protected, withIntermediateDirectories: false)
        try Data().write(to: protected.appending(path: "Contents"))
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protected.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path) }

        var reads = 0
        let source = BrowserContentRefresh.Source(read: { target, hidden in
            reads += 1
            return try await FileBrowser.readContents(at: target, includeHidden: hidden)
        }, searchUpdates: BrowserContentRefresh.Source.live.searchUpdates)
        let tabs = BrowserTabs(initialDirectory: trash, settings: NotchSettings(defaults: fixture.defaults),
                               clipboardHistory: ClipboardHistory(defaults: fixture.defaults, storageURL: fixture.directory.appending(path: "History.plist")),
                               contentSource: source,
                               sidebar: SidebarLocations(defaults: fixture.defaults, trashDirectory: trash))
        tabs.setPanelVisible(panelVisible)
        let origin = tabs.active
        origin.browser.emptyTrash { request in
            throw LocalFileOperations.Failure("Permission denied", trashRecovery: request)
        }
        tabs.add()
        tabs.close(origin.id)
        let browser = tabs.active.browser
        try await waitUntil { !browser.isUpdatingFiles }
        if !panelVisible { #expect(reads == 0) }
        tabs.setPanelVisible(true)
        defer { tabs.setPanelVisible(false) }
        try await waitUntil { !browser.isLoading }
        #expect(browser.openError?.contains("Permission denied") == true)
        let retry = try #require(browser.trashRecovery)
        #expect(retry.items.map(\.name) == ["Protected.app"])

        let newcomer = trash.appending(path: "New.txt")
        try Data().write(to: newcomer)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path)
        browser.emptyTrash(retrying: retry) { _ in Issue.record("Retry should use normal access") }
        try await waitUntil { !browser.isUpdatingFiles && !browser.isLoading }
        #expect(browser.trashRecovery == nil && browser.openError == nil)
        #expect(browser.entries.map(\.name) == ["New.txt"])
        #expect(manager.fileExists(atPath: newcomer.path))
    }

    @Test func replaySkipsReplacementsAndNewOperationsClearRedoHistory() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = fixture.directory
        let original = folder.appending(path: "Original.txt")
        let renamed = folder.appending(path: "Renamed.txt")
        let saved = folder.appending(path: "Saved.txt")
        let bytes = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        try bytes.write(to: original)

        let history = FileOperationHistory()
        #expect(await history.perform { try LocalFileOperations.rename(original, to: renamed.lastPathComponent) } == nil)
        #expect(await history.replay(.undo) == nil)
        #expect(history.canReplay(.redo))
        #expect(await history.perform { try LocalFileOperations.rename(original, to: saved.lastPathComponent) } == nil)
        #expect(!history.canReplay(.redo))

        try FileManager.default.moveItem(at: saved, to: renamed)
        try replacement.write(to: saved)
        #expect(await history.replay(.undo) != nil)
        #expect(!history.canReplay(.undo))
        #expect(!history.canReplay(.redo))
        #expect(try Data(contentsOf: renamed) == bytes)
        #expect(try Data(contentsOf: saved) == replacement)
    }

    @Test func interfaceLanguageDefaultsToSystemAndPersistsChanges() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let settings = NotchSettings(defaults: fixture.defaults)
        #expect(settings.interfaceLanguage == .system)

        settings.interfaceLanguage = .japanese
        #expect(NotchSettings(defaults: fixture.defaults).interfaceLanguage == .japanese)

        settings.interfaceLanguage = .system
        #expect(NotchSettings(defaults: fixture.defaults).interfaceLanguage == .system)

        fixture.defaults.set("unsupported", forKey: "interfaceLanguage")
        #expect(NotchSettings(defaults: fixture.defaults).interfaceLanguage == .system)
    }

    @Test func clipboardDefaultPreservesAnExistingGlobalPanelBinding() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let clipboardDefault = PanelCommand.openClipboard.defaultShortcut
        let panelDefault = PanelCommand.togglePanel.defaultShortcut
        let savedBindings = try JSONEncoder().encode([PanelCommand.togglePanel.rawValue: clipboardDefault])
        fixture.defaults.set(savedBindings, forKey: "panelShortcuts")

        let shortcuts = PanelShortcuts(defaults: fixture.defaults)
        var registered: [PanelCommand: KeyShortcut] = [:]
        shortcuts.installGlobals = { changes in
            registered.merge(changes) { _, new in new }
            return true
        }
        shortcuts.installInitialGlobals()
        #expect(registered == [.togglePanel: clipboardDefault])
        #expect(!shortcuts.globalAvailable)

        #expect(shortcuts.assign(panelDefault, to: .openClipboard))
        #expect(registered == [.togglePanel: clipboardDefault, .openClipboard: panelDefault])
        #expect(shortcuts.globalAvailable)
        #expect(PanelShortcuts(defaults: fixture.defaults)[.openClipboard] == panelDefault)

        shortcuts.reset()
        #expect(registered == [.togglePanel: panelDefault, .openClipboard: clipboardDefault])
    }

    @Test(arguments: [PanelCommand.togglePanel, .filter])
    func freeingClipboardShortcutRegistersItImmediately(previous: PanelCommand) throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let binding = PanelCommand.openClipboard.defaultShortcut
        fixture.defaults.set(try JSONEncoder().encode([previous.rawValue: binding]), forKey: "panelShortcuts")
        let shortcuts = PanelShortcuts(defaults: fixture.defaults)
        var globals: [PanelCommand: KeyShortcut] = [:]
        shortcuts.installGlobals = { globals.merge($0) { _, new in new }; return true }
        shortcuts.installInitialGlobals()
        #expect(globals[.openClipboard] == nil)
        #expect(shortcuts.assign(previous.defaultShortcut, to: previous))
        #expect(globals[.openClipboard] == binding)
        #expect(shortcuts.globalAvailable)
    }

    @Test func globalClipboardCommandOpensSwitchesAndDismissesThePanel() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        let settings = NotchSettings(defaults: fixture.defaults)
        settings.startupFolder = .custom
        settings.customFolder = fixture.directory.path
        settings.hoverEnabled = false
        settings.autoHide = false
        settings.animation = .off
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardHistory(pasteboard: board, defaults: fixture.defaults,
                                         storageURL: fixture.directory.appending(path: "history.plist"))
        let controller = NotchController(settings: settings, clipboardHistory: clipboard)
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        controller.start()
        defer { controller.prepareToShowPreferences() }

        controller.toggleClipboard()
        let panel = try #require(application.windows.first { $0.isVisible && !existingWindows.contains(ObjectIdentifier($0)) })
        #expect(controller.tabs.showsClipboard)
        controller.toggleClipboard()
        #expect(!panel.isVisible)

        controller.toggleClipboard()
        #expect(panel.isVisible && controller.tabs.showsClipboard)
        controller.tabs.closeClipboard()
        #expect(panel.isVisible && !controller.tabs.showsClipboard)
        controller.toggleClipboard()
        #expect(panel.isVisible && controller.tabs.showsClipboard)
        controller.toggleClipboard()
        #expect(!panel.isVisible)
    }

    @Test func nativeQuickLookUsesTheFileIconAndAcceptsPreviewKeysDuringClose() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("Next Folder")
        let file = fixture.directory.appending(path: "Preview.txt")
        try Data("Preview".utf8).write(to: file)
        let app = NSApplication.shared
        let appearance = app.appearance
        defer { app.appearance = appearance }
        let settings = NotchSettings(defaults: fixture.defaults)
        settings.startupFolder = .custom
        settings.customFolder = fixture.directory.path
        settings.hoverEnabled = false
        settings.autoHide = false
        settings.animation = .off
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardHistory(pasteboard: pasteboard, defaults: fixture.defaults,
                                         storageURL: fixture.directory.appending(path: "history.plist"))
        let shortcuts = PanelShortcuts(defaults: fixture.defaults)
        let shortcut = KeyShortcut(kVK_ANSI_P, "p")
        try #require(shortcuts.assign(shortcut, to: .preview))
        let controller = NotchController(settings: settings, shortcuts: shortcuts, clipboardHistory: clipboard)
        let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
        controller.start()
        controller.showPanel()
        defer { controller.prepareToShowPreferences() }
        let browser = try #require(app.windows.compactMap { $0 as? NotchPanel }.first {
            $0.isVisible && $0.title == "Notch Finder" && !existingWindows.contains(ObjectIdentifier($0))
        })
        try await waitUntil { controller.browser.entries.count == 2 }
        let fileEntry = try #require(controller.browser.entries.first { $0.name == file.lastPathComponent })
        let folderEntry = try #require(controller.browser.entries.first { $0.name == folder.lastPathComponent })
        browser.contentView?.layoutSubtreeIfNeeded()
        browser.displayIfNeeded()
        let native = try #require(QLPreviewPanel.shared())
        func sourceFrame() -> NSRect {
            browser.previewPanel(native, sourceFrameOnScreenFor: fileEntry.url as NSURL)
        }
        #expect(sourceFrame().isEmpty)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settings.animation = .standard
            try await waitUntil { !sourceFrame().isEmpty }
            #expect(browser.frame.contains(sourceFrame()))
        }

        settings.animation = .off
        controller.browser.selectItems([folderEntry.id])
        // Quick Look retains control and receives shortcuts while its closing transition runs.
        let ignoredMouse = native.ignoresMouseEvents
        browser.beginPreviewPanelControl(native)
        native.ignoresMouseEvents = true
        defer {
            browser.endPreviewPanelControl(native)
            native.ignoresMouseEvents = ignoredMouse
        }
        let press = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: native.windowNumber, context: nil,
                                                 characters: "p", charactersIgnoringModifiers: "p", isARepeat: false,
                                                 keyCode: shortcut.keyCode))
        #expect(browser.handleNativePreviewKey(press, from: native))
        #expect(browser.visibleFolder == folderEntry.id)
    }

    @Test func openFolderPreviewFollowsTheSelectionUntilClosed() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let first = try fixture.createFolder("First Preview Folder")
        let second = try fixture.createFolder("Second Preview Folder")
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        let settings = NotchSettings(defaults: fixture.defaults)
        settings.startupFolder = .custom
        settings.customFolder = fixture.directory.path
        settings.hoverEnabled = false
        settings.autoHide = false
        settings.animation = .off
        let controller = NotchController(settings: settings, shortcuts: PanelShortcuts(defaults: fixture.defaults),
                                         clipboardHistory: ClipboardHistory(defaults: fixture.defaults,
                                                                            storageURL: fixture.directory.appending(path: "history.plist")))
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        controller.start()
        controller.showPanel()
        defer { controller.prepareToShowPreferences() }
        let browserWindow = try #require(application.windows.first {
            $0.isVisible && $0.title == "Notch Finder" && !existingWindows.contains(ObjectIdentifier($0))
        })

        try await waitUntil { controller.browser.entries.count == 2 }
        let firstEntry = try #require(controller.browser.entries.first { $0.name == first.lastPathComponent })
        let secondEntry = try #require(controller.browser.entries.first { $0.name == second.lastPathComponent })
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: browserWindow.windowNumber, context: nil,
                                                 characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                                                 keyCode: PanelCommand.preview.defaultShortcut.keyCode))
        func visibleFolderPreviews() -> [FolderPreviewPanel] {
            application.windows.compactMap { window in
                guard let preview = window as? FolderPreviewPanel, preview.isVisible,
                      [firstEntry.id, secondEntry.id].contains(preview.folderURL) else { return nil }
                return preview
            }
        }

        controller.browser.selectItems([firstEntry.id])
        browserWindow.sendEvent(space)
        try #require(visibleFolderPreviews().map(\.title) == [firstEntry.name])
        let preview = try #require(visibleFolderPreviews().first)

        browserWindow.makeKeyAndOrderFront(nil)
        controller.browser.selectItems([secondEntry.id])
        try await waitUntil { visibleFolderPreviews().map(\.title) == [secondEntry.name] }
        #expect(visibleFolderPreviews().first === preview)
        #expect(preview.parent === browserWindow)

        browserWindow.sendEvent(space)
        #expect(visibleFolderPreviews().isEmpty)
        #expect(preview.parent == nil)

        controller.browser.selectItems([firstEntry.id])
        browserWindow.contentView?.layoutSubtreeIfNeeded()
        #expect(visibleFolderPreviews().isEmpty)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        settings.animation = .standard
        browserWindow.contentView?.layoutSubtreeIfNeeded()
        browserWindow.displayIfNeeded()
        controller.browser.selectItems([firstEntry.id])
        browserWindow.sendEvent(space)
        let openingPreview = try #require(visibleFolderPreviews().first)
        try #require(openingPreview.alphaValue == 0)

        for entry in [secondEntry, firstEntry, secondEntry] {
            controller.browser.selectItems([entry.id])
            try await waitUntil { visibleFolderPreviews().map(\.title) == [entry.name] }
        }
        try await waitUntil {
            let previews = visibleFolderPreviews()
            return previews.map(\.title) == [secondEntry.name] && previews.first?.alphaValue == 1
        }
        #expect(visibleFolderPreviews().first === openingPreview)
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .leftMouseUp])
    func fileClickTrackingSuppliesAMissingReleaseAfterTheButtonIsUp(dispatching type: NSEvent.EventType) throws {
        let point = NSPoint(x: 20, y: 40)
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.shift],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: 0, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1))
        var isPressed = true
        var releases: [NSEvent] = []
        FileClickTracking.forwardToAppKit(event, isPressed: { isPressed }, postRelease: { releases.append($0) }) {
            // Drive only the event-tracking run loop, without routing mouse events through the test runner.
            let heldUntil = Date(timeIntervalSinceNow: 2 * FileClickTracking.checkInterval)
            while Date() < heldUntil && RunLoop.main.run(mode: .eventTracking, before: heldUntil) {}
            #expect(releases.isEmpty)

            isPressed = false
            let deadline = Date(timeIntervalSinceNow: 0.4)
            while releases.isEmpty && Date() < deadline && RunLoop.main.run(mode: .eventTracking, before: deadline) {}
        }
        let release = try #require(releases.first)
        #expect(releases.count == 1)
        #expect(release.type == .leftMouseUp)
        #expect(release.locationInWindow == point)
        #expect(release.modifierFlags.contains(.shift))
    }

    @Test func disablingRememberLastSizeRestoresDefaultOnNextOpen() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        let settings = NotchSettings(defaults: fixture.defaults)
        settings.startupFolder = .custom
        settings.customFolder = fixture.directory.path
        settings.hoverEnabled = false
        settings.autoHide = false
        settings.animation = .off
        let savedSize = CGSize(width: 540, height: 280)
        NotchGeometry.savePanelSize(savedSize, in: fixture.defaults)
        let controller = NotchController(settings: settings, shortcuts: PanelShortcuts(defaults: fixture.defaults),
                                         clipboardHistory: ClipboardHistory(defaults: fixture.defaults,
                                                                            storageURL: fixture.directory.appending(path: "history.plist")))
        let previousWindows = Set(application.windows.map(ObjectIdentifier.init))
        controller.start()
        controller.showPanel()
        defer { controller.prepareToShowPreferences() }

        let panel = try #require(application.windows.first { $0.isVisible && !previousWindows.contains(ObjectIdentifier($0)) })
        let screen = try #require(panel.screen)
        let notch = NotchGeometry(screen: screen)
        let expectedCustom = NotchGeometry.panelFrame(on: screen, notch: notch, requestedSize: savedSize).size
        let expectedDefault = NotchGeometry.panelFrame(on: screen, notch: notch, requestedSize: NotchGeometry.defaultPanelSize).size
        #expect(panel.frame.size == expectedCustom)

        settings.remembersSize = false
        #expect(panel.frame.size == expectedCustom)
        controller.prepareToShowPreferences()
        controller.showPanel()

        #expect(panel.frame.size == expectedDefault)
        #expect(NotchGeometry.savedPanelSize(in: fixture.defaults) == savedSize)
    }

    @Test func startupPermissionCheckCoversTheOpeningFolderAndTrash() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let readable = try fixture.createFolder("Readable")
        let blocked = try fixture.createFolder("Blocked")
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }

        let missing = fixture.directory.appending(path: "Missing")
        #expect(!FileAccess.needsStartupPermission(for: readable, trashDirectory: readable))
        #expect(FileAccess.needsStartupPermission(for: blocked, trashDirectory: readable))
        #expect(FileAccess.needsStartupPermission(for: readable, trashDirectory: blocked))
        #expect(!FileAccess.needsStartupPermission(for: missing, trashDirectory: readable))
        #expect(!FileAccess.needsStartupPermission(for: nil, trashDirectory: readable))
    }

    @Test func clipboardOpeningRefreshAndPollingSharePrivacyRules() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let archive = fixture.directory.appending(path: "history.plist")
        let history = ClipboardHistory(pasteboard: board, defaults: fixture.defaults, storageURL: archive)
        let tabs = BrowserTabs(initialDirectory: fixture.directory, settings: NotchSettings(defaults: fixture.defaults),
                               clipboardHistory: history)
        tabs.setPanelVisible(true)
        defer { tabs.setPanelVisible(false) }

        let hiddenTypes = ["ConcealedType", "TransientType", "AutoGeneratedType"]
        for type in hiddenTypes {
            try writeText("placeholder", to: board, hiddenType: type)

            tabs.showClipboard()
            #expect(history.timeline.rows.isEmpty)
            try writeText("Visible", to: board)
            history.refreshPreview()
            #expect(history.timeline.current?.contents == .text("Visible"))
            try writeText("other placeholder", to: board, hiddenType: type)
            history.sample(allowPrompt: true)
            #expect(history.timeline.current == nil)
            history.refreshPreview()
            #expect(history.timeline.rows.isEmpty)
            tabs.closeClipboard()
        }

        try writeText("First", to: board)
        tabs.showClipboard()
        #expect(history.timeline.current?.contents == .text("First"))
        #expect(history.entries.isEmpty)

        history.setRecording(true)
        try writeText("Second", to: board)
        history.refreshPreview()
        #expect(history.timeline.rows.map(\.contents) == [.text("Second"), .text("First")])

        let first = try #require(history.timeline.rows.last)
        try #require(history.restore(first) != nil)
        #expect(history.timeline.rows.map(\.contents) == [.text("First"), .text("Second")])
        history.finishSaving()
        let reopened = ClipboardHistory(pasteboard: board, defaults: fixture.defaults, storageURL: archive)
        #expect(reopened.entries.map(\.contents) == [.text("First"), .text("Second")])

        history.clear()
        history.sample(allowPrompt: true)
        #expect(history.entries.isEmpty)
        #expect(history.timeline.rows.map(\.contents) == [.text("First")])
        history.finishSaving()
        history.setRecording(false)
        tabs.setPanelVisible(false)
        try writeText("Hidden", to: board)
        history.sample(allowPrompt: true)
        #expect(history.timeline.current == nil)
        #expect(history.entries.isEmpty)

        history.setRecording(true)
        try writeText("Recorded while hidden", to: board)
        history.sample(allowPrompt: true)
        #expect(history.timeline.current == nil)
        #expect(history.entries.first?.contents == .text("Recorded while hidden"))
        history.setRecording(false)
        history.finishSaving()
    }

    @Test func onlyVisibleTabTracksFileChanges() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: board, defaults: fixture.defaults,
                                       storageURL: fixture.directory.appending(path: "history.plist"))
        let folderA = try fixture.createFolder("A")
        let folderB = try fixture.createFolder("B")
        let tabs = BrowserTabs(initialDirectory: folderA, settings: NotchSettings(defaults: fixture.defaults),
                               clipboardHistory: history)
        let tabA = tabs.active
        tabs.setPanelVisible(true)
        defer { tabs.setPanelVisible(false) }
        try await waitUntil { !tabA.browser.isLoading }

        tabs.add()
        let tabB = tabs.active
        tabs.navigate(to: folderB)
        try await waitUntil { !tabB.browser.isLoading }
        try await Task.sleep(for: .milliseconds(250))
        try touchExternally("inactive.txt", in: folderA)
        try touchExternally("visible.txt", in: folderB)
        try await waitUntil { tabB.browser.entries.map(\.url.lastPathComponent) == ["visible.txt"] }
        #expect(tabA.browser.entries.isEmpty)
        #expect(fixture.defaults.string(forKey: "lastVisitedFolder") == folderB.path)

        tabs.setPanelVisible(false)
        try touchExternally("hidden.txt", in: folderB)
        try await Task.sleep(for: .milliseconds(400))
        #expect(tabB.browser.entries.map(\.url.lastPathComponent) == ["visible.txt"])
        tabs.setPanelVisible(true)
        try await waitUntil { tabB.browser.entries.count == 2 }

        tabs.showClipboard()
        #expect(tabs.showsClipboard)
        try touchExternally("clipboard-is-visible.txt", in: folderB)
        try await Task.sleep(for: .milliseconds(400))
        #expect(tabB.browser.entries.count == 2)
        tabs.select(tabA.id)
        #expect(!tabs.showsClipboard)
        #expect(!tabA.browser.isLoading)
        tabs.select(tabB.id)
        try await waitUntil { tabB.browser.entries.count == 3 }
        #expect(tabA.browser.entries.isEmpty)

        tabs.select(tabA.id)
        try await waitUntil { tabA.browser.entries.map(\.url.lastPathComponent) == ["inactive.txt"] }
    }

    @Test func clipboardPasteReportsPermissionFocusAndStaleContentOutcomes() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: board, defaults: fixture.defaults,
                                       storageURL: fixture.directory.appending(path: "history.plist"))
        var allowed = false
        var accessRequests = 0
        var acquiredFocus = false
        var changedClipboard = false
        var posted = 0
        var dismissed = 0
        var folderIsBusy = true
        var pastedFiles: [URL] = []
        let desktop = ClipboardPaste.Desktop(
            frontmostApplication: {
                ClipboardPaste.Application(name: "Editor", isRunning: { true }, acquireFocus: {
                    if changedClipboard { board.clearContents() }
                    return acquiredFocus
                }, postPaste: {
                    posted += 1
                    return true
                })
            },
            canPostEvents: { allowed },
            requestEventAccess: { accessRequests += 1; return false }
        )
        let paste = ClipboardPaste(history: history, desktop: desktop, folder: {
            ClipboardPaste.Folder(available: !folderIsBusy) { pastedFiles = $0 }
        }, dismissPanel: { dismissed += 1 })
        paste.captureTarget()

        try writeText("Text to paste", to: board)
        let row = ClipboardHistory.Row.current(.init(contents: .text("Text to paste"), changeCount: board.changeCount))
        #expect(await paste.paste(row) == .copied)
        #expect(await paste.paste(row) == .copied)
        #expect(accessRequests == 1)
        #expect(dismissed == 0)

        allowed = true
        #expect(await paste.paste(row) == .copied)
        #expect(posted == 0)
        acquiredFocus = true
        changedClipboard = true
        #expect(await paste.paste(row) == .unavailable)
        #expect(paste.destination(for: row) == nil)
        #expect(posted == 0)

        changedClipboard = false
        try writeText("Fresh", to: board)
        let fresh = ClipboardHistory.Row.current(.init(contents: .text("Fresh"), changeCount: board.changeCount))
        #expect(await paste.paste(fresh) == .posted)
        #expect(posted == 1)

        let files = ClipboardHistory.Row.current(.init(contents: .files([fixture.directory]), changeCount: board.changeCount))
        #expect(paste.destination(for: files)?.isAvailable == false)
        #expect(await paste.paste(files) == .unavailable)
        #expect(pastedFiles.isEmpty)
        folderIsBusy = false
        #expect(await paste.paste(files) == .started)
        #expect(pastedFiles == [fixture.directory])
    }

    @Test func panelAutoHideUsesTheSameHoldOpenRulesForHoverAndDrops() {
        func sample(_ now: TimeInterval, inside: Bool = false, trigger: Bool = false,
                    tracking: Bool = false, resizing: Bool = false,
                    preview: Bool = false, automaticHide: Bool = true) -> PanelVisibility.Sample {
            .init(now: now, insideTrigger: trigger, insideAnyTrigger: trigger, insidePanel: inside,
                  mouseDown: false, trackingEvents: tracking, resizing: resizing, editing: false,
                  previewVisible: preview, automaticHide: automaticHide, showDelay: 0, hideDelay: 1)
        }

        var panel = PanelVisibility()
        panel.didShow(manually: false)
        panel.fileDragEnded(now: 0, hideDelay: 1, automaticHide: true)
        #expect(panel.update(sample(1, inside: true, tracking: true)) { true } == nil)
        panel.fileDragEnded(now: 2, hideDelay: 1, automaticHide: true)
        #expect(panel.update(sample(3, tracking: true, resizing: true)) { false } == nil)
        panel.fileDragEnded(now: 4, hideDelay: 1, automaticHide: true)
        #expect(panel.update(sample(5, tracking: true, automaticHide: false)) { false } == nil)
        panel.fileDragEnded(now: 6, hideDelay: 1, automaticHide: true)
        #expect(panel.update(sample(7, trigger: true, tracking: true)) { false } == .hide(suppressUntilExit: true))
        panel.didHide(suppressUntilExit: true)
        #expect(panel.update(sample(8, trigger: true, tracking: true)) { false } == nil)
        #expect(panel.update(sample(9)) { false } == nil)
        #expect(panel.update(sample(10, trigger: true)) { false } == .show)

        panel.didShow(manually: false)
        #expect(panel.update(sample(11, preview: true)) { false } == nil)
        #expect(panel.update(sample(12)) { false } == nil)
        #expect(panel.update(sample(14)) { false } == nil)
        #expect(panel.update(sample(15, inside: true)) { true } == nil)
        #expect(panel.update(sample(16)) { false } == nil)
        #expect(panel.update(sample(17)) { false } == .hide(suppressUntilExit: false))
    }

    @Test func switchingContentDiscardsLateFolderResultsAndRestartsSpotlightSearches() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let folder = try fixture.createFolder("Folder")
        try Data().write(to: folder.appending(path: "Initial.txt"))
        let initial = try await FileBrowser.readContents(of: folder, includeHidden: false)
        let settings = NotchSettings(defaults: fixture.defaults)
        let history = ClipboardHistory(pasteboard: board, defaults: fixture.defaults,
                                       storageURL: fixture.directory.appending(path: "history.plist"))
        var delayedRead: CheckedContinuation<[FileEntry], Never>?
        var delayFirstRead = true
        var didReturnLate = false
        var searchStreams: [(SpotlightFileSearch.Scope, AsyncThrowingStream<[FileEntry], Error>.Continuation)] = []
        let source = BrowserContentRefresh.Source(
            read: { destination, includeHidden in
                if delayFirstRead {
                    delayFirstRead = false
                    let files = await withCheckedContinuation { delayedRead = $0 }
                    didReturnLate = true
                    return files
                }
                return try await FileBrowser.readContents(at: destination, includeHidden: includeHidden)
            },
            searchUpdates: { scope, _ in
                let (stream, continuation) = AsyncThrowingStream<[FileEntry], Error>.makeStream()
                searchStreams.append((scope, continuation))
                return stream
            }
        )
        let tabs = BrowserTabs(initialDirectory: folder, settings: settings, clipboardHistory: history,
                               contentSource: source)
        let browser = tabs.active.browser
        tabs.setPanelVisible(true)
        defer {
            tabs.setPanelVisible(false)
            searchStreams.forEach { $0.1.finish() }
        }
        try await waitUntil { delayedRead != nil }
        tabs.showClipboard()
        delayedRead?.resume(returning: initial)
        try await waitUntil { didReturnLate }
        #expect(browser.entries.isEmpty)
        #expect(!browser.isLoading)

        tabs.closeClipboard()
        try await waitUntil { browser.entries == initial }
        tabs.showRecentItems()
        try await waitUntil { searchStreams.count == 1 }
        #expect(searchStreams[0].0 == .recents)
        searchStreams[0].1.yield(initial)
        try await waitUntil { browser.entries == initial }
        tabs.setPanelVisible(false)
        if case .terminated = searchStreams[0].1.yield([]) {
            #expect(browser.entries == initial)
        } else {
            Issue.record("The old Recents stream accepted an update after the panel was hidden")
        }

        tabs.setPanelVisible(true)
        try await waitUntil { searchStreams.count == 2 }
        #expect(searchStreams[1].0 == .recents)
        searchStreams[1].1.yield([])
        try await waitUntil { !browser.isLoading && browser.entries.isEmpty }

        tabs.navigate(to: folder)
        tabs.showClipboard()
        tabs.showTag("Project")
        try await waitUntil { searchStreams.last?.0 == .tag("Project") }
        searchStreams.last?.1.yield(initial)
        try await waitUntil { browser.entries == initial }
        #expect(!tabs.showsClipboard)
        #expect(browser.title == "Project")
        #expect(!browser.canGoUp)
        browser.beginEditing(.createFolder)
        #expect(browser.editing == nil)

        browser.goBack()
        #expect(browser.destination == .folder(folder))
        let previousSearchCount = searchStreams.count
        tabs.goForward()
        try await waitUntil { searchStreams.count > previousSearchCount }
        #expect(browser.destination == .tag("Project"))
        #expect(searchStreams.last?.0 == .tag("Project"))
    }

    @Test func expandedTagFolderTracksUntaggedFilesWithoutASpotlightUpdate() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let tagged = try fixture.createFolder("Tagged")
        let nested = tagged.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let roots = try await FileBrowser.readContents(of: fixture.directory, includeHidden: false)
        let children = try await FileBrowser.readContents(of: tagged, includeHidden: false)
        let (stream, continuation) = AsyncThrowingStream<[FileEntry], Error>.makeStream()
        let source = BrowserContentRefresh.Source(read: BrowserContentRefresh.Source.live.read, searchUpdates: { _, _ in stream })
        let browser = FileBrowser(initialDirectory: fixture.directory, settings: NotchSettings(defaults: fixture.defaults),
                                  contentSource: source)
        browser.setContentActive(true, revalidation: .immediately)
        defer {
            browser.setContentActive(false, revalidation: .immediately)
            continuation.finish()
        }
        browser.showTag("Tagged")
        browser.setDisplayMode(.list)
        continuation.yield(roots)
        try await waitUntil { browser.entries == roots }
        let taggedEntry = try #require(roots.first)
        let nestedEntry = try #require(children.first)
        browser.toggleExpansion(of: taggedEntry)
        try await waitUntil { browser.expandedFolders[taggedEntry.id]?.map(\.name) == [nestedEntry.name] }
        browser.toggleExpansion(of: nestedEntry)
        try await waitUntil { !browser.isLoadingContents(of: nestedEntry.id) }
        try touchExternally("New.txt", in: nested)
        try await waitUntil { browser.expandedFolders[nestedEntry.id]?.map(\.name) == ["New.txt"] }
    }

    @Test func taggedFolderExpandsWithOverlappingSpotlightResults() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("Tagged Folder")
        try Data().write(to: folder.appending(path: "Also Tagged.txt"))
        let roots = try await FileBrowser.readContents(of: fixture.directory, includeHidden: false)
        let children = try await FileBrowser.readContents(of: folder, includeHidden: false)
        let taggedFolder = try #require(roots.first)
        let child = try #require(children.first)
        let source = BrowserContentRefresh.Source(read: { destination, hidden in
            if case .tag = destination { return [child, taggedFolder] }
            return try await FileBrowser.readContents(at: destination, includeHidden: hidden)
        }, searchUpdates: BrowserContentRefresh.Source.live.searchUpdates)
        let browser = FileBrowser(initialDirectory: fixture.directory, settings: NotchSettings(defaults: fixture.defaults),
                                  contentSource: source)
        browser.showTag("Project")
        browser.setDisplayMode(.list)
        try await waitUntil { browser.entries.count == 2 }
        browser.toggleExpansion(of: taggedFolder)
        try await waitUntil { browser.expandedFolders[taggedFolder.id]?.count == 1 }
        #expect(browser.listing.entries.map(\.id) == [taggedFolder.id, child.id])
        #expect(browser.listing.depth(of: child.id) == 1)
        browser.filter = "Also Tagged"
        #expect(browser.listing.entries.map(\.id) == [child.id])
        #expect(browser.listing.depth(of: child.id) == 0)

        browser.filter = ""
        browser.setDisplayMode(.columns)
        browser.selectColumnItems([taggedFolder.id], in: nil)
        #expect(browser.listing.entries(in: taggedFolder.id).map(\.id) == [child.id])
        browser.selectColumnItems([child.id], in: taggedFolder.id)
        #expect(browser.entries(matching: browser.selection).map(\.id) == [child.id])
    }

    @Test func folderReadPreservesSystemDisplayNamesAndRawFilenameSearch() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("Names")
        for name in ["plain.txt", "résumé.txt", "Icon\r", ".dotfile"] {
            try Data().write(to: folder.appending(path: name))
        }
        var hiddenExtension = folder.appending(path: "hidden-extension.txt")
        try Data().write(to: hiddenExtension)
        var properties = URLResourceValues()
        properties.hasHiddenExtension = true
        try hiddenExtension.setResourceValues(properties)
        let localized = folder.appending(path: "Sample.localized", directoryHint: .isDirectory)
        let translations = localized.appending(path: ".localized", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: translations, withIntermediateDirectories: true)
        try Data(#""Sample" = "Translated";"#.utf8).write(to: translations.appending(path: "en.strings"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "Folder Link"), withDestinationURL: localized)

        let browser = FileBrowser(initialDirectory: folder, settings: NotchSettings(defaults: fixture.defaults))
        browser.reload()
        try await waitUntil { !browser.isLoading }
        #expect(browser.entries.count == 6)
        for entry in browser.entries {
            let expected = try entry.url.resourceValues(forKeys: [.localizedNameKey]).localizedName
            #expect(entry.name == (expected ?? entry.url.lastPathComponent))
        }
        browser.filter = "hidden-extension.txt"
        #expect(browser.displayedEntries.map(\.url.lastPathComponent) == ["hidden-extension.txt"])
        let includingHidden = try await FileBrowser.readContents(of: folder, includeHidden: true)
        #expect(includingHidden.contains { $0.url.lastPathComponent == ".dotfile" })
    }

    @Test func ejectingAVolumeClearsItsNavigationWithoutAffectingASimilarlyNamedVolume() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let disk = try fixture.createFolder("Disk")
        let otherDisk = try fixture.createFolder("Disk 1")
        let child = disk.appending(path: "Files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let browser = FileBrowser(initialDirectory: child, settings: NotchSettings(defaults: fixture.defaults))

        browser.navigate(to: otherDisk)
        browser.volumeDidUnmount(at: disk)
        #expect(browser.directory == otherDisk)
        #expect(!browser.canGoBack)

        browser.navigate(to: child)
        browser.volumeDidUnmount(at: disk)
        #expect(browser.directory == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
        browser.goBack()
        #expect(browser.directory == otherDisk)
    }

    @Test func listingSelectionUsesVisibleSortedRows() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("Folder")
        for name in ["A-root.txt", "Z-root.txt"] {
            try Data().write(to: fixture.directory.appending(path: name))
        }
        for name in ["A-child.txt", "Z-child.txt"] {
            try Data().write(to: folder.appending(path: name))
        }
        let settings = NotchSettings(defaults: fixture.defaults)
        let browser = FileBrowser(initialDirectory: fixture.directory, settings: settings)
        browser.reload()
        try await waitUntil { browser.entries.count == 3 }
        let folderEntry = browser.entries.first(where: \.canExpand)
        let expandable = try #require(folderEntry)
        browser.toggleExpansion(of: expandable)
        try await waitUntil { browser.expandedFolders[expandable.url]?.count == 2 }

        browser.setTableSortOrder([KeyPathComparator(\.name, comparator: .localizedStandard, order: .reverse)])
        let detailed = browser.listing
        #expect(detailed.entries.map(\.url.lastPathComponent) == [
            "Folder", "Z-child.txt", "A-child.txt", "Z-root.txt", "A-root.txt"
        ])
        #expect(detailed.groups == nil)
        #expect(detailed.selected(detailed.visibleIDs) == detailed.entries)

        let child = try #require(detailed.entries.first { $0.name == "Z-child.txt" })
        browser.selectItems([child.id])
        #expect(browser.selection == [child.id])
        browser.setDisplayMode(.icons)
        let grid = browser.listing
        #expect(grid.entries.map(\.url.lastPathComponent) == ["Folder", "Z-root.txt", "A-root.txt"])
        #expect(grid.selected(detailed.visibleIDs) == grid.entries)
        #expect(browser.selection.isEmpty)
        #expect(browser.entries(matching: [child.id]).isEmpty)
        browser.setDisplayMode(.gallery)
        #expect(browser.listing.entries == grid.entries)

        let hiddenRoot = try #require(grid.entries.first { $0.name == "Z-root.txt" })
        browser.selectItems([hiddenRoot.id])
        browser.filter = "A-root"
        let filteredGallery = browser.listing
        #expect(filteredGallery.selected(detailed.visibleIDs).map(\.url.lastPathComponent) == ["A-root.txt"])
        #expect(browser.selection.isEmpty)
        browser.beginEditing(.rename(hiddenRoot.id))
        #expect(browser.editing == nil)
        var preview: [FileEntry] = []
        browser.onPreview = { preview = $0 }
        browser.showPreview([hiddenRoot.id])
        #expect(preview.isEmpty)
        browser.selectAll()
        browser.showPreview(browser.selection)
        #expect(preview.map(\.id.lastPathComponent) == ["A-root.txt"])
    }

    @Test func clickingInALargeSortedListSkipsSorting() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let files = (0..<10_000).map { index in
            let name = "Item-\(index)"
            return FileEntry(url: fixture.directory.appending(path: name), name: name, isFolder: false,
                             isSymbolicLink: false, fileKind: .file, fileSize: 0, modified: .distantPast, added: .distantPast)
        }
        let source = BrowserContentRefresh.Source(read: { _, _ in files }, searchUpdates: BrowserContentRefresh.Source.live.searchUpdates)
        let browser = FileBrowser(initialDirectory: fixture.directory, settings: NotchSettings(defaults: fixture.defaults),
                                  contentSource: source)
        browser.setDisplayMode(.list)
        browser.reload()
        try await waitUntil { browser.entries.count == files.count }
        browser.setTableSortOrder([KeyPathComparator(\FileEntry.countedSortKey, order: .reverse)])
        let target = try #require(files.last?.id)
        let readsBeforeClick = sortKeyReads.withLock { $0 }
        browser.selectItems([target])
        #expect(browser.selection == [target])
        #expect(sortKeyReads.withLock { $0 } == readsBeforeClick)
        #expect(browser.listing.entries.first?.id == target)
        #expect(sortKeyReads.withLock { $0 } > readsBeforeClick)
    }

    @Test func wideListRestoresNarrowedColumnsAfterFolderNavigation() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let other = try fixture.createFolder("Other")
        let settings = NotchSettings(defaults: fixture.defaults)
        let browser = FileBrowser(initialDirectory: fixture.directory, settings: settings)
        func list() -> some View {
            FileList(browser: browser, settings: settings, listing: browser.listing,
                     releaseSearchFocus: {}, onFileDragEnded: {},
                     columnCustomization: settings.fileListColumnStorage(for: browser.destination))
                .defaultAppStorage(fixture.defaults)
                .id(browser.destination)
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 830, height: 430),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSHostingView(rootView: list())
        window.contentView = host
        let center = NSPoint(x: 415, y: 215)
        func currentTable() -> NSTableView? {
            host.layoutSubtreeIfNeeded()
            return window.table(at: center)
        }
        try await waitUntil { currentTable()?.numberOfColumns == 4 }
        let table = try #require(currentTable())
        settings.beginCustomizingFileListColumns(for: browser.destination)
        table.tableColumns[0].width -= 64
        table.sizeLastColumnToFit()
        let expected = table.rect(ofColumn: 1).minX
        browser.navigate(to: other)
        host.rootView = list()
        try await waitUntil { currentTable().map { $0 !== table } == true }
        let otherTable = try #require(currentTable())
        browser.goBack()
        host.rootView = list()
        try await waitUntil { currentTable().map { $0 !== otherTable } == true }
        let restored = try #require(currentTable())
        #expect(abs(restored.rect(ofColumn: 1).minX - expected) <= 1)
    }

    @Test func legacyListPreferencesAndNewDisplayModes() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        for oldMode in ["details", "compact"] {
            fixture.defaults.set(oldMode, forKey: "fileDisplayMode")
            #expect(NotchSettings(defaults: fixture.defaults).defaultDisplayMode == .list)
        }
        let settings = NotchSettings(defaults: fixture.defaults)
        #expect(FileDisplayMode.allCases == [.icons, .list, .columns, .gallery])
        for mode in FileDisplayMode.allCases {
            settings.defaultDisplayMode = mode
            #expect(NotchSettings(defaults: fixture.defaults).defaultDisplayMode == mode)
        }
    }

    @Test func locationsRememberTheirViewsAcrossTabsAndSettingsReload() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        fixture.defaults.set("details", forKey: "fileDisplayMode")
        let settings = NotchSettings(defaults: fixture.defaults)
        let firstFolder = try fixture.createFolder("First")
        let secondFolder = try fixture.createFolder("Second")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: board, defaults: fixture.defaults,
                                       storageURL: fixture.directory.appending(path: "history.plist"))
        let tabs = BrowserTabs(initialDirectory: firstFolder, settings: settings, clipboardHistory: history)
        let firstTab = tabs.active
        let trash = try #require(firstTab.browser.sidebar.locationItems.first(where: { $0.symbol == "trash" })?.url)

        func modeInActiveTab() -> FileDisplayMode {
            tabs.active.browser.listing.displayMode
        }

        #expect(modeInActiveTab() == .list)
        settings.setDisplayMode(.list, for: firstTab.browser.destination)
        tabs.add()
        let secondTab = tabs.active
        tabs.navigate(to: secondFolder)
        #expect(modeInActiveTab() == .list)
        settings.setDisplayMode(.gallery, for: secondTab.browser.destination)
        tabs.showRecentItems()
        #expect(modeInActiveTab() == .list)
        settings.setDisplayMode(.columns, for: secondTab.browser.destination)
        tabs.navigate(to: trash)
        #expect(modeInActiveTab() == .list)
        settings.setDisplayMode(.icons, for: secondTab.browser.destination)

        tabs.select(firstTab.id)
        #expect(modeInActiveTab() == .list)
        tabs.navigate(to: secondFolder)
        #expect(modeInActiveTab() == .gallery)
        tabs.select(secondTab.id)
        #expect(modeInActiveTab() == .icons)
        secondTab.browser.goBack()
        #expect(modeInActiveTab() == .columns)
        secondTab.browser.goBack()
        #expect(modeInActiveTab() == .gallery)
        tabs.goForward()
        #expect(modeInActiveTab() == .columns)
        #expect(settings.defaultDisplayMode == .list)

        settings.defaultDisplayMode = .gallery
        let reloaded = NotchSettings(defaults: fixture.defaults)
        #expect(reloaded.displayMode(for: .folder(firstFolder)) == .list)
        #expect(reloaded.displayMode(for: .folder(secondFolder)) == .gallery)
        #expect(reloaded.displayMode(for: .recentItems) == .columns)
        #expect(reloaded.displayMode(for: .folder(trash)) == .icons)
        #expect(reloaded.displayMode(for: .folder(fixture.directory)) == .gallery)
    }

    @Test func columnsFollowSelectionAndPreserveInlineExpansion() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let firstFolder = try fixture.createFolder("First")
        _ = try fixture.createFolder("Second")
        let nestedFolder = firstFolder.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: false)
        try Data().write(to: nestedFolder.appending(path: "Leaf.txt"))

        let settings = NotchSettings(defaults: fixture.defaults)
        let browser = FileBrowser(initialDirectory: fixture.directory, settings: settings)
        browser.reload()
        try await waitUntil { browser.entries.count == 2 }
        let first = try #require(browser.entries.first { $0.url.lastPathComponent == "First" }).id
        let second = try #require(browser.entries.first { $0.url.lastPathComponent == "Second" })
        browser.toggleExpansion(of: second)
        browser.setDisplayMode(.columns)
        browser.selectColumnItems([first], in: nil)
        try await waitUntil { !browser.listing.entries(in: first).isEmpty }
        let nested = try #require(browser.listing.entries(in: first).first).id
        #expect(nested.lastPathComponent == "Nested")
        browser.selectColumnItems([nested], in: first)
        try await waitUntil { !browser.listing.entries(in: nested).isEmpty }
        let leaf = try #require(browser.listing.entries(in: nested).first).id
        #expect(leaf.lastPathComponent == "Leaf.txt")
        browser.selectColumnItems([leaf], in: nested)
        let listing = browser.listing
        #expect(listing.columns.map(\.id) == [nil, first, nested])
        #expect(listing.selected(browser.selection).map(\.id) == [leaf])
        #expect(browser.entries(matching: browser.selection).map(\.id) == [leaf])
        #expect(browser.activeColumn == nested)
        #expect(!browser.isExpandedInList(first))

        browser.filter = "Second"
        #expect(browser.columnPath.isEmpty)
        #expect(browser.activeColumn == nil)
        #expect(browser.selection.isEmpty)
        #expect(browser.isExpandedInList(second.id))
        #expect(browser.listing.entries.map(\.id) == [second.id])
    }

    @Test func removingAnExpandedParentDropsItsSelectionAndCommandTargets() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let root = try fixture.createFolder("Root")
        let parent = root.appending(path: "Parent", directoryHint: .isDirectory)
        let nested = parent.appending(path: "Nested", directoryHint: .isDirectory)
        let leaf = nested.appending(path: "Selected.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: leaf)
        let browser = FileBrowser(initialDirectory: root, settings: NotchSettings(defaults: fixture.defaults))
        browser.setDisplayMode(.columns)
        browser.setContentActive(true, revalidation: .immediately)
        defer { browser.setContentActive(false, revalidation: .immediately) }
        try await waitUntil { browser.entries.count == 1 }
        let parentID = try #require(browser.listing.entries.first?.id)
        browser.selectColumnItems([parentID], in: nil)
        try await waitUntil { browser.listing.entries(in: parentID).count == 1 }
        let nestedID = try #require(browser.listing.entries(in: parentID).first?.id)
        browser.selectColumnItems([nestedID], in: parentID)
        try await waitUntil { browser.listing.entries(in: nestedID).count == 1 }
        let leafID = try #require(browser.listing.entries(in: nestedID).first?.id)
        browser.selectColumnItems([leafID], in: nestedID)
        #expect(browser.listing.columns.last?.selected(from: browser.selection) == [leafID])

        // Move the subtree out from under the active column, as Finder could do.
        let move = Process()
        move.executableURL = URL(fileURLWithPath: "/bin/mv")
        move.arguments = [parent.path, fixture.directory.appending(path: "Moved").path]
        try move.run()
        move.waitUntilExit()
        try #require(move.terminationStatus == 0)
        try await waitUntil { browser.listing.entries.isEmpty }
        #expect(browser.listing.columns.count == 1 && browser.activeColumn == nil)
        #expect(browser.selection.isEmpty)
        #expect(browser.entries(matching: [leafID]).isEmpty)
        browser.onPreview = { _ in Issue.record("A removed file cannot be previewed") }
        browser.showPreview([leafID])
        browser.beginEditing(.rename(leafID))
        #expect(browser.editing == nil)
    }

    @Test func downloadsAndTrashGroupOnlyInListView() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let settings = NotchSettings(defaults: fixture.defaults)
        let downloads = try #require(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        let sidebar = SidebarLocations(defaults: fixture.defaults)
        let trash = try #require(sidebar.locationItems.first(where: { $0.symbol == "trash" })?.url)
        let destinations = [downloads, trash].map { FileBrowser(initialDirectory: $0, settings: settings) }
        let children = [downloads, trash].map {
            FileBrowser(initialDirectory: $0.appending(path: "Archive"), settings: settings)
        }
        let namesakes = try ["Downloads", ".Trash"].map {
            FileBrowser(initialDirectory: try fixture.createFolder($0), settings: settings)
        }

        for browser in destinations {
            #expect(browser.listing.groups != nil)
        }
        for browser in children + namesakes {
            #expect(browser.listing.groups == nil)
        }

        for mode in [FileDisplayMode.icons, .columns, .gallery] {
            for browser in destinations {
                browser.setDisplayMode(mode)
                #expect(browser.listing.groups == nil)
            }
        }
        for browser in destinations {
            browser.setDisplayMode(.list)
            #expect(browser.listing.groups != nil)
        }
        settings.groupsByAddedDate = false
        for browser in destinations {
            #expect(browser.listing.groups == nil)
        }
    }

    @Test func appearanceChangesPublishCompleteAndMigratedPreferences() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let defaults = fixture.defaults
        defaults.set("dracula", forKey: "panelStylePreset")
        defaults.set("dark", forKey: PanelTheme.preferenceKey)
        defaults.set("rounded", forKey: "panelFontStyle")
        defaults.set(0x112233, forKey: "panelCustomAccent")
        defaults.set("large", forKey: "fileIconSize")

        let settings = NotchSettings(defaults: defaults)
        #expect(settings.appearance.preset(for: .dark).title == "Dracula")
        #expect(settings.appearance.preset(for: .light) == .native)
        #expect(settings.appearance.fontStyle == .rounded)
        #expect(settings.appearance.accentValue(for: .dark) == 0x112233)
        var published: [PanelAppearance] = []
        settings.colorModeDidChange = { [weak settings] _ in
            if let settings { published.append(settings.appearance) }
        }

        settings.setCustomAccent(nil)
        settings.selectStylePreset(try #require(PanelStylePreset(rawValue: "proof")), for: .light)
        #expect(published.isEmpty)
        #expect(settings.appearance.colorMode == .dark)
        settings.selectColorMode(.light)
        #expect(published.count == 1)
        #expect(published.first?.preset(for: .light).title == "Proof")
        #expect(published.first?.preset(for: .dark).title == "Dracula")
        #expect(published.first?.colorMode == .light)
        #expect(settings.appearance.accentValue(for: .light) == 0x3D755D)
        #expect(settings.appearance.accentColor(for: .light).flatMap(PanelRGB.value(of:)) == 0x3D755D)

        let reopened = NotchSettings(defaults: defaults)
        #expect(reopened.appearance == settings.appearance)
        reopened.restoreDefaultAppearance()
        let reset = NotchSettings(defaults: defaults)
        #expect(reset.appearance == PanelAppearance())
        #expect(reset.interfaceSize == .medium)
    }

    @Test func interfaceSizeUsesTheSystemBaselineAndPersists() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let settings = NotchSettings(defaults: fixture.defaults)
        #expect(settings.interfaceSize == .small)
        #expect(settings.interfaceSize.panelText == NSFont.systemFontSize)
        #expect(FileDisplaySize.allCases.map { $0.panelIcon - NSFont.systemFontSize } == [2, 4, 6])
        #expect(FileDisplaySize.allCases.map { $0.row.icon } == [20, 24, 28])
        #expect(FileDisplaySize.allCases.map { $0.grid.icon } == [56, 64, 72])

        fixture.defaults.set("large", forKey: "fileIconSize")
        fixture.defaults.set("medium", forKey: "fileTextSize")
        let upgraded = NotchSettings(defaults: fixture.defaults)
        #expect(upgraded.interfaceSize == .small)
        upgraded.interfaceSize = .large
        #expect(NotchSettings(defaults: fixture.defaults).interfaceSize == .large)
    }

    @Test func gridIconSizePersistsIndependentlyOfInterfaceSize() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        fixture.defaults.set("medium", forKey: "interfaceSize")
        let settings = NotchSettings(defaults: fixture.defaults)
        #expect(settings.gridIconSize == 64)

        settings.gridIconSize = 91.5
        let reopened = NotchSettings(defaults: fixture.defaults)
        #expect(reopened.gridIconSize == 91.5)
        #expect(reopened.interfaceSize == .medium)

        reopened.interfaceSize = .large
        #expect(reopened.gridIconSize == 91.5)
        reopened.gridIconSize = 200
        #expect(NotchSettings(defaults: fixture.defaults).gridIconSize == NotchSettings.gridIconSizes.upperBound)
    }

    @Test func themePresetsShowSystemFirstThenAlphabeticalNames() {
        for presets in [PanelStylePreset.available(in: .light), PanelStylePreset.available(in: .dark)] {
            #expect(presets.first == .native)
            let names = presets.dropFirst().map(\.title)
            #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
    }

    @Test func lightAndDarkThemeChoicesSurviveModeChangesAndRelaunch() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        fixture.defaults.set(["mode": "system", "preset": "github", "font": "system"], forKey: "panelAppearance")
        let settings = NotchSettings(defaults: fixture.defaults)
        let github = try #require(PanelStylePreset(rawValue: "github"))
        let proof = try #require(PanelStylePreset(rawValue: "proof"))
        let dracula = try #require(PanelStylePreset(rawValue: "dracula"))

        #expect(settings.appearance.preset(for: .light) == github)
        #expect(settings.appearance.preset(for: .dark) == github)
        settings.selectStylePreset(proof, for: .light)
        settings.selectStylePreset(dracula, for: .dark)
        settings.selectStylePreset(proof, for: .dark)
        #expect(settings.appearance.colorMode == .system)

        settings.selectColorMode(.dark)
        settings.selectColorMode(.light)
        settings.selectColorMode(.system)
        let reloaded = NotchSettings(defaults: fixture.defaults).appearance
        #expect(reloaded.colorMode == .system)
        #expect(reloaded.preset(for: .light) == proof)
        #expect(reloaded.preset(for: .dark) == dracula)
        #expect(reloaded.accentValue(for: .light) == 0x3D755D)
        #expect(reloaded.accentValue(for: .dark) == 0xFF79C6)
    }

    @Test func preferencesPageSurvivesReopeningSettings() throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let settings = NotchSettings(defaults: fixture.defaults)
        #expect(settings.preferencesPage == .triggers)

        settings.preferencesPage = .clipboard
        #expect(NotchSettings(defaults: fixture.defaults).preferencesPage == .clipboard)

        fixture.defaults.set("unknown", forKey: "preferencesPage")
        #expect(NotchSettings(defaults: fixture.defaults).preferencesPage == .triggers)
    }

    @Test func preferencesPlacementUsesAvailableSpaceOnPanelDisplay() {
        let display = CGRect(x: -2_000, y: 50, width: 2_000, height: 1_000)
        let size = CGSize(width: 680, height: 480)
        let leftPanel = CGRect(x: -1_900, y: 630, width: 700, height: 420)
        let rightPanel = CGRect(x: -800, y: 630, width: 700, height: 420)
        let widePanel = CGRect(x: -1_600, y: 630, width: 1_200, height: 420)

        let right = NotchGeometry.preferencesFrame(size: size, beside: leftPanel, in: display)
        let left = NotchGeometry.preferencesFrame(size: size, beside: rightPanel, in: display)
        let below = NotchGeometry.preferencesFrame(size: size, beside: widePanel, in: display)

        #expect(right.minX == leftPanel.maxX + 12)
        #expect(left.maxX == rightPanel.minX - 12)
        #expect(below.maxY == widePanel.minY - 12)
        #expect(below.midX == widePanel.midX)
        #expect([right, left, below].allSatisfy { display.contains($0) && $0.size == size })
    }

    @Test func sizeSortPreservesFoldersTiesAndSecondaryColumns() async throws {
        let fixture = try TestWorkspace()
        defer { fixture.cleanUp() }
        let folder = try fixture.createFolder("Folder")
        for (name, size) in [("A.txt", 20), ("B.txt", 20), ("C.txt", 5)] {
            try Data(repeating: 0, count: size).write(to: fixture.directory.appending(path: name))
            try Data(repeating: 0, count: size).write(to: folder.appending(path: name))
        }
        let settings = NotchSettings(defaults: fixture.defaults)
        let browser = FileBrowser(initialDirectory: fixture.directory, settings: settings)
        settings.fileSort = .size
        settings.groupsByAddedDate = false
        browser.reload()
        try await waitUntil { browser.entries.count == 4 }
        let folderEntry = browser.entries.first(where: \.canExpand)
        let expandable = try #require(folderEntry)
        browser.toggleExpansion(of: expandable)
        try await waitUntil { browser.expandedFolders[expandable.url]?.count == 3 }

        func names() -> [String] {
            browser.listing.entries.map(\.url.lastPathComponent)
        }

        let descending = ["Folder", "A.txt", "B.txt", "C.txt", "A.txt", "B.txt", "C.txt"]
        #expect(names() == descending)
        browser.setTableSortOrder([KeyPathComparator(\.fileSize, order: .reverse)])
        #expect(names() == descending)
        let ascending = KeyPathComparator<FileEntry>(\.fileSize)
        browser.setTableSortOrder([ascending])
        #expect(names() == ["Folder", "C.txt", "A.txt", "B.txt", "C.txt", "A.txt", "B.txt"])
        browser.setTableSortOrder([ascending, KeyPathComparator(\.name, order: .reverse)])
        #expect(names() == ["Folder", "C.txt", "B.txt", "A.txt", "C.txt", "B.txt", "A.txt"])

        settings.foldersFirst = false
        browser.setTableSortOrder([])
        #expect(names() == ["A.txt", "B.txt", "C.txt", "Folder", "A.txt", "B.txt", "C.txt"])
    }

    private func writeText(_ text: String, to board: NSPasteboard, hiddenType: String? = nil) throws {
        let item = NSPasteboardItem()
        try #require(item.setString(text, forType: .string))
        if let hiddenType {
            try #require(item.setString("1", forType: .init("org.nspasteboard." + hiddenType)))
        }
        board.clearContents()
        try #require(board.writeObjects([item]))
    }

    private func touchExternally(_ name: String, in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [folder.appending(path: name).path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}

private let sortKeyReads = OSAllocatedUnfairLock(initialState: 0)

private extension FileEntry {
    var countedSortKey: String {
        sortKeyReads.withLock { $0 += 1 }
        return name
    }
}

private struct TestWorkspace {
    let directory: URL
    let defaults: UserDefaults
    private let identifier = "local.notchfinder.tests." + UUID().uuidString

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: identifier, directoryHint: .isDirectory)
        defaults = try #require(UserDefaults(suiteName: identifier))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func createFolder(_ name: String) throws -> URL {
        let folder = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: identifier)
        try? FileManager.default.removeItem(at: directory)
    }
}
