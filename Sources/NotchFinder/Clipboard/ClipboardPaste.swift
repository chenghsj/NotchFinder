import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Observation

@MainActor
@Observable
final class ClipboardPaste {
    enum Destination {
        case folder(available: Bool)
        case application(String)

        var isAvailable: Bool {
            if case .folder(let available) = self { return available }
            return true
        }
    }

    enum Outcome: Equatable {
        case started, posted, copied, unavailable, superseded
    }

    enum Feedback {
        case copied, copyFailed, manualPaste, pasteUnavailable

        var message: String {
            switch self {
            case .copied: L10n.text("已複製")
            case .copyFailed: L10n.text("無法複製此項目")
            case .manualPaste: L10n.text("已複製，可用 ⌘V 貼上")
            case .pasteUnavailable: L10n.text("無法貼上此項目")
            }
        }
    }

    struct Folder {
        let available: Bool
        let paste: ([URL]) -> Void
    }

    struct Application {
        let name: String
        let isRunning: () -> Bool
        let acquireFocus: @MainActor () async -> Bool
        let postPaste: () -> Bool
    }

    @MainActor
    struct Desktop {
        let frontmostApplication: () -> Application?
        let canPostEvents: () -> Bool
        let requestEventAccess: () -> Bool

        static var live: Desktop {
            Desktop(frontmostApplication: captureApplication, canPostEvents: CGPreflightPostEventAccess,
                    requestEventAccess: CGRequestPostEventAccess)
        }

        private static func captureApplication() -> Application? {
            guard let application = NSWorkspace.shared.frontmostApplication,
                  application.processIdentifier != NSRunningApplication.current.processIdentifier,
                  application.activationPolicy == .regular,
                  let name = application.localizedName else { return nil }
            return Application(
                name: name,
                isRunning: { !application.isTerminated },
                acquireFocus: { await acquireFocus(for: application) },
                postPaste: { postPaste(to: application.processIdentifier) }
            )
        }

        private static func acquireFocus(for application: NSRunningApplication) async -> Bool {
            if !application.isActive {
                NSApp.yieldActivation(to: application)
                _ = application.activate(options: [])
            }
            for _ in 0..<15 where !Task.isCancelled {
                if application.isActive || application.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(55))
            return !Task.isCancelled && !application.isTerminated &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
        }

        private static func postPaste(to pid: pid_t) -> Bool {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(pid)
            up.postToPid(pid)
            return true
        }
    }

    private enum Route {
        case folder(Folder)
        case application(Application)
    }

    @ObservationIgnored private let history: ClipboardHistory
    @ObservationIgnored private let desktop: Desktop
    @ObservationIgnored private let folder: () -> Folder?
    @ObservationIgnored private let dismissPanel: () -> Void
    private var application: Application?
    private var feedback: (id: ClipboardHistory.Row.ID, value: Feedback)?
    @ObservationIgnored private var requestedEventAccess = false
    @ObservationIgnored private var attemptID: UUID?

    init(history: ClipboardHistory, desktop: Desktop, folder: @escaping () -> Folder?,
         dismissPanel: @escaping () -> Void) {
        self.history = history
        self.desktop = desktop
        self.folder = folder
        self.dismissPanel = dismissPanel
    }

    func captureTarget() {
        if let target = desktop.frontmostApplication() { application = target }
    }

    func destination(for row: ClipboardHistory.Row) -> Destination? {
        guard let contents = history.availableContents(for: row) else { return nil }
        switch route(for: contents) {
        case .folder(let folder): return .folder(available: folder.available)
        case .application(let application): return .application(application.name)
        case nil: return nil
        }
    }

    func feedback(for id: ClipboardHistory.Row.ID) -> Feedback? {
        feedback?.id == id ? feedback?.value : nil
    }

    func clearFeedback(except id: ClipboardHistory.Row.ID?) {
        if feedback?.id != id { feedback = nil }
    }

    func copy(_ row: ClipboardHistory.Row) {
        attemptID = nil
        feedback = (row.id, history.restore(row) == nil ? .copyFailed : .copied)
    }

    @discardableResult
    func paste(_ row: ClipboardHistory.Row, copyIfNoDestination: Bool = false) async -> Outcome {
        let id = UUID()
        attemptID = id
        feedback = nil
        let outcome = await performPaste(row, id: id, copyIfNoDestination: copyIfNoDestination)
        if attemptID == id {
            switch outcome {
            case .copied: feedback = (row.id, .manualPaste)
            case .unavailable: feedback = (row.id, .pasteUnavailable)
            case .started, .posted, .superseded: break
            }
        }
        return outcome
    }

    private func route(for contents: ClipboardContents) -> Route? {
        if contents.hasFiles { return folder().map(Route.folder) }
        guard let application, application.isRunning() else { return nil }
        return .application(application)
    }

    private func performPaste(_ row: ClipboardHistory.Row, id: UUID, copyIfNoDestination: Bool) async -> Outcome {
        guard !Task.isCancelled else { return .superseded }
        guard let contents = history.availableContents(for: row) else { return .unavailable }
        switch route(for: contents) {
        case .folder(let folder):
            guard folder.available, case .files(let urls) = contents, !urls.isEmpty else { return .unavailable }
            folder.paste(urls)
            return .started
        case .application(let application):
            guard let snapshot = history.restore(row) else { return .unavailable }
            if !desktop.canPostEvents() {
                guard !requestedEventAccess else { return .copied }
                requestedEventAccess = true
                guard desktop.requestEventAccess() else { return .copied }
            }
            dismissPanel()
            let acquiredFocus = await application.acquireFocus()
            guard attemptID == id, !Task.isCancelled else { return .superseded }
            guard history.isCurrent(snapshot) else { return .unavailable }
            guard acquiredFocus, application.isRunning(), application.postPaste() else { return .copied }
            return .posted
        case nil:
            guard copyIfNoDestination, history.restore(row) != nil else { return .unavailable }
            return .copied
        }
    }
}
