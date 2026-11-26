import Foundation
import Sparkle
import os

@MainActor
final class PreviewUpdater: NSObject, SPUUpdaterDelegate {
    private let settings: NotchSettings
    private let driver: PreviewUpdateDriver
    private var updater: SPUUpdater?
    private var checkAfterCancellation = false
    private static let logger = Logger(subsystem: "local.notchfinder.app", category: "Updates")

    init(settings: NotchSettings) {
        self.settings = settings
        driver = PreviewUpdateDriver(settings: settings)
        super.init()
    }

    func check() {
        guard settings.installsUpdatesOnQuit else { return }
        if driver.isCancelling {
            checkAfterCancellation = true
            return
        }
        if updater == nil {
            let candidate = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
            do {
                try candidate.start()
                updater = candidate
            } catch {
                Self.logger.error("Sparkle failed to start: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    func cancel() {
        checkAfterCancellation = false
        driver.cancel()
    }

    func deferQuitForCancellation(_ reply: @escaping () -> Void) -> Bool {
        driver.deferQuitForCancellation(reply)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard settings.installsUpdatesOnQuit else { throw CancellationError() }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard settings.installsUpdatesOnQuit, !driver.isCancelling,
              let url = updateItem.fileURL, GitHubRelease.isReleaseDMG(url),
              updateItem.installationType == "application" else { throw CancellationError() }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let retry = checkAfterCancellation
        checkAfterCancellation = false
        let quitting = driver.finish()
        if retry, !quitting { check() }
    }
}

@MainActor
private final class PreviewUpdateDriver: NSObject, SPUUserDriver {
    private let settings: NotchSettings
    private var cancelDownload: (() -> Void)?
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var preparing = false
    private var quitReply: (() -> Void)?
    private(set) var isCancelling = false

    init(settings: NotchSettings) { self.settings = settings }

    func cancel() {
        guard !isCancelling, cancelDownload != nil || preparing || pendingChoice != nil else { return }
        isCancelling = true
        settings.updateReadyToInstall = false
        if let pendingChoice {
            self.pendingChoice = nil
            pendingChoice(.skip)
        } else if !preparing {
            cancelDownload?()
            cancelDownload = nil
        }
    }

    func deferQuitForCancellation(_ reply: @escaping () -> Void) -> Bool {
        guard isCancelling else { return false }
        quitReply = reply
        return true
    }

    func finish() -> Bool {
        cancelDownload = nil
        pendingChoice = nil
        preparing = false
        isCancelling = false
        settings.updateReadyToInstall = false
        let reply = quitReply
        quitReply = nil
        reply?()
        return reply != nil
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if state.stage == .installing {
            showReady(toInstallAndRelaunch: reply)
        } else {
            reply(settings.installsUpdatesOnQuit && !isCancelling ? .install : .dismiss)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        if !settings.installsUpdatesOnQuit { cancel() }
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        preparing = true
        if !settings.installsUpdatesOnQuit { cancel() }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        preparing = false
        if settings.installsUpdatesOnQuit && !isCancelling {
            // Sparkle's installer waits for the app to exit. An explicit .install reply would quit it now.
            pendingChoice = reply
            settings.updateReadyToInstall = true
        } else {
            isCancelling = true
            reply(.skip)
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}
