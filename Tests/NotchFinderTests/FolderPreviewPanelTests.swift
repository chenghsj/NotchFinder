import AppKit
import Carbon.HIToolbox
import Testing
@testable import NotchFinder

@Suite(.serialized)
@MainActor
struct FolderPreviewPanelTests {
    @Test func spaceReopensFolderPreviewDuringClose() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let preview = makePreview()
        defer { preview.close() }
        try show(preview)
        // Opening is setup for the close/reopen assertion. Other AppKit tests share the main run loop.
        try await waitUntil(timeout: .seconds(4)) { preview.alphaValue == 1 }

        preview.commandForKey = { $0.keyCode == kVK_Space ? .preview : nil }
        preview.dismiss()
        try #require(preview.alphaValue == 0)
        #expect(preview.ignoresMouseEvents)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: preview.windowNumber, context: nil,
                                                characters: " ", charactersIgnoringModifiers: " ",
                                                isARepeat: false, keyCode: UInt16(kVK_Space)))
        preview.sendEvent(space)

        #expect(preview.isVisible && preview.alphaValue == 1)
        #expect(!preview.ignoresMouseEvents)
        // The restored preview stays visible past the canceled animation's deadline.
        try await Task.sleep(for: .milliseconds(450))
        #expect(preview.isVisible && preview.alphaValue == 1)
    }

    @Test(arguments: [true, false])
    func pausedZoomStillSettlesThePreview(opening: Bool) async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let preview = makePreview()
        defer { preview.close() }
        preview.hidesOnDeactivate = true
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        try show(preview)
        #expect(!preview.hidesOnDeactivate)
        if !opening {
            try await waitUntil { preview.alphaValue == 1 }
            preview.dismiss()
        }

        let overlay = try #require(NSApplication.shared.windows.first {
            $0.isVisible && $0.styleMask.contains(.nonactivatingPanel)
                && !existingWindows.contains(ObjectIdentifier($0))
        })
        let canvas = try #require(overlay.contentView?.layer)
        let previousSpeed = canvas.speed
        canvas.speed = 0
        defer { canvas.speed = previousSpeed }

        try await waitUntil { opening ? preview.alphaValue == 1 : !preview.isVisible }
        #expect(!overlay.isVisible)
    }

    private func makePreview() -> FolderPreviewPanel {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let folder = FileEntry(url: directory, name: "Preview Fixture", isFolder: true,
                               isSymbolicLink: false, fileKind: .folder, fileSize: -1,
                               modified: .distantPast, added: .distantPast)
        let preview = FolderPreviewPanel(folder: folder, includeHidden: false, interfaceSize: .small)
        preview.hidesOnDeactivate = false
        return preview
    }

    private func show(_ preview: FolderPreviewPanel) throws {
        let screen = try #require(NSScreen.main)
        let source = CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.midY, width: 24, height: 24)
        preview.show(above: nil, animation: .standard) { source }
    }

    private func waitUntil(timeout: Duration = .seconds(1), sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}
