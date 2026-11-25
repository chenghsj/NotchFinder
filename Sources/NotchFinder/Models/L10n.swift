import Foundation
import Observation
import os

enum InterfaceLanguage: String, CaseIterable {
    case system
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var title: String {
        switch self {
        case .system: L10n.text("跟隨系統")
        case .traditionalChinese: "繁體中文"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

@Observable
final class L10n: Sendable {
    private struct Resources: Sendable {
        let bundle: Bundle
        let locale: Locale

        init(_ language: InterfaceLanguage) {
            let main = Bundle.main
            if language != .system,
               let url = main.url(forResource: language.rawValue, withExtension: "lproj"),
               let localized = Bundle(url: url) {
                bundle = localized
                locale = Locale(identifier: language.rawValue)
            } else {
                bundle = main
                locale = main.preferredLocalizations.first.map(Locale.init(identifier:)) ?? .current
            }
        }
    }

    private static let shared = L10n()
    // Views observe the selection while background file operations can read it safely.
    private let selection = OSAllocatedUnfairLock(initialState: Resources(.system))

    private var resources: Resources {
        access(keyPath: \.resources)
        return selection.withLock { $0 }
    }

    @MainActor
    static func select(_ language: InterfaceLanguage) {
        let resources = Resources(language)
        shared.withMutation(keyPath: \.resources) {
            shared.selection.withLock { $0 = resources }
        }
    }

    static func text(_ key: String, _ arguments: String...) -> String {
        let resources = shared.resources
        let translation = resources.bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return translation }
        return String(format: translation, locale: .current, arguments: arguments)
    }

    static var locale: Locale { shared.resources.locale }
}
