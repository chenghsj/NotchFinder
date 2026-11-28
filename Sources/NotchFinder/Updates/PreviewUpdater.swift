import AppKit
import Observation
import Sparkle
import os

@MainActor
final class PreviewUpdater: NSObject, SPUUpdaterDelegate {
    private let lifecycle: AutomaticUpdateLifecycle
    private let driver: PreviewUpdateDriver
    private let checkFinished: ((any Error)?) -> Void
    private var updater: SPUUpdater?
    private static let logger = Logger(subsystem: "local.notchfinder.app", category: "Updates")

    init(settings: NotchSettings, lifecycle: AutomaticUpdateLifecycle, schedule: UpdateSchedule,
         checkFinished: @escaping ((any Error)?) -> Void) {
        self.lifecycle = lifecycle
        self.checkFinished = checkFinished
        driver = PreviewUpdateDriver(settings: settings, lifecycle: lifecycle, schedule: schedule)
        super.init()
    }

    var isBusy: Bool { driver.phase != nil }

    var actionTitle: String {
        switch driver.phase {
        case nil: L10n.text("檢查更新…")
        case .manual, .background: L10n.text("正在檢查更新…")
        case .interactiveInstall, .automaticInstall: L10n.text("正在準備更新…")
        }
    }

    func check(manually: Bool) {
        guard !isBusy else { return }
        if updater == nil {
            let candidate = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
            do {
                try candidate.start()
                updater = candidate
            } catch {
                Self.logger.error("Sparkle failed to start: \(error.localizedDescription, privacy: .public)")
                if manually { driver.showError(error) }
                checkFinished(error)
                return
            }
        }
        guard let updater, !updater.sessionInProgress else { return }
        driver.phase = manually ? .manual : .background
        if manually {
            updater.checkForUpdates()
        } else {
            updater.checkForUpdatesInBackground()
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let url = item.fileURL, GitHubRelease.isReleaseDMG(url),
              !item.isInformationOnlyUpdate, item.installationType == "application",
              item.signingValidationStatus != .failed else { throw URLError(.cannotDecodeContentData) }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        driver.finish()
        checkFinished(error)
        lifecycle.didFinish()
    }
}

@MainActor
@Observable
private final class PreviewUpdateDriver: NSObject, SPUUserDriver {
    enum Phase {
        case manual, background, interactiveInstall, automaticInstall
    }

    var phase: Phase?
    private let settings: NotchSettings
    private let lifecycle: AutomaticUpdateLifecycle
    private let schedule: UpdateSchedule
    private let progress = UpdateProgressWindow()

    init(settings: NotchSettings, lifecycle: AutomaticUpdateLifecycle, schedule: UpdateSchedule) {
        self.settings = settings
        self.lifecycle = lifecycle
        self.schedule = schedule
    }

    func finish() {
        progress.close()
        phase = nil
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if phase == .background {
            guard settings.checksForUpdates else { return reply(.dismiss) }
            if settings.installsUpdatesOnQuit {
                guard lifecycle.acceptsUpdate else { return reply(.dismiss) }
                phase = .automaticInstall
                if state.stage == .installing { showReady(toInstallAndRelaunch: reply) }
                else { reply(.install) }
                return
            }
            if schedule.isDeferred(item.versionString) { return reply(.dismiss) }
        }

        let alert = NSAlert()
        alert.messageText = L10n.text("Notch Finder %@ 已推出", item.displayVersionString)
        let install = state.stage == .installing ? "安裝並重新啟動" : "安裝更新"
        alert.addButton(withTitle: L10n.text(install))
        alert.addButton(withTitle: L10n.text("稍後")).keyEquivalent = "\u{1B}"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            schedule.remindLater(about: item.versionString)
            return reply(.dismiss)
        }
        phase = .interactiveInstall
        reply(.install)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if phase == .automaticInstall { lifecycle.didStartDownload(cancel: cancellation) }
        else { progress.show(.downloading, action: cancellation) }
    }

    func showDownloadDidStartExtractingUpdate() {
        if phase == .automaticInstall { lifecycle.didStartExtraction() }
        else { progress.show(.extracting) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if phase == .automaticInstall {
            lifecycle.readyToInstall(install: { [weak self] in
                self?.phase = .interactiveInstall
                reply(.install)
            }, skip: { reply(.skip) })
        } else {
            progress.show(.ready) { reply(.install) }
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        defer { acknowledgement() }
        if phase == .manual {
            let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
            switch reason.flatMap({ SPUNoUpdateFoundReason(rawValue: $0.int32Value) }) {
            case .onLatestVersion, .onNewerThanLatestVersion: break
            default:
                showError(error)
                return
            }
            let alert = NSAlert()
            alert.messageText = L10n.text("Notch Finder 已是最新版本")
            alert.addButton(withTitle: L10n.text("確定"))
            NSApp.activate()
            alert.runModal()
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if phase == .manual || phase == .interactiveInstall { showError(error) }
        acknowledgement()
    }

    func showError(_ error: any Error) {
        NSApp.activate()
        if settings.interfaceLanguage == .system {
            NSAlert(error: error).runModal()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(phase == .interactiveInstall ? "無法安裝更新" : "無法檢查更新")
        alert.addButton(withTitle: L10n.text("確定"))
        alert.addButton(withTitle: L10n.text("顯示詳細資訊"))
        if alert.runModal() == .alertSecondButtonReturn {
            let diagnostic = error as NSError
            let details = NSAlert()
            details.messageText = alert.messageText
            details.informativeText = [diagnostic.localizedDescription, diagnostic.localizedRecoverySuggestion]
                .compactMap { $0 }.joined(separator: "\n")
            details.addButton(withTitle: L10n.text("確定"))
            details.runModal()
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if phase == .interactiveInstall { progress.expectedBytes = expectedContentLength }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if phase == .interactiveInstall { progress.receivedBytes += length }
    }

    func showExtractionReceivedProgress(_ value: Double) {
        if phase == .interactiveInstall { progress.extractionProgress = value }
    }

    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication retry: @escaping () -> Void) {
        if phase == .interactiveInstall {
            progress.show(.installing, action: terminated ? nil : retry)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        progress.close()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        progress.close()
    }
}
