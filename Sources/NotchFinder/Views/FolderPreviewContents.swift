import SwiftUI

struct FolderPreviewContents: View {
    let folder: URL
    let includeHidden: Bool
    let interfaceSize: FileDisplaySize
    @State private var entries: [FileEntry]?
    @State private var readError: String?

    var body: some View {
        Group {
            if let readError {
                ContentUnavailableView(L10n.text("無法預覽資料夾"), systemImage: "exclamationmark.circle",
                                       description: Text(readError))
            } else if let entries {
                if entries.isEmpty {
                    ContentUnavailableView(L10n.text("沒有項目"), systemImage: "folder")
                } else {
                    table(entries)
                }
            } else {
                ProgressView(L10n.text("載入中…"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            do {
                let result = try await FileBrowser.readContents(of: folder, includeHidden: includeHidden)
                try Task.checkCancellation()
                entries = result
            } catch {
                if !Task.isCancelled { readError = error.localizedDescription }
            }
        }
    }

    private func table(_ entries: [FileEntry]) -> some View {
        VStack(spacing: 0) {
            Table(entries) {
                TableColumn(L10n.text("名稱")) { entry in
                    HStack(spacing: 8) {
                        BrowserFileIcon(entry: entry, side: interfaceSize.row.icon, loadsFileIcon: true)
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.name)
                    }
                    .frame(minHeight: interfaceSize.row.height)
                }
                TableColumn(L10n.text("種類"), value: \.kind)
                    .width(min: 70, ideal: 105)
            }
            .font(.system(size: interfaceSize.panelText))
            .tableStyle(.inset)
            Divider()
            Text(L10n.text("%@ 個項目", String(describing: entries.count.formatted())))
                .font(.system(size: interfaceSize.panelText - 1))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }
}
