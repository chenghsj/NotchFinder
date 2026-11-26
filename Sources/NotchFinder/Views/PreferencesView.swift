import AppKit
import ServiceManagement
import SwiftUI

private extension PreferencesPage {
    var title: String {
        switch self {
        case .triggers: L10n.text("一般")
        case .appearance: L10n.text("外觀")
        case .sidebar: L10n.text("側邊欄")
        case .browsing: L10n.text("檔案瀏覽")
        case .clipboard: L10n.text("剪貼簿")
        case .shortcuts: L10n.text("快捷鍵")
        case .about: L10n.text("關於")
        }
    }

    var symbol: String {
        switch self {
        case .triggers: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .sidebar: "sidebar.left"
        case .browsing: "folder"
        case .clipboard: "clipboard"
        case .shortcuts: "keyboard"
        case .about: "info.circle"
        }
    }
}

struct PreferencesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var sidebarFocused: Bool
    @State private var sidebarWidth: CGFloat = 216
    @GestureState private var sidebarDragOffset: CGFloat = 0
    @Bindable var settings: NotchSettings
    @Bindable var shortcuts: PanelShortcuts
    let tabs: BrowserTabs
    @Bindable var clipboardHistory: ClipboardHistory
    var restoreSize: () -> Void
    var saveSize: () -> Void

    private let sidebarDividerWidth: CGFloat = 7

    private var selection: Binding<PreferencesPage?> {
        Binding(
            get: { settings.preferencesPage },
            set: { if let page = $0 { settings.preferencesPage = page } }
        )
    }

    var body: some View {
        let preset = settings.appearance.preset(for: colorScheme)
        let accent = settings.appearance.accentColor(for: colorScheme)
        let size = settings.interfaceSize
        let scale = size.preferencesScale
        let width = clampedSidebarWidth(sidebarWidth + sidebarDragOffset / scale) * scale
        HStack(spacing: 0) {
            sidebar(size: size, preset: preset, accent: accent)
                .frame(width: width)

            let page = settings.preferencesPage
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title)
                    .font(settings.panelFont(size: size.panelText + 4, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24 * scale)
                    .padding(.top, 18 * scale)

                Group {
                    switch page {
                    case .triggers: triggers
                    case .appearance: appearance
                    case .sidebar: SidebarPreferencesView(settings: settings, locations: tabs.active.browser.sidebar)
                    case .browsing: browsing
                    case .clipboard: clipboard
                    case .shortcuts: keyBindings
                    case .about: AboutSettingsView()
                    }
                }
                .scrollContentBackground(preset == .native ? .automatic : .hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(preset.windowColor)
        }
        .overlay(alignment: .leading) {
            sidebarDivider(width: width, scale: scale, accent: accent)
                .offset(x: width - sidebarDividerWidth / 2)
        }
        .accentColor(accent)
        .tint(accent)
        .font(settings.panelFont(size: settings.interfaceSize.panelText))
    }

    @ViewBuilder
    private func sidebar(size: FileDisplaySize, preset: PanelStylePreset, accent: Color?) -> some View {
        let scale = size.preferencesScale
        if let accent {
            let cornerRadius: CGFloat = 8
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(PreferencesPage.allCases, id: \.self) { page in
                            let selected = page == settings.preferencesPage
                            Button {
                                settings.preferencesPage = page
                                sidebarFocused = true
                            } label: {
                                sidebarLabel(page, size: size, selected: selected, accent: accent)
                                    .frame(maxWidth: .infinity, minHeight: 33 * scale, alignment: .leading)
                                    .padding(.horizontal, 8 * scale)
                            }
                            .buttonStyle(PanelButtonStyle(selected: selected, cornerRadius: cornerRadius, accent: accent))
                            .overlay {
                                if selected && sidebarFocused {
                                    RoundedRectangle(cornerRadius: cornerRadius)
                                        .strokeBorder(accent)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .id(page)
                        }
                    }
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 9 * scale)
                }
                .focusable()
                .focused($sidebarFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    let pages = PreferencesPage.allCases
                    guard let index = pages.firstIndex(of: settings.preferencesPage) else { return }
                    let next: Int
                    switch direction {
                    case .up: next = index - 1
                    case .down: next = index + 1
                    default: return
                    }
                    guard pages.indices.contains(next) else { return }
                    settings.preferencesPage = pages[next]
                    scroll.scrollTo(pages[next])
                }
            }
            .background(preset.windowColor)
            .accessibilityLabel(L10n.text("側邊欄"))
        } else {
            List(selection: selection) {
                ForEach(PreferencesPage.allCases, id: \.self) { page in
                    sidebarLabel(page, size: size)
                        .frame(minHeight: 23 * scale)
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func sidebarLabel(_ page: PreferencesPage, size: FileDisplaySize,
                              selected: Bool = false, accent: Color? = nil) -> some View {
        Label {
            Text(page.title)
                .font(settings.panelFont(size: size.panelText, weight: selected ? .semibold : .regular))
                .lineLimit(1)
        } icon: {
            let symbol = Image(systemName: page.symbol)
            Group {
                if let accent { symbol.foregroundStyle(accent) }
                else { symbol }
            }
            .font(.system(size: size.panelIcon))
            .frame(width: 22 * size.preferencesScale)
        }
    }

    private func sidebarDivider(width: CGFloat, scale: CGFloat, accent: Color?) -> some View {
        let divider = Rectangle()
            .fill(accent?.opacity(0.3) ?? Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: sidebarDividerWidth)
            .contentShape(.rect)

        return sidebarResizePointer(divider)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($sidebarDragOffset) { drag, offset, _ in offset = drag.translation.width }
                    .onEnded { drag in
                        sidebarWidth = clampedSidebarWidth(sidebarWidth + drag.translation.width / scale)
                    }
            )
            .accessibilityLabel(L10n.text("側邊欄寬度"))
            .accessibilityValue(L10n.text("%@ 點", String(describing: Int(width.rounded()))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: sidebarWidth = clampedSidebarWidth(sidebarWidth + 10)
                case .decrement: sidebarWidth = clampedSidebarWidth(sidebarWidth - 10)
                @unknown default: break
                }
            }
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(260, max(160, width))
    }

    @ViewBuilder
    private func sidebarResizePointer<Divider: View>(_ divider: Divider) -> some View {
        if #available(macOS 15, *) {
            divider.pointerStyle(.columnResize)
        } else {
            divider.onHover { hovering in
                let cursor: NSCursor = hovering ? .resizeLeftRight : .arrow
                cursor.set()
            }
        }
    }

    private var triggers: some View {
        Form {
            Section {
                Picker(L10n.text("介面語言"), selection: $settings.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.menu)
            }

            Section(L10n.text("面板行為")) {
                Toggle(L10n.text("游標停在瀏海時展開"), isOn: $settings.hoverEnabled)
                delay(L10n.text("展開前停留"), value: $settings.hoverDelay)
                    .disabled(!settings.hoverEnabled)
                Toggle(L10n.text("游標離開後自動收合"), isOn: $settings.autoHide)
                delay(L10n.text("離開後等待"), value: $settings.hideDelay)
                    .disabled(!settings.autoHide)
            }

            Section(L10n.text("動畫")) {
                Picker(L10n.text("動畫速度"), selection: $settings.animation) {
                    ForEach(PanelAnimationSpeed.allCases, id: \.self) { speed in Text(speed.title).tag(speed) }
                }
            }

            Section(L10n.text("啟動")) {
                LoginItemSetting()
                Toggle(L10n.text("在 Dock 顯示"), isOn: $settings.showsDockIcon)
            }

            Section(L10n.text("軟體更新")) {
                Toggle(L10n.text("自動檢查更新"), isOn: $settings.checksForUpdates)
                Toggle(L10n.text("自動下載更新"), isOn: $settings.automaticallyDownloadsUpdates)
                    .disabled(!settings.checksForUpdates)
                    .help(L10n.text("關閉自動安裝時，新版 DMG 會存到「下載項目」。"))
                Toggle(L10n.text("自動安裝更新"), isOn: $settings.automaticallyInstallsUpdates)
                    .disabled(!settings.checksForUpdates || !settings.automaticallyDownloadsUpdates)
                    .help(L10n.text("下載並驗證更新後，等你退出 Notch Finder 再安裝。"))
                if settings.updateReadyToInstall {
                    Text(L10n.text("更新已就緒，退出 Notch Finder 後安裝。"))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(L10n.text("結束 Notch Finder")) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        AppearanceSettingsView(settings: settings, restoreSize: restoreSize, saveSize: saveSize)
    }

    private var browsing: some View {
        Form {
            Section(L10n.text("啟動位置")) {
                Picker(L10n.text("重新啟動後的位置"), selection: $settings.startupFolder) {
                    ForEach(StartupFolder.allCases, id: \.self) { folder in Text(folder.title).tag(folder) }
                }
                if settings.startupFolder == .custom {
                    LabeledContent(L10n.text("指定資料夾")) {
                        HStack {
                            Text(settings.customFolder.isEmpty ? L10n.text("尚未選取") : settings.customFolder)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(settings.customFolder)
                            Button(L10n.text("選擇…"), action: chooseFolder)
                        }
                    }
                }
            }
            Section(L10n.text("權限")) {
                LabeledContent(L10n.text("完全取用磁碟")) {
                    Button(L10n.text("打開系統設定…"), action: FileAccess.openSystemSettings)
                }
            }
            Section(L10n.text("列表")) {
                Picker(L10n.text("預設檔案顯示方式"), selection: $settings.defaultDisplayMode) {
                    ForEach(FileDisplayMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Picker(L10n.text("預設排序"), selection: $settings.fileSort) {
                    ForEach(FileSort.allCases, id: \.self) { sort in Text(sort.title).tag(sort) }
                }
                Toggle(L10n.text("資料夾排在前面"), isOn: $settings.foldersFirst)
                Toggle(L10n.text("下載項目和垃圾桶依加入日期分組"), isOn: $settings.groupsByAddedDate)
                Toggle(L10n.text("顯示隱藏項目"), isOn: Binding(
                    get: { tabs.active.browser.showsHidden },
                    set: { tabs.active.browser.setShowsHidden($0) }
                ))
            }
            Section(L10n.text("安裝")) {
                Toggle(L10n.text("安裝後退出磁碟並將 .dmg 移到垃圾桶"), isOn: $settings.cleansDiskImageAfterInstall)
                Text(L10n.text("適用於透過 Notch Finder 從 .dmg 安裝應用程式。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var clipboard: some View {
        Form {
            Section(L10n.text("剪貼簿歷史")) {
                Toggle(L10n.text("記錄歷史"), isOn: Binding(get: { clipboardHistory.isRecording }, set: clipboardHistory.setRecording))
                Picker(L10n.text("保留期限"), selection: $clipboardHistory.retention) {
                    ForEach(ClipboardRetention.allCases, id: \.self) { period in
                        Text(period.title).tag(period)
                    }
                }
                Text(L10n.text("歷史只儲存在這台 Mac，從該項目上次複製時起算。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.text("清除記錄"), role: .destructive) {
                    clipboardHistory.clear()
                }
                .disabled(clipboardHistory.entries.isEmpty)
            }
            if clipboardHistory.storageFailed {
                Label(L10n.text("無法存取本機剪貼簿歷史"), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var keyBindings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("點擊右側的快捷鍵，再按下新的組合。按 Esc 取消錄製。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = shortcuts.error {
                Text(error).font(.callout).foregroundStyle(.red)
            } else if !shortcuts.globalAvailable {
                Text(L10n.text("全域快捷鍵尚未註冊，請選擇另一組按鍵。"))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            List(PanelCommand.allCases, id: \.self) { command in
                LabeledContent(command.title) {
                    Button(shortcuts.recording == command ? L10n.text("按下快捷鍵…") : shortcuts[command].display) {
                        if shortcuts.recording == command { shortcuts.cancelRecording() }
                        else { shortcuts.startRecording(command) }
                    }
                    .buttonStyle(.bordered)
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityLabel(L10n.text("修改%@的快捷鍵", String(describing: command.title)))
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)

            Button(L10n.text("恢復預設快捷鍵"), action: shortcuts.reset)
        }
        .padding(18)
        .onDisappear(perform: shortcuts.cancelRecording)
    }

    private func delay(_ title: String, value: Binding<Double>) -> some View {
        let snappedValue = Binding(
            get: { value.wrappedValue },
            set: {
                let rounded = ($0 * 100).rounded() / 100
                if value.wrappedValue != rounded { value.wrappedValue = rounded }
            }
        )
        return LabeledContent(title) {
            HStack(spacing: 9) {
                NativeSlider(title: title, value: snappedValue, bounds: 0...1)
                    .frame(width: 196)
                Text(L10n.text("%@ 毫秒", String(describing: Int((value.wrappedValue * 1000).rounded()))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L10n.text("選擇")
        if !settings.customFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.customFolder, isDirectory: true)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { result in
                if result == .OK, let url = panel.url { settings.customFolder = url.path }
            }
        }
    }
}

private struct LoginItemSetting: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle(L10n.text("登入時啟動"), isOn: Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: setEnabled
        ))
        .onAppear { status = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }

        if status == .requiresApproval {
            LabeledContent(L10n.text("等待 macOS 核准")) {
                Button(L10n.text("開啟登入項目")) { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error { Text(error).font(.callout).foregroundStyle(.red) }
    }

    private func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
