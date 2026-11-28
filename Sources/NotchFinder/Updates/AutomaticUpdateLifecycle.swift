@MainActor
final class AutomaticUpdateLifecycle {
    private enum Stage {
        case idle
        case downloading(cancel: () -> Void)
        case preparing
        case ready(install: () -> Void, skip: () -> Void)
        case cancelling
    }

    private let readinessChanged: (Bool) -> Void
    private var stage = Stage.idle
    private var enabled = false
    private var retryAfterCancellation: (() -> Void)?
    private var quitReply: (() -> Void)?
    private var isQuitting = false

    init(readinessChanged: @escaping (Bool) -> Void) {
        self.readinessChanged = readinessChanged
    }

    var acceptsUpdate: Bool {
        guard enabled && !isQuitting else { return false }
        if case .cancelling = stage { return false }
        return true
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            retryAfterCancellation = nil
            cancel()
        }
    }

    func check(start: @escaping () -> Void) {
        guard enabled && !isQuitting else { return }
        if case .cancelling = stage {
            retryAfterCancellation = start
        } else {
            start()
        }
    }

    func didStartDownload(cancel download: @escaping () -> Void) {
        if case .cancelling = stage {
            download()
            return
        }
        stage = .downloading(cancel: download)
        if !enabled { cancel() }
    }

    func didStartExtraction() {
        if case .cancelling = stage { return }
        stage = .preparing
        if !enabled { cancel() }
    }

    func readyToInstall(install: @escaping () -> Void, skip: @escaping () -> Void) {
        guard acceptsUpdate else {
            stage = .cancelling
            skip()
            return
        }
        // Sparkle keeps the installer waiting for process exit while its reply is retained.
        stage = .ready(install: install, skip: skip)
        readinessChanged(true)
    }

    func installNow() {
        guard case .ready(let install, _) = stage else { return }
        stage = .idle
        readinessChanged(false)
        install()
    }

    func deferQuitForCancellation(_ reply: @escaping () -> Void) -> Bool {
        guard case .cancelling = stage else { return false }
        isQuitting = true
        quitReply = reply
        return true
    }

    func didFinish() {
        let quit = quitReply
        let retry = retryAfterCancellation
        stage = .idle
        quitReply = nil
        retryAfterCancellation = nil
        readinessChanged(false)
        quit?()
        if let retry { check(start: retry) }
    }

    private func cancel() {
        let cancelInProgress: (() -> Void)?
        switch stage {
        case .idle, .cancelling: return
        case .preparing: cancelInProgress = nil
        case .downloading(let cancel), .ready(_, let cancel): cancelInProgress = cancel
        }
        stage = .cancelling
        readinessChanged(false)
        cancelInProgress?()
    }
}
