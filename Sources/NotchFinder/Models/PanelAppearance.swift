import AppKit
import SwiftUI

struct PanelAppearance: Equatable {
    private static let preferenceKey = "panelAppearance"
    private(set) var colorMode: PanelTheme = .system
    private var lightPreset: PanelStylePreset = .native
    private var darkPreset: PanelStylePreset = .native
    var fontStyle: PanelFontStyle = .system
    private(set) var customAccent: Int?

    init() {}

    init(defaults: UserDefaults) {
        let stored = defaults.dictionary(forKey: Self.preferenceKey)
        let modeID: String?
        let presetID: String?
        let fontID: String?
        let accent: Int?
        if let stored {
            modeID = stored["mode"] as? String
            presetID = stored["preset"] as? String
            fontID = stored["font"] as? String
            accent = stored["accent"] as? Int
        } else {
            modeID = defaults.string(forKey: PanelTheme.preferenceKey)
            presetID = defaults.string(forKey: "panelStylePreset")
            fontID = defaults.string(forKey: "panelFontStyle")
            accent = defaults.object(forKey: "panelCustomAccent") as? Int
        }
        colorMode = modeID.flatMap(PanelTheme.init(rawValue:)) ?? .system
        if stored?["lightPreset"] != nil || stored?["darkPreset"] != nil {
            if let light = (stored?["lightPreset"] as? String).flatMap(PanelStylePreset.init(rawValue:)) {
                selectPreset(light, for: .light)
            }
            if let dark = (stored?["darkPreset"] as? String).flatMap(PanelStylePreset.init(rawValue:)) {
                selectPreset(dark, for: .dark)
            }
        } else if let previousPreset = presetID.flatMap(PanelStylePreset.init(rawValue:)) {
            selectPreset(previousPreset, for: .light)
            selectPreset(previousPreset, for: .dark)
            if let required = previousPreset.requiredColorMode { colorMode = required }
        }
        fontStyle = fontID.flatMap(PanelFontStyle.init(rawValue:)) ?? .system
        setCustomAccent(accent)
    }

    func save(to defaults: UserDefaults) {
        var value: [String: Any] = [
            "mode": colorMode.rawValue,
            "lightPreset": lightPreset.rawValue,
            "darkPreset": darkPreset.rawValue,
            "font": fontStyle.rawValue
        ]
        if let customAccent { value["accent"] = customAccent }
        defaults.set(value, forKey: Self.preferenceKey)
    }

    mutating func selectMode(_ mode: PanelTheme) {
        colorMode = mode
    }

    func preset(for scheme: ColorScheme) -> PanelStylePreset {
        scheme == .dark ? darkPreset : lightPreset
    }

    mutating func selectPreset(_ preset: PanelStylePreset, for scheme: ColorScheme) {
        guard preset.supports(scheme) else { return }
        if scheme == .dark { darkPreset = preset }
        else { lightPreset = preset }
    }

    mutating func setCustomAccent(_ accent: Int?) {
        customAccent = accent.flatMap { (0...0xFFFFFF).contains($0) ? $0 : nil }
    }

    func accentValue(for scheme: ColorScheme) -> Int? {
        customAccent ?? preset(for: scheme).accentValue(for: scheme)
    }

    func accentColor(for scheme: ColorScheme) -> Color? {
        accentValue(for: scheme).map { Color(nsColor: PanelRGB.nsColor($0)) }
    }
}

struct PanelStylePreset: RawRepresentable, Hashable, Identifiable {
    private struct Palette: Hashable {
        let surface: Int
        let ink: Int
        let accent: Int
        var windowOverride: Int? = nil

        var window: Int {
            if let windowOverride { return windowOverride }
            func blend(_ shift: Int) -> Int {
                let background = (surface >> shift) & 255
                let foreground = (ink >> shift) & 255
                return (background * 96 + foreground * 4 + 50) / 100
            }
            return (blend(16) << 16) | (blend(8) << 8) | blend(0)
        }
    }

    let rawValue: String
    let title: String
    private let light: Palette?
    private let dark: Palette?

    var id: String { rawValue }

    init?(rawValue: String) {
        guard let preset = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = preset
    }

    private init(_ rawValue: String, _ title: String, light: Palette? = nil, dark: Palette? = nil) {
        self.rawValue = rawValue
        self.title = title
        self.light = light
        self.dark = dark
    }

    var requiredColorMode: PanelTheme? {
        if light == nil && dark != nil { return .dark }
        if light != nil && dark == nil { return .light }
        return nil
    }

    func supports(_ scheme: ColorScheme) -> Bool {
        let mode: PanelTheme = scheme == .dark ? .dark : .light
        return (requiredColorMode ?? mode) == mode
    }

