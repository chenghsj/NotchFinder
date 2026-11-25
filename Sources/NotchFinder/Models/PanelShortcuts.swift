import AppKit
import Carbon
import Observation

struct KeyShortcut: Codable, Equatable {
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    let keyCode: UInt16
    let characters: String
    private let rawModifiers: UInt

    var modifiers: NSEvent.ModifierFlags { .init(rawValue: rawModifiers) }

    init(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) {
        keyCode = UInt16(code)
        self.characters = characters.lowercased()
        rawModifiers = modifiers.intersection(Self.shortcutModifiers).rawValue
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        self.init(Int(event.keyCode), characters, event.modifierFlags)
    }

    func matches(_ other: KeyShortcut) -> Bool {
        keyCode == other.keyCode && rawModifiers == other.rawModifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode && rawModifiers == event.modifierFlags.intersection(Self.shortcutModifiers).rawValue
    }

    var display: String {
        let keys = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] as [(NSEvent.ModifierFlags, String)]
        let prefix = keys.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let name: String
        switch Int(keyCode) {
        case kVK_Space: name = L10n.text("空白鍵")
        case kVK_Return, kVK_ANSI_KeypadEnter: name = "↩"
        case kVK_Escape: name = "Esc"
        case kVK_Delete: name = "⌫"
        case kVK_ForwardDelete: name = "⌦"
        case kVK_LeftArrow: name = "←"
        case kVK_RightArrow: name = "→"
        case kVK_UpArrow: name = "↑"
        case kVK_DownArrow: name = "↓"
        case kVK_Tab: name = "⇥"
        default:
            if let key = characters.unicodeScalars.first?.value, key >= 0xf704, key <= 0xf726 {
                name = "F\(key - 0xf704 + 1)"
            } else {
                name = characters.uppercased()
            }
        }
        return prefix + name
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }
}

enum PanelCommand: String, CaseIterable {
    case togglePanel, settings, close, pin, back, forward, parent, goToFolder, filter, reload, toggleHidden
    case open, preview, selectAll, copy, paste, copyPath, reveal, rename, newFolder, trash
    case newTab, closeTab, nextTab, previousTab

    var isTabCommand: Bool {
        switch self {
        case .newTab, .closeTab, .nextTab, .previousTab: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .togglePanel: L10n.text("開關檔案面板（全域）")
        case .settings: L10n.text("開啟設定")
        case .close: L10n.text("收合面板或取消")
        case .pin: L10n.text("固定或解除固定面板")
        case .back: L10n.text("上一個資料夾")
        case .forward: L10n.text("下一個資料夾")
        case .parent: L10n.text("上一層")
        case .goToFolder: L10n.text("前往資料夾")
        case .filter: L10n.text("搜尋")
        case .reload: L10n.text("重新載入")
        case .toggleHidden: L10n.text("切換隱藏項目")
        case .open: L10n.text("開啟項目")
        case .preview: L10n.text("快速查看")
        case .selectAll: L10n.text("全選")
        case .copy: L10n.text("複製項目")
        case .paste: L10n.text("貼上項目")
        case .copyPath: L10n.text("複製路徑")
        case .reveal: L10n.text("在 Finder 中顯示")
        case .rename: L10n.text("重新命名")
        case .newFolder: L10n.text("新增資料夾")
        case .trash: L10n.text("移到垃圾桶")
        case .newTab: L10n.text("新增分頁")
        case .closeTab: L10n.text("關閉目前分頁")
        case .nextTab: L10n.text("下一個分頁")
        case .previousTab: L10n.text("上一個分頁")
        }
    }

