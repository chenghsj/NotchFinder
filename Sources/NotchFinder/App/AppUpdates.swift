import AppKit

@MainActor
final class AppUpdates {
    private let settings: NotchSettings
    private var task: Task<Void, Never>?
    private var previewUpdater: PreviewUpdater?

    init(settings: NotchSettings) {
        self.settings = settings
    }

    func restart() {
        stop()
        if !settings.installsUpdatesOnQuit { previewUpdater?.cancel() }
        guard ProcessInfo.processInfo.environment["NOTCH_FINDER_TEST_DATA_DIR"] == nil,
              settings.checksForUpdates,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let installed = AppVersion(version) else { return }

        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates(installed: installed)
                do {
                    try await Task.sleep(for: .seconds(24 * 60 * 60))
                } catch {
                    break
                }
            }
        }
    }

    func deferQuitForUpdateCancellation(_ reply: @escaping () -> Void) -> Bool {
        previewUpdater?.deferQuitForCancellation(reply) ?? false
    }

    private func checkForUpdates(installed: AppVersion) async {
        if settings.installsUpdatesOnQuit {
            if previewUpdater == nil { previewUpdater = PreviewUpdater(settings: settings) }
            previewUpdater?.check()
        } else {
            await check(installed: installed)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func check(installed: AppVersion) async {
        guard let release = try? await GitHubRelease.latest(), !Task.isCancelled,
              release.isNewer(than: installed) else { return }

        let defaults = settings.defaults
        let lastPrompt = "lastNotifiedUpdateTag"
        let lastDownload = "lastAutomaticallyDownloadedUpdateTag"
        let alreadyNotified = defaults.string(forKey: lastPrompt) == release.tagName
        var downloadedFile: URL?
        if settings.automaticallyDownloadsUpdates, defaults.string(forKey: lastDownload) != release.tagName {
            downloadedFile = try? await release.downloadDiskImage()
            if downloadedFile != nil { defaults.set(release.tagName, forKey: lastDownload) }
        }
        guard !Task.isCancelled, !alreadyNotified || downloadedFile != nil else { return }

        defaults.set(release.tagName, forKey: lastPrompt)
        showUpdate(release, downloadedFile: downloadedFile)
    }

    private func showUpdate(_ release: GitHubRelease, downloadedFile: URL?) {
        let alert = NSAlert()
        alert.messageText = release.prerelease
            ? L10n.text("Notch Finder %@ 預覽版已推出", release.tagName)
            : L10n.text("Notch Finder %@ 已推出", release.tagName)
        let openRelease = L10n.text("前往 GitHub Releases")
        if downloadedFile != nil {
            alert.informativeText = L10n.text("新版 DMG 已存到「下載項目」。你可以在 Finder 開啟它來安裝。")
            alert.addButton(withTitle: L10n.text("在 Finder 中顯示"))
        } else {
            alert.informativeText = L10n.text("你可以從 GitHub Releases 下載新版 DMG。")
        }
        alert.addButton(withTitle: openRelease)
        alert.addButton(withTitle: L10n.text("稍後")).keyEquivalent = "\u{1B}"
        NSApp.activate()

        let response = alert.runModal()
        if let downloadedFile, response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([downloadedFile])
        } else if response == (downloadedFile == nil ? .alertFirstButtonReturn : .alertSecondButtonReturn) {
            NSWorkspace.shared.open(release.page)
        }
    }
}