    static func available(in scheme: ColorScheme) -> [Self] {
        allCases.filter { $0.supports(scheme) }
    }

    var windowColor: Color { adaptiveColor(for: \.window) ?? Color(nsColor: .windowBackgroundColor) }
    var contentColor: Color { adaptiveColor(for: \.surface) ?? Color(nsColor: .controlBackgroundColor) }

    func listStripeColor(for scheme: ColorScheme) -> NSColor? {
        guard let palette = palette(for: scheme) else { return nil }
        return PanelRGB.nsColor(palette.surface).blended(withFraction: 0.07, of: PanelRGB.nsColor(palette.ink))
    }

    func accentValue(for scheme: ColorScheme) -> Int? {
        palette(for: scheme)?.accent
    }

    func previewColors(for scheme: ColorScheme) -> (surface: NSColor, accent: NSColor) {
        guard let palette = palette(for: scheme) else {
            return (.controlBackgroundColor, .controlAccentColor)
        }
        return (PanelRGB.nsColor(palette.surface), PanelRGB.nsColor(palette.accent))
    }

    private func palette(for scheme: ColorScheme) -> Palette? {
        scheme == .dark ? dark ?? light : light ?? dark
    }

    private func adaptiveColor(for key: KeyPath<Palette, Int>) -> Color? {
        guard let lightValue = (light ?? dark)?[keyPath: key],
              let darkValue = (dark ?? light)?[keyPath: key] else { return nil }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return PanelRGB.nsColor(isDark ? darkValue : lightValue)
        })
    }

    static let native = Self("native", "System")
    static let sandstone = Self("sandstone", "Sandstone",
                                light: Palette(surface: 0xFCF7F0, ink: 0x202020, accent: 0xA35D36, windowOverride: 0xF2EAE0),
                                dark: Palette(surface: 0x25211E, ink: 0xEEEEEE, accent: 0xA35D36, windowOverride: 0x302823))
    static let seaGlass = Self("seaGlass", "Sea Glass",
                               light: Palette(surface: 0xF4F9FA, ink: 0x202020, accent: 0x008784, windowOverride: 0xE6F1F1),
                               dark: Palette(surface: 0x18242B, ink: 0xEEEEEE, accent: 0x008784, windowOverride: 0x1F2D33))

    // Theme names and light/dark palette values from the Codex 26.1120.50957 catalog.
    static let allCases: [Self] = [.native] + [
        .sandstone, .seaGlass,
        Self("absolutely", "Absolutely",
             light: Palette(surface: 0xF9F9F7, ink: 0x2D2D2B, accent: 0xCC7D5E),
             dark: Palette(surface: 0x2D2D2B, ink: 0xF9F9F7, accent: 0xCC7D5E)),
        Self("ayu", "Ayu",
             dark: Palette(surface: 0x10141C, ink: 0xBFBDB6, accent: 0xE6B450)),
        Self("catppuccin", "Catppuccin",
             light: Palette(surface: 0xEFF1F5, ink: 0x4C4F69, accent: 0x8839EF),
             dark: Palette(surface: 0x1E1E2E, ink: 0xCDD6F4, accent: 0xCBA6F7)),
        Self("codex", "Codex",
             light: Palette(surface: 0xFFFFFF, ink: 0x1A1C1F, accent: 0x339CFF),
             dark: Palette(surface: 0x181818, ink: 0xFFFFFF, accent: 0x339CFF)),
        Self("dracula", "Dracula",
             dark: Palette(surface: 0x282A36, ink: 0xF8F8F2, accent: 0xFF79C6)),
        Self("everforest", "Everforest",
             light: Palette(surface: 0xFDF6E3, ink: 0x5C6A72, accent: 0x93B259),
             dark: Palette(surface: 0x2D353B, ink: 0xD3C6AA, accent: 0xA7C080)),
        Self("github", "GitHub",
             light: Palette(surface: 0xFFFFFF, ink: 0x1F2328, accent: 0x0969DA),
             dark: Palette(surface: 0x0D1117, ink: 0xE6EDF3, accent: 0x1F6FEB)),
        Self("gruvbox", "Gruvbox",
             light: Palette(surface: 0xFBF1C7, ink: 0x3C3836, accent: 0x458588),
             dark: Palette(surface: 0x282828, ink: 0xEBDBB2, accent: 0x458588)),
        Self("linear", "Linear",
             light: Palette(surface: 0xFCFCFD, ink: 0x1B1B1B, accent: 0x5E6AD2),
             dark: Palette(surface: 0x0F0F11, ink: 0xE3E4E6, accent: 0x606ACC)),
        Self("lobster", "Lobster",
             dark: Palette(surface: 0x111827, ink: 0xE4E4E7, accent: 0xFF5C5C)),
        Self("material", "Material",
             dark: Palette(surface: 0x212121, ink: 0xEEFFFF, accent: 0x80CBC4)),
        Self("matrix", "Matrix",
             dark: Palette(surface: 0x040805, ink: 0xB8FFCA, accent: 0x1EFF5A)),
        Self("monokai", "Monokai",
             dark: Palette(surface: 0x272822, ink: 0xF8F8F2, accent: 0x99947C)),
        Self("night-owl", "Night Owl",
             dark: Palette(surface: 0x011627, ink: 0xD6DEEB, accent: 0x44596B)),
        Self("nord", "Nord",
             dark: Palette(surface: 0x2E3440, ink: 0xD8DEE9, accent: 0x88C0D0)),
        Self("notion", "Notion",
             light: Palette(surface: 0xFFFFFF, ink: 0x37352F, accent: 0x3183D8),
             dark: Palette(surface: 0x191919, ink: 0xD9D9D8, accent: 0x3183D8)),
        Self("og", "OG",
             dark: Palette(surface: 0x343541, ink: 0xD1D5DB, accent: 0x10A37F)),
        Self("one", "One",
             light: Palette(surface: 0xFAFAFA, ink: 0x383A42, accent: 0x526FFF),
             dark: Palette(surface: 0x282C34, ink: 0xABB2BF, accent: 0x4D78CC)),
        Self("oscurange", "Oscurange",
             dark: Palette(surface: 0x0B0B0F, ink: 0xE6E6E6, accent: 0xF9B98C)),
        Self("proof", "Proof",
             light: Palette(surface: 0xF5F3ED, ink: 0x2F312D, accent: 0x3D755D)),
        Self("raycast", "Raycast",
             light: Palette(surface: 0xFFFFFF, ink: 0x030303, accent: 0xFF6363),
             dark: Palette(surface: 0x101010, ink: 0xFEFEFE, accent: 0xFF6363)),
        Self("rose-pine", "Rose Pine",
             light: Palette(surface: 0xFAF4ED, ink: 0x575279, accent: 0xD7827E),
             dark: Palette(surface: 0x232136, ink: 0xE0DEF4, accent: 0xEA9A97)),
        Self("sentry", "Sentry",
             dark: Palette(surface: 0x2D2935, ink: 0xE6DFF9, accent: 0x7055F6)),
        Self("solarized", "Solarized",
             light: Palette(surface: 0xFDF6E3, ink: 0x657B83, accent: 0xB58900),
             dark: Palette(surface: 0x002B36, ink: 0x839496, accent: 0xD30102)),
        Self("temple", "Temple",
             dark: Palette(surface: 0x02120C, ink: 0xC7E6DA, accent: 0xE4F222)),
        Self("tokyo-night", "Tokyo Night",
             dark: Palette(surface: 0x1A1B26, ink: 0xA9B1D6, accent: 0x3D59A1)),
        Self("vercel", "Vercel",
             light: Palette(surface: 0xFFFFFF, ink: 0x171717, accent: 0x006AFF),
             dark: Palette(surface: 0x000000, ink: 0xEDEDED, accent: 0x006EFE)),
        Self("vscode-plus", "VS Code Plus",
             light: Palette(surface: 0xFFFFFF, ink: 0x000000, accent: 0x007ACC),
             dark: Palette(surface: 0x1E1E1E, ink: 0xD4D4D4, accent: 0x007ACC)),
        Self("xcode", "Xcode",
             light: Palette(surface: 0xFFFFFF, ink: 0x000000, accent: 0x0E0EFF),
             dark: Palette(surface: 0x1F1F24, ink: 0xFFFFFF, accent: 0x5482FF)),
    ].sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
}

enum PanelFontStyle: String, CaseIterable {
    case system, rounded, serif, monospaced

    var title: String {
        switch self {
        case .system: L10n.text("系統字型")
        case .rounded: L10n.text("圓體")
        case .serif: L10n.text("襯線")
        case .monospaced: L10n.text("等寬")
        }
    }

    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

enum PanelRGB {
    static func nsColor(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                green: Double((rgb >> 8) & 255) / 255,
                blue: Double(rgb & 255) / 255,
                alpha: 1)
    }

    static func value(of color: Color) -> Int? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        let bytes = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        let (red, green, blue) = (bytes[0], bytes[1], bytes[2])
        return (red << 16) | (green << 8) | blue
    }
}

private struct PanelStyleKey: EnvironmentKey {
    static let defaultValue = PanelStylePreset.native
}

extension EnvironmentValues {
    var panelStyle: PanelStylePreset {
        get { self[PanelStyleKey.self] }
        set { self[PanelStyleKey.self] = newValue }
    }
}