    var defaultShortcut: KeyShortcut {
        switch self {
        case .togglePanel: KeyShortcut(kVK_ANSI_N, "n", [.control, .option])
        case .settings: KeyShortcut(kVK_ANSI_Comma, ",", .command)
        case .close: KeyShortcut(kVK_Escape, "\u{1b}")
        case .pin: KeyShortcut(kVK_ANSI_P, "p", [.command, .shift])
        case .back: KeyShortcut(kVK_ANSI_LeftBracket, "[", .command)
        case .forward: KeyShortcut(kVK_ANSI_RightBracket, "]", .command)
        case .parent: KeyShortcut(kVK_UpArrow, "\u{f700}", .command)
        case .goToFolder: KeyShortcut(kVK_ANSI_G, "g", [.command, .shift])
        case .filter: KeyShortcut(kVK_ANSI_F, "f", .command)
        case .reload: KeyShortcut(kVK_ANSI_R, "r", .command)
        case .toggleHidden: KeyShortcut(kVK_ANSI_Period, ".", [.command, .shift])
        case .open: KeyShortcut(kVK_DownArrow, "\u{f701}", .command)
        case .preview: KeyShortcut(kVK_Space, " ")
        case .selectAll: KeyShortcut(kVK_ANSI_A, "a", .command)
        case .copy: KeyShortcut(kVK_ANSI_C, "c", .command)
        case .paste: KeyShortcut(kVK_ANSI_V, "v", .command)
        case .copyPath: KeyShortcut(kVK_ANSI_C, "c", [.command, .option])
        case .reveal: KeyShortcut(kVK_ANSI_R, "r", [.command, .option])
        case .rename: KeyShortcut(kVK_Return, "\r")
        case .newFolder: KeyShortcut(kVK_ANSI_N, "n", [.command, .shift])
        case .trash: KeyShortcut(kVK_Delete, "\u{7f}", .command)
        case .newTab: KeyShortcut(kVK_ANSI_T, "t", .command)
        case .closeTab: KeyShortcut(kVK_ANSI_W, "w", .command)
        case .nextTab: KeyShortcut(kVK_Tab, "\t", .control)
        case .previousTab: KeyShortcut(kVK_Tab, "\t", [.control, .shift])
        }
    }
}

@MainActor
@Observable
final class PanelShortcuts {
    private static let searchShortcut = KeyShortcut(kVK_ANSI_K, "k", .command)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var installGlobal: ((KeyShortcut) -> Bool)?
    @ObservationIgnored var settingsShortcutChanged: ((KeyShortcut) -> Void)?
    private var assigned: [String: KeyShortcut]
    private(set) var recording: PanelCommand?
    private(set) var error: String?
    private(set) var globalAvailable = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        assigned = defaults.data(forKey: "panelShortcuts")
            .flatMap { try? JSONDecoder().decode([String: KeyShortcut].self, from: $0) } ?? [:]
    }

    subscript(command: PanelCommand) -> KeyShortcut { assigned[command.rawValue] ?? command.defaultShortcut }

    func startRecording(_ command: PanelCommand) {
        error = nil
        recording = command
    }

    func cancelRecording() { recording = nil }

    func installInitialGlobal() {
        globalAvailable = installGlobal?(self[.togglePanel]) ?? false
    }

    func command(for event: NSEvent) -> PanelCommand? {
        guard event.type == .keyDown else { return nil }
        if let command = PanelCommand.allCases.first(where: { $0 != .togglePanel && self[$0].matches(event) }) {
            return command
        }
        return Self.searchShortcut.matches(event) ? .filter : nil
    }

    func capture(_ event: NSEvent) -> Bool {
        guard let recording, event.type == .keyDown else { return false }
        if Int(event.keyCode) == kVK_Escape {
            cancelRecording()
        } else if let shortcut = KeyShortcut(event: event), assign(shortcut, to: recording) {
            cancelRecording()
        }
        return true
    }

    @discardableResult
    func assign(_ shortcut: KeyShortcut, to command: PanelCommand) -> Bool {
        if let conflict = PanelCommand.allCases.first(where: { $0 != command && self[$0].matches(shortcut) }) {
            error = L10n.text("%@ 已綁定「%@」", String(describing: shortcut.display), String(describing: conflict.title))
            return false
        }
        if shortcut.matches(KeyShortcut(kVK_ANSI_Q, "q", .command)) {
            error = L10n.text("⌘Q 用於結束 App")
            return false
        }
        if command == .settings && !shortcut.modifiers.contains(.command) {
            error = L10n.text("開啟設定的快捷鍵需包含 ⌘")
            return false
        }
        if command == .togglePanel {
            guard !shortcut.modifiers.intersection([.command, .option, .control]).isEmpty else {
                error = L10n.text("全域快捷鍵需包含 ⌘、⌥ 或 ⌃")
                return false
            }
            guard installGlobal?(shortcut) == true else {
                error = L10n.text("macOS 無法註冊 %@，請試另一組按鍵", String(describing: shortcut.display))
                return false
            }
            globalAvailable = true
        }
        assigned[command.rawValue] = shortcut
        persist()
        if command == .settings { settingsShortcutChanged?(shortcut) }
        error = nil
        return true
    }

    func reset() {
        guard installGlobal?(PanelCommand.togglePanel.defaultShortcut) == true else {
            error = L10n.text("預設的全域快捷鍵無法註冊")
            return
        }
        assigned = [:]
        globalAvailable = true
        error = nil
        recording = nil
        persist()
        settingsShortcutChanged?(self[.settings])
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(assigned) {
            defaults.set(data, forKey: "panelShortcuts")
        }
    }
}
