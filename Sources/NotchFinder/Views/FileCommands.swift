import SwiftUI

struct FileCommands: View {
    let browser: FileBrowser
    let items: Set<URL>
    let cleanupInstaller: Bool

    var body: some View {
        if !items.isEmpty {
            Button(L10n.text("開啟")) { browser.openItems(items) }
            if items.count == 1, let item = items.first, DiskImageInstall.canInstall(item) {
                Button(L10n.text("安裝到「應用程式」")) { browser.installApplication(item, cleanupInstaller: cleanupInstaller) }
                    .disabled(browser.isUpdatingFiles)
            }
            Button(L10n.text("快速查看")) { browser.showPreview(items) }
            Button(L10n.text("在 Finder 中顯示")) { browser.revealInFinder(items) }
            Divider()
            Button(L10n.text("複製")) { browser.copyItems(items) }
            Button(L10n.text("複製路徑")) { browser.copyPaths(items) }
            if items.count == 1, let item = items.first {
                Button(L10n.text("重新命名")) { browser.beginEditing(.rename(item)) }
                    .disabled(browser.isUpdatingFiles)
            }
        }

        Button(L10n.text("貼上項目")) { browser.pasteItems(cleanupInstaller: cleanupInstaller) }
            .disabled(browser.isUpdatingFiles || browser.showsRecentItems)
        Button(L10n.text("新增資料夾")) { browser.beginEditing(.createFolder) }
            .disabled(browser.isUpdatingFiles || browser.showsRecentItems)
        Button(L10n.text("前往資料夾…")) { browser.beginEditing(.goToFolder) }
            .disabled(browser.isUpdatingFiles)
        Toggle(L10n.text("顯示隱藏項目"), isOn: Binding(get: { browser.showsHidden }, set: browser.setShowsHidden))

        if !items.isEmpty {
            Divider()
            Button(L10n.text("移到垃圾桶"), role: .destructive) { browser.trashItems(items) }
                .disabled(browser.isUpdatingFiles)
        }
    }
}

struct FileNameEditor: View {
    @Bindable var browser: FileBrowser
    let request: BrowserEdit
    let textSize: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Text(request.title)
                .font(.system(size: textSize, weight: .semibold))
            TextField(request == .goToFolder ? L10n.text("資料夾路徑") : L10n.text("名稱"), text: $browser.editText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(browser.commitEditing)
            Button(L10n.text("取消"), role: .cancel, action: browser.cancelEditing)
            Button(L10n.text("確定"), action: browser.commitEditing)
                .buttonStyle(.borderedProminent)
        }
        .font(.system(size: textSize))
        .controlSize(.small)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.primary.opacity(0.045))
        .onAppear { focused = true }
    }
}
