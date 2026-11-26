import AppKit
import Foundation
import Observation
import SwiftUI

enum PanelAnimationSpeed: String, CaseIterable {
    case fast, standard, off

    var title: String {
        switch self {
        case .fast: L10n.text("快速")
        case .standard: L10n.text("標準")
        case .off: L10n.text("關閉")
        }
    }

    var rate: Double { self == .fast ? 1.4 : 1 }
}

enum StartupFolder: String, CaseIterable {
    case home, last, clipboard, custom

    var title: String {
        switch self {
        case .home: L10n.text("個人資料夾")
        case .last: L10n.text("上次位置")
        case .clipboard: L10n.text("剪貼簿")
        case .custom: L10n.text("指定資料夾")
        }
    }
}

enum FileSort: String, CaseIterable {
    case name, kind, size, modified

    var title: String {
        switch self {
        case .name: L10n.text("名稱")
        case .kind: L10n.text("種類")
        case .size: L10n.text("大小")
        case .modified: L10n.text("修改日期")
        }
    }
}

enum FileDisplayMode: String, CaseIterable {
    case icons
    case list = "details"
    case columns, gallery

    var title: String {
        switch self {
        case .icons: L10n.text("圖像")
        case .list: L10n.text("列表")
        case .columns: L10n.text("直欄")
        case .gallery: L10n.text("圖庫")
        }
    }

    var symbol: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        case .gallery: "squares.below.rectangle"
        }
    }
}

enum FileDisplaySize: String, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: L10n.text("小")
        case .medium: L10n.text("中")
        case .large: L10n.text("大")
        }
    }

    var row: (icon: CGFloat, height: CGFloat) {
        switch self {
        case .small: (20, 30)
        case .medium: (24, 36)
        case .large: (28, 42)
        }
    }

    var grid: (icon: CGFloat, width: CGFloat, height: CGFloat) {
        switch self {
        case .small: (56, 112, 112)
        case .medium: (64, 128, 128)
        case .large: (72, 144, 144)
        }
    }

    var panelIcon: CGFloat { panelText + 2 }
    var preferencesScale: CGFloat { panelIcon / Self.small.panelIcon }

    var panelText: CGFloat {
        switch self {
        case .small: NSFont.systemFontSize
        case .medium: NSFont.systemFontSize + 2
        case .large: NSFont.systemFontSize + 4
        }
    }
}

enum PreferencesPage: String, CaseIterable {
    case triggers, appearance, sidebar, browsing, clipboard, shortcuts, about
}

@MainActor
@Observable
final class NotchSettings {
    static let sidebarWidths: ClosedRange<Double> = 112...260
    private static let locationDisplayModesKey = "fileDisplayModesByLocation"
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var colorModeDidChange: ((PanelTheme) -> Void)?
    @ObservationIgnored var dockIconVisibilityDidChange: ((Bool) -> Void)?
    @ObservationIgnored var interfaceSizeDidChange: (() -> Void)?
    @ObservationIgnored var interfaceLanguageDidChange: ((InterfaceLanguage) -> Void)?
    @ObservationIgnored var updatePreferencesDidChange: (() -> Void)?

    private(set) var appearance: PanelAppearance {
        didSet {
            guard appearance != oldValue else { return }
            appearance.save(to: defaults)
            if appearance.colorMode != oldValue.colorMode { colorModeDidChange?(appearance.colorMode) }
        }
    }

