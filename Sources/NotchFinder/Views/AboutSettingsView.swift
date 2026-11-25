import AppKit
import SwiftUI

struct AboutSettingsView: View {
    private static let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    private let bundle = Bundle.main

    private var appName: String {
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Notch Finder"
    }

    private var version: String? {
        guard let release = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return L10n.text("版本 %@（組建 %@）", release, build)
        }
        return release
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: Self.appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110, height: 110)
                        .accessibilityHidden(true)
                    Text(verbatim: appName)
                        .font(.title.weight(.semibold))
                    if let version {
                        Text(verbatim: version)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
                Section {
                    LabeledContent {
                        Text(L10n.text("macOS %@ 或更新版本", minimum))
                    } label: {
                        Label(L10n.text("系統需求"), systemImage: "desktopcomputer")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
