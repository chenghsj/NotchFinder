import AppKit

@MainActor
func configureDockIconVisibility(settings: NotchSettings, application: NSApplication) {
    let focusRestore = DockFocusRestore()
    let applyVisibility: (Bool) -> Void = { [weak application] visible in
        focusRestore.cancel()
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard let application, application.activationPolicy() != policy else { return }

        if policy == .accessory, application.isActive, let keyWindow = application.keyWindow {
            focusRestore.watchDeactivation(of: application, window: keyWindow)
        }
        if !application.setActivationPolicy(policy) { focusRestore.cancel() }
    }

    applyVisibility(settings.showsDockIcon)
    settings.dockIconVisibilityDidChange = applyVisibility
}

@MainActor
private final class DockFocusRestore {
    private var observer: NSObjectProtocol?
    private var pendingTask: Task<Void, Never>?

    func watchDeactivation(of application: NSApplication, window: NSWindow) {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: application, queue: .main
        ) { [weak self, weak application, weak window] _ in
            MainActor.assumeIsolated { self?.restoreAfterTransition(application: application, window: window) }
        }

        // Stop listening after the activation-policy transition.
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            self?.cancel()
        }
    }

    private func restoreAfterTransition(application: NSApplication?, window: NSWindow?) {
        cancel()
        pendingTask = Task { [weak application, weak window] in
            // Let the Dock finish the policy change before asking Launch Services to return focus.
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let application, let window, application.activationPolicy() == .accessory,
                  window.isVisible, !window.isMiniaturized,
                  application.keyWindow == nil || application.keyWindow === window else { return }
            // A Launch Services activation can return focus after AppKit makes the app an accessory.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            guard let running = try? await NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL, configuration: configuration
            ), !Task.isCancelled, running.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                application.activationPolicy() == .accessory, window.isVisible, !window.isMiniaturized,
                application.keyWindow == nil || application.keyWindow === window else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func cancel() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pendingTask?.cancel()
        pendingTask = nil
    }
}