    var interfaceLanguage: InterfaceLanguage {
        didSet {
            guard interfaceLanguage != oldValue else { return }
            defaults.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage")
            interfaceLanguageDidChange?(interfaceLanguage)
        }
    }
    var showsDockIcon: Bool {
        didSet {
            guard showsDockIcon != oldValue else { return }
            defaults.set(showsDockIcon, forKey: "showsDockIcon")
            dockIconVisibilityDidChange?(showsDockIcon)
        }
    }
    var checksForUpdates: Bool {
        didSet {
            guard checksForUpdates != oldValue else { return }
            defaults.set(checksForUpdates, forKey: "checksForUpdates")
            updatePreferencesDidChange?()
        }
    }
    var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard automaticallyDownloadsUpdates != oldValue else { return }
            defaults.set(automaticallyDownloadsUpdates, forKey: "automaticallyDownloadsUpdates")
            updatePreferencesDidChange?()
        }
    }
    var automaticallyInstallsUpdates: Bool {
        didSet {
            guard automaticallyInstallsUpdates != oldValue else { return }
            defaults.set(automaticallyInstallsUpdates, forKey: "automaticallyInstallsUpdates")
            updatePreferencesDidChange?()
        }
    }
    var installsUpdatesOnQuit: Bool {
        checksForUpdates && automaticallyDownloadsUpdates && automaticallyInstallsUpdates
    }
    var updateReadyToInstall = false
    var hoverEnabled: Bool { didSet { defaults.set(hoverEnabled, forKey: "hoverEnabled") } }
    var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    var autoHide: Bool { didSet { defaults.set(autoHide, forKey: "autoHide") } }
    var hideDelay: Double { didSet { defaults.set(hideDelay, forKey: "hideDelay") } }
    var animation: PanelAnimationSpeed { didSet { defaults.set(animation.rawValue, forKey: "panelAnimation") } }
    var preferencesPage: PreferencesPage { didSet { defaults.set(preferencesPage.rawValue, forKey: "preferencesPage") } }
    var interfaceSize: FileDisplaySize {
        didSet {
            guard interfaceSize != oldValue else { return }
            defaults.set(interfaceSize.rawValue, forKey: "interfaceSize")
            interfaceSizeDidChange?()
        }
    }
    var remembersSize: Bool { didSet { defaults.set(remembersSize, forKey: "remembersPanelSize") } }
    var startupFolder: StartupFolder { didSet { defaults.set(startupFolder.rawValue, forKey: "startupFolder") } }
    var customFolder: String { didSet { defaults.set(customFolder, forKey: "customStartupFolder") } }
    var fileSort: FileSort { didSet { defaults.set(fileSort.rawValue, forKey: "defaultFileSort") } }
    var foldersFirst: Bool { didSet { defaults.set(foldersFirst, forKey: "foldersFirst") } }
    var groupsByAddedDate: Bool { didSet { defaults.set(groupsByAddedDate, forKey: "groupsByAddedDate") } }
    var cleansDiskImageAfterInstall: Bool { didSet { defaults.set(cleansDiskImageAfterInstall, forKey: "cleansDiskImageAfterInstall") } }
    var defaultDisplayMode: FileDisplayMode {
        didSet { defaults.set(defaultDisplayMode.rawValue, forKey: "fileDisplayMode") }
    }
    private var locationDisplayModes: [String: FileDisplayMode]
    var showsClipboardInSidebar: Bool { didSet { defaults.set(showsClipboardInSidebar, forKey: "showsClipboardInSidebar") } }
    private var sidebarWidthOverride: Double? { didSet { defaults.set(sidebarWidthOverride, forKey: "sidebarWidth") } }

    var sidebarWidth: Double {
        get { sidebarWidthOverride ?? (138 + Double(interfaceSize.panelText - NSFont.systemFontSize) * 8) }
        set { sidebarWidthOverride = Self.clampSidebarWidth(newValue) }
    }

    var panelPinned = false
    var filterFocusRequest = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = PanelAppearance(defaults: defaults)
        interfaceLanguage = defaults.string(forKey: "interfaceLanguage").flatMap(InterfaceLanguage.init(rawValue:)) ?? .system
        showsDockIcon = defaults.bool(forKey: "showsDockIcon")
        checksForUpdates = defaults.object(forKey: "checksForUpdates") as? Bool ?? true
        automaticallyDownloadsUpdates = defaults.bool(forKey: "automaticallyDownloadsUpdates")
        automaticallyInstallsUpdates = defaults.bool(forKey: "automaticallyInstallsUpdates")
        hoverEnabled = defaults.object(forKey: "hoverEnabled") as? Bool ?? true
        hoverDelay = Self.delay(defaults.object(forKey: "hoverDelay"), fallback: 0.15)
        autoHide = defaults.object(forKey: "autoHide") as? Bool ?? true
        hideDelay = Self.delay(defaults.object(forKey: "hideDelay"), fallback: 0.24)
        animation = defaults.string(forKey: "panelAnimation").flatMap(PanelAnimationSpeed.init(rawValue:)) ?? .standard
        preferencesPage = defaults.string(forKey: "preferencesPage").flatMap(PreferencesPage.init(rawValue:)) ?? .triggers
        if let savedSize = defaults.string(forKey: "interfaceSize").flatMap(FileDisplaySize.init(rawValue:)) {
            interfaceSize = savedSize
        } else {
            let previousSize = ["fileTextSize", "fileIconSize", "fileDisplaySize"].lazy.compactMap { key in
                defaults.string(forKey: key).flatMap(FileDisplaySize.init(rawValue:))
            }.first
            // The former large text size matches the new medium size.
            interfaceSize = previousSize == .large ? .medium : .small
        }
        remembersSize = defaults.object(forKey: "remembersPanelSize") as? Bool ?? true
        startupFolder = defaults.string(forKey: "startupFolder").flatMap(StartupFolder.init(rawValue:)) ?? .home
        customFolder = defaults.string(forKey: "customStartupFolder") ?? ""
        fileSort = defaults.string(forKey: "defaultFileSort").flatMap(FileSort.init(rawValue:)) ?? .name
        foldersFirst = defaults.object(forKey: "foldersFirst") as? Bool ?? true
        groupsByAddedDate = defaults.object(forKey: "groupsByAddedDate") as? Bool ?? true
        cleansDiskImageAfterInstall = defaults.bool(forKey: "cleansDiskImageAfterInstall")
        // The removed Compact List preference also falls back to List.
        defaultDisplayMode = defaults.string(forKey: "fileDisplayMode").flatMap(FileDisplayMode.init(rawValue:)) ?? .list
        locationDisplayModes = defaults.dictionary(forKey: Self.locationDisplayModesKey)?.compactMapValues {
            ($0 as? String).flatMap(FileDisplayMode.init(rawValue:))
        } ?? [:]
        showsClipboardInSidebar = defaults.object(forKey: "showsClipboardInSidebar") as? Bool ?? true
        sidebarWidthOverride = (defaults.object(forKey: "sidebarWidth") as? Double)
            .flatMap { $0.isFinite ? Self.clampSidebarWidth($0) : nil }
    }

    func displayMode(for destination: FileBrowser.Destination) -> FileDisplayMode {
        locationDisplayModes[destination.displayModeKey] ?? defaultDisplayMode
    }

    func setDisplayMode(_ mode: FileDisplayMode, for destination: FileBrowser.Destination) {
        let key = destination.displayModeKey
        guard locationDisplayModes[key] != mode else { return }
        locationDisplayModes[key] = mode
        defaults.set(locationDisplayModes.mapValues(\.rawValue), forKey: Self.locationDisplayModesKey)
    }

    func selectColorMode(_ mode: PanelTheme) { appearance.selectMode(mode) }
    func selectStylePreset(_ preset: PanelStylePreset, for scheme: ColorScheme) {
        appearance.selectPreset(preset, for: scheme)
    }
    func setFontStyle(_ font: PanelFontStyle) { appearance.fontStyle = font }
    func setCustomAccent(_ accent: Int?) { appearance.setCustomAccent(accent) }

    var canRestoreDefaultAppearance: Bool { appearance != PanelAppearance() }

    func restoreDefaultAppearance() { appearance = PanelAppearance() }

    func panelFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: appearance.fontStyle.design)
    }

    var opensClipboardAtStartup: Bool {
        startupFolder == .clipboard || (startupFolder == .last && defaults.bool(forKey: "lastLocationWasClipboard"))
    }

    var startDirectory: URL? {
        let path: String?
        switch startupFolder {
        case .home: path = nil
        case .last, .clipboard: path = defaults.string(forKey: "lastVisitedFolder")
        case .custom: path = customFolder
        }
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func delay(_ value: Any?, fallback: Double) -> Double {
        guard let seconds = value as? Double, seconds.isFinite else { return fallback }
        return min(1, max(0, seconds))
    }

    private static func clampSidebarWidth(_ value: Double) -> Double {
        min(sidebarWidths.upperBound, max(sidebarWidths.lowerBound, value))
    }
}
