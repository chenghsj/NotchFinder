import Foundation

@MainActor
final class AppUpdates {
    private let settings: NotchSettings
    private let automaticUpdates: AutomaticUpdateLifecycle
    private let schedule: UpdateSchedule
    private lazy var updater = PreviewUpdater(settings: settings, lifecycle: automaticUpdates, schedule: schedule) {
        [weak self] error in
        guard let self, task != nil else { return }
        scheduleCheck(after: schedule.nextCheckDelay(after: error))
    }
    private var task: Task<Void, Never>?

    init(settings: NotchSettings) {
        self.settings = settings
        schedule = UpdateSchedule(defaults: settings.defaults)
        automaticUpdates = AutomaticUpdateLifecycle { [weak settings] ready in
            settings?.updateReadyToInstall = ready
        }
    }

    var manualCheckTitle: String {
        if settings.updateReadyToInstall { return L10n.text("安裝並重新啟動") }
        return updater.actionTitle
    }

    var manualCheckUnavailable: Bool {
        updater.isBusy && !settings.updateReadyToInstall
    }

    func checkManually() {
        if settings.updateReadyToInstall {
            automaticUpdates.installNow()
        } else {
            updater.check(manually: true)
        }
    }

    func restart() {
        stop()
        automaticUpdates.setEnabled(settings.installsUpdatesOnQuit)
        guard ProcessInfo.processInfo.environment["NOTCH_FINDER_TEST_DATA_DIR"] == nil,
              settings.checksForUpdates else { return }
        scheduleCheck(after: 0)
    }

    private func scheduleCheck(after delay: TimeInterval) {
        task?.cancel()
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.checkInBackground()
        }
    }

    private func checkInBackground() {
        if settings.installsUpdatesOnQuit {
            automaticUpdates.check { [weak self] in self?.updater.check(manually: false) }
        } else {
            updater.check(manually: false)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func deferQuitForUpdateCancellation(_ reply: @escaping () -> Void) -> Bool {
        automaticUpdates.deferQuitForCancellation(reply)
    }
}
