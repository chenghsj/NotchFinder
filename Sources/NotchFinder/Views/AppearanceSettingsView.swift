import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var settings: NotchSettings
    var restoreSize: () -> Void
    var saveSize: () -> Void

    var body: some View {
        Form {
            Section(L10n.text("視覺風格")) {
                colorModes
                themePicker
                LabeledContent(L10n.text("強調色")) {
                    HStack(spacing: 8) {
                        if let rgb = settings.appearance.accentValue(for: colorScheme) {
                            Text(String(format: "#%06X", rgb))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if settings.appearance.customAccent != nil {
                            Button(L10n.text("恢復預設強調色")) { settings.setCustomAccent(nil) }
                                .controlSize(.small)
                        }
                        ColorPicker(L10n.text("強調色"), selection: accentSelection, supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                Picker(L10n.text("字型風格"), selection: fontSelection) {
                    ForEach(PanelFontStyle.allCases, id: \.self) { font in
                        Text(font.title).fontDesign(font.design).tag(font)
                    }
                }
                Button(L10n.text("恢復預設外觀"), action: settings.restoreDefaultAppearance)
                    .disabled(!settings.canRestoreDefaultAppearance)
            }
            Section(L10n.text("顯示")) {
                Picker(L10n.text("介面大小"), selection: $settings.interfaceSize) {
                    ForEach(FileDisplaySize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle(L10n.text("記住最後使用的尺寸"), isOn: $settings.remembersSize)
                    .onChange(of: settings.remembersSize) { _, value in if value { saveSize() } }
                Button(L10n.text("恢復預設尺寸"), action: restoreSize)
            } header: {
                Text(L10n.text("面板大小"))
            } footer: {
                Text(L10n.text("關閉後，面板下次展開時會使用預設尺寸。"))
            }
        }
        .formStyle(.grouped)
    }

    private var themePicker: some View {
        let scheme: ColorScheme = switch settings.appearance.colorMode {
        case .system: colorScheme
        case .light: .light
        case .dark: .dark
        }
        let selection = Binding(
            get: { settings.appearance.preset(for: scheme) },
            set: { settings.selectStylePreset($0, for: scheme) }
        )
        return LabeledContent(L10n.text("主題")) {
            ThemePresetPicker(selection: selection, scheme: scheme)
                .fixedSize()
        }
    }

    private var fontSelection: Binding<PanelFontStyle> {
        Binding(get: { settings.appearance.fontStyle }, set: settings.setFontStyle)
    }

    private var accentSelection: Binding<Color> {
        Binding(
            get: { settings.appearance.accentColor(for: colorScheme) ?? .accentColor },
            set: { if let color = PanelRGB.value(of: $0) { settings.setCustomAccent(color) } }
        )
    }

    private var colorModes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("色彩模式"))
            HStack(spacing: 10) {
                ForEach(PanelTheme.allCases, id: \.self) { mode in
                    colorModeButton(mode)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func colorModeButton(_ mode: PanelTheme) -> some View {
        Button { settings.selectColorMode(mode) } label: {
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    if mode != .dark { preview(dark: false) }
                    if mode != .light { preview(dark: true) }
                }
                .frame(width: 44, height: 25)
                .clipShape(.rect(cornerRadius: 4))
                .accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(mode == .system ? L10n.text("色彩模式跟隨系統") : mode.label)
                        .lineLimit(1)
                    if settings.appearance.colorMode == mode {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(settings.appearance.accentColor(for: colorScheme) ?? Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, minHeight: 47)
        }
        .buttonStyle(.bordered)
        .overlay {
            if settings.appearance.colorMode == mode {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder((settings.appearance.accentColor(for: colorScheme) ?? Color.accentColor).opacity(0.65))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(settings.appearance.colorMode == mode ? .isSelected : [])
    }

    private func preview(dark: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(dark ? Color(white: 0.19) : Color(white: 0.94))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                    .fill(Color(white: 0.09))
                    .frame(width: 7, height: 2)
            }
            .overlay {
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(dark ? .white.opacity(0.16) : .black.opacity(0.1))
                        .frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Capsule().frame(maxWidth: 15)
                        Capsule().frame(maxWidth: 11)
                    }
                    .foregroundStyle(dark ? .white.opacity(0.37) : .black.opacity(0.21))
                    .frame(height: 5)
                }
                .padding(4)
            }
    }
}
