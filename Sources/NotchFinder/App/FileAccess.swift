import AppKit
import Darwin

enum FileAccess {
    static func needsStartupPermission(
        for startupDirectory: URL?,
        trashDirectory: URL? = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
    ) -> Bool {
        // If the protected Trash is already denied, show the app's prompt before opening another protected folder.
        isDenied(at: trashDirectory) || (startupDirectory != trashDirectory && isDenied(at: startupDirectory))
    }

    @MainActor
    static func confirmRequest() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.text("允許 Notch Finder 取用檔案")
        alert.informativeText = L10n.text("在系統設定開啟「完全取用磁碟」，即可從面板瀏覽受保護的資料夾。")
        alert.addButton(withTitle: L10n.text("打開系統設定…"))
        alert.addButton(withTitle: L10n.text("稍後"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func isDenied(at directory: URL?) -> Bool {
        guard let directory else { return false }
        return directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            let error: Int32
            if let stream = opendir(path) {
                errno = 0
                error = readdir(stream) == nil ? errno : 0
                closedir(stream)
            } else {
                error = errno
            }
            return error == EPERM || error == EACCES
        }
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
