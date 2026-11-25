import AppKit

enum PanelTheme: String, CaseIterable {
    case system, light, dark

    static let preferenceKey = "panelTheme"

    var label: String {
        switch self {
        case .system: L10n.text("跟隨系統")
        case .light: L10n.text("淺色")
        case .dark: L10n.text("深色")
        }
    }

    @MainActor
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
