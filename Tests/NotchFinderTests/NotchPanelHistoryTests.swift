import AppKit
import Testing
@testable import NotchFinder

@MainActor
@Test func sideButtonsNavigateDisplayedTab() throws {
    let app = NSApplication.shared
    let windows = Set(app.windows.map(ObjectIdentifier.init))
    let appearance = app.appearance
    defer { app.appearance = appearance }
    let suite = "local.notchfinder.panel-history-tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = root.appendingPathComponent("Previous", isDirectory: true).standardizedFileURL
    let next = root.appendingPathComponent("Next", isDirectory: true).standardizedFileURL
    for folder in [previous, next] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    let settings = NotchSettings(defaults: defaults)
    settings.hoverEnabled = false
    settings.autoHide = false
    settings.animation = .off
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let clipboard = ClipboardHistory(pasteboard: board, defaults: defaults, storageURL: root.appending(path: "history.plist"))
    let controller = NotchController(settings: settings, shortcuts: PanelShortcuts(defaults: defaults), clipboardHistory: clipboard)
    controller.start()
    controller.showPanel()
    let panel = try #require(app.windows.first {
        !windows.contains(ObjectIdentifier($0)) && $0.title == "Notch Finder" && $0.isVisible
    })
    defer { panel.orderOut(nil) }

    let firstTab = controller.tabs.active
    controller.tabs.navigate(to: previous)
    controller.tabs.add()
    controller.tabs.navigate(to: next)

    func send(_ button: UInt32, type: CGEventType = .otherMouseDown) throws {
        let mouseButton = try #require(CGMouseButton(rawValue: button))
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                                         mouseButton: mouseButton))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        let mouse = try #require(NSEvent(cgEvent: event))
        #expect(mouse.buttonNumber == Int(button))
        panel.sendEvent(mouse)
    }

    try send(2)
    #expect(controller.browser.directory == next)
    try send(3, type: .otherMouseUp)
    #expect(controller.browser.directory == next)
    try send(3)
    try #require(controller.browser.directory == previous)
    try send(4)
    #expect(controller.browser.directory == next)
    try send(4)
    #expect(controller.browser.directory == next)
    #expect(firstTab.browser.directory == previous)

    panel.sendEvent(HistorySwipeEvent(deltaX: 1))
    try #require(controller.browser.directory == previous)
    panel.sendEvent(HistorySwipeEvent(deltaX: 0))
    #expect(controller.browser.directory == previous)
    panel.sendEvent(HistorySwipeEvent(deltaX: -1))
    #expect(controller.browser.directory == next)

    controller.tabs.showClipboard()
    try send(3)
    #expect(!controller.tabs.showsClipboard)
    #expect(controller.browser.directory == next)
}

private final class HistorySwipeEvent: NSEvent {
    private let horizontalDelta: CGFloat

    init(deltaX: CGFloat) {
        horizontalDelta = deltaX
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var type: NSEvent.EventType { .swipe }
    override var deltaX: CGFloat { horizontalDelta }
}
