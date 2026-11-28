import Foundation

@MainActor
protocol FilePreviewWindows: AnyObject {
    var canPresent: Bool { get }
    var visibleFolder: URL? { get }
    var folderIsClosing: Bool { get }
    var nativeState: FilePreviewSession.NativeState { get }

    func presentFolder(_ folder: FileEntry, followingSelection: Bool)
    func dismissFolder(_ disposition: FilePreviewSession.FolderDismissal)
    func reopenFolder()
    func presentFiles(_ urls: [URL], followingSelection: Bool)
    func dismissNative(followingSelection: Bool)
}

@MainActor
final class FilePreviewSession {
    enum NativeState { case closed, open, closing }
    enum FolderDismissal { case immediately, animated, keepForSelection }

    private unowned let windows: any FilePreviewWindows
    private var pendingNative: (urls: [URL], followingSelection: Bool)?
    private var selectionUpdate: Task<Void, Never>?

    init(windows: any FilePreviewWindows) {
        self.windows = windows
    }

    var isVisible: Bool {
        pendingNative != nil || windows.visibleFolder != nil || windows.nativeState != .closed
    }

    private var followsSelection: Bool {
        pendingNative != nil || windows.nativeState == .open || (windows.visibleFolder != nil && !windows.folderIsClosing)
    }

    func selectionDidChange(_ entries: @escaping @MainActor () -> [FileEntry]) {
        guard followsSelection, selectionUpdate == nil else { return }
        // AppKit must finish committing the selection before changing the preview window.
        selectionUpdate = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            selectionUpdate = nil
            if followsSelection { show(entries(), followingSelection: true) }
        }
    }

    func show(_ entries: [FileEntry], followingSelection: Bool = false) {
        guard windows.canPresent else { return }
        guard let first = entries.first else {
            if followingSelection { close() }
            return
        }
        pendingNative = nil
        if entries.count == 1 && first.isFolder {
            if windows.nativeState == .open { windows.dismissNative(followingSelection: followingSelection) }
            windows.presentFolder(first, followingSelection: followingSelection)
        } else {
            if windows.visibleFolder != nil {
                windows.dismissFolder(followingSelection && !windows.folderIsClosing ? .keepForSelection : .immediately)
            }
            let urls = entries.map(\.url)
            if windows.nativeState == .closing {
                pendingNative = (urls, followingSelection)
            } else {
                windows.presentFiles(urls, followingSelection: followingSelection)
            }
        }
    }

    func nativeControlEnded(canReopen: @escaping @MainActor () -> Bool) {
        guard pendingNative != nil else { return }
        // AppKit releases control synchronously. Read the latest request on the next turn.
        Task { [weak self] in
            guard let self, let pending = pendingNative, windows.nativeState != .closing else { return }
            pendingNative = nil
            if windows.canPresent && canReopen() {
                windows.presentFiles(pending.urls, followingSelection: pending.followingSelection)
            }
        }
    }

    func toggle(for selection: Set<URL>) -> Bool {
        if let folder = windows.visibleFolder {
            guard selection.isEmpty || selection == [folder] else { return false }
            if windows.folderIsClosing { windows.reopenFolder() }
            else { close(animated: true) }
        } else if windows.nativeState == .open || pendingNative != nil {
            close()
        } else {
            return false
        }
        return true
    }

    func close(animated: Bool = false) {
        selectionUpdate?.cancel()
        selectionUpdate = nil
        pendingNative = nil
        windows.dismissFolder(animated ? .animated : .immediately)
        if windows.nativeState == .open { windows.dismissNative(followingSelection: false) }
    }
}
