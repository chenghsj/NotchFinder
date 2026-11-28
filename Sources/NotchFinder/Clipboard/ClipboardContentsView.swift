import ImageIO
import SwiftUI

struct ClipboardContentsView: View {
    private enum Filter: CaseIterable {
        case all, text, images, files

        var title: String {
            switch self {
            case .all: L10n.text("所有類型")
            case .text: L10n.text("文字")
            case .images: L10n.text("圖片")
            case .files: L10n.text("檔案")
            }
        }

        func includes(_ contents: ClipboardContents) -> Bool {
            switch (self, contents) {
            case (.all, _), (.text, .text), (.images, .image), (.files, .files): true
            default: false
            }
        }
    }

    let rows: [ClipboardHistory.Row]
    let history: ClipboardHistory
    let searchRequest: PanelSearchRequest?
    let interfaceSize: FileDisplaySize
    @Binding var listWidth: Double?
    let clipboardPaste: ClipboardPaste
    @State private var selectedID: ClipboardHistory.Row.ID?
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var showsSearch = true
    @FocusState private var searchFocused: Bool

    private var thumbnailSide: CGFloat { interfaceSize.row.icon + 4 }

    var body: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleRows = rows.filter { filter.includes($0.contents) && (search.isEmpty || $0.contents.matches(search)) }
        let selected = visibleRows.first { $0.id == selectedID } ?? visibleRows.first

        VStack(spacing: 0) {
            searchBar
            Divider()
            if history.isWaitingForAccess || history.storageFailed {
                HStack {
                    Label(history.storageFailed ? L10n.text("無法存取本機剪貼簿歷史") : L10n.text("允許剪貼簿存取後，即可自動更新內容。"),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if history.isWaitingForAccess {
                        Button(L10n.text("重新整理剪貼簿"), action: history.refreshPreview)
                            .buttonStyle(.bordered)
                    }
                }
                .font(.system(size: interfaceSize.panelText - 1))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            if let selected {
                ClipboardSplitView(listWidth: $listWidth, textSize: interfaceSize.panelText) {
                    historyList(visibleRows, selected: selected)
                } preview: { paneWidth in
                    VStack(spacing: 0) {
                        previewActions(for: selected)
                        Divider()
                        ClipboardItemPreview(row: selected, textSize: interfaceSize.panelText, paneWidth: paneWidth)
                            .id(selected.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ContentUnavailableView(rows.isEmpty ? L10n.text("剪貼簿沒有內容") : L10n.text("找不到符合的項目"),
                                       systemImage: rows.isEmpty ? "clipboard" : "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer(count: visibleRows.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.system(size: interfaceSize.panelText))
        .onChange(of: searchRequest) { _, request in
            guard let request else { return }
            if request.action == .toggle && showsSearch {
                searchFocused = false
                query = ""
                showsSearch = false
            } else {
                focusSearch()
            }
        }
        .onChange(of: selected?.id) { _, id in clipboardPaste.clearFeedback(except: id) }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            if showsSearch {
                searchField
            } else {
                Spacer(minLength: 0)
                Button(L10n.text("搜尋剪貼簿"), systemImage: "magnifyingglass", action: focusSearch)
                    .labelStyle(.iconOnly)
            }
            Picker(L10n.text("類型"), selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.text("搜尋剪貼簿"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button(L10n.text("清除搜尋"), systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: .rect(cornerRadius: 7))
    }

    private func focusSearch() {
        showsSearch = true
        searchFocused = true
    }

    private func historyList(_ visibleRows: [ClipboardHistory.Row], selected: ClipboardHistory.Row) -> some View {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visibleRows) { calendar.startOfDay(for: $0.copiedAt) }
        return List(selection: Binding(get: { selected.id as ClipboardHistory.Row.ID? }, set: { selectedID = $0 })) {
            ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(groups[day, default: []]) { row in
                        HStack(spacing: 8) {
                            thumbnail(row.contents)
                                .frame(width: thumbnailSide, height: thumbnailSide)
                                .accessibilityHidden(true)
                            Text(row.contents.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(minHeight: max(interfaceSize.row.height, thumbnailSide + 4))
                        .tag(row.id)
                    }
                } header: {
                    if calendar.isDateInToday(day) { Text(L10n.text("今天")) }
                    else if calendar.isDateInYesterday(day) { Text(L10n.text("昨天")) }
                    else { Text(day, format: .dateTime.year().month().day()) }
                }
            }
        }
        .contextMenu(forSelectionType: ClipboardHistory.Row.ID.self) { ids in
            if let row = visibleRows.first(where: { ids.contains($0.id) }) {
                if let destination = clipboardPaste.destination(for: row) {
                    Button(L10n.text("貼上")) { use(row) }
                        .disabled(!destination.isAvailable)
                }
                Button(L10n.text("複製")) { clipboardPaste.copy(row) }
            }
        } primaryAction: { ids in
            if let row = visibleRows.first(where: { ids.contains($0.id) }) {
                use(row)
            }
        }
        .onKeyPress(.return) {
            guard clipboardPaste.destination(for: selected)?.isAvailable == true else { return .ignored }
            use(selected)
            return .handled
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.primary.opacity(0.035))
        .accessibilityLabel(L10n.text("剪貼簿項目"))
    }

    @ViewBuilder
    private func thumbnail(_ contents: ClipboardContents) -> some View {
        if case .image(_, let data) = contents,
           let image = ClipboardImage.thumbnail(data, maxPixels: Int(thumbnailSide * 2)) {
            Image(decorative: image, scale: 2)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 4))
        } else {
            Image(systemName: contents.symbol)
                .font(.system(size: interfaceSize.row.icon))
                .foregroundStyle(.secondary)
        }
    }

    private func use(_ row: ClipboardHistory.Row) {
        selectedID = row.id
        Task { await clipboardPaste.paste(row, copyIfNoDestination: true) }
    }

    private func previewActions(for row: ClipboardHistory.Row) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 8) {
                Button(L10n.text("複製"), systemImage: "doc.on.doc") { clipboardPaste.copy(row) }
                    .fixedSize()

                if let destination = clipboardPaste.destination(for: row) {
                    let title = switch destination {
                    case .folder: L10n.text("貼到資料夾")
                    case .application(let name): L10n.text("貼到 %@", name)
                    }
                    Button {
                        use(row)
                    } label: {
                        Text(title).lineLimit(1).truncationMode(.tail)
                    }
                    .disabled(!destination.isAvailable)
                    .help(title)
                }
            }
            .buttonStyle(.bordered)

            if let feedback = clipboardPaste.feedback(for: row.id)?.message {
                Text(feedback)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(feedback)
            }
        }
        .font(.system(size: interfaceSize.panelText - 1))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 9) {
            Text(L10n.text("%@ 個項目", String(describing: count)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .modifier(PanelFooterStyle(textSize: interfaceSize.panelText - 1))
    }
}

private struct ClipboardSplitView<ListContent: View, Preview: View>: View {
    @Binding var listWidth: Double?
    let textSize: CGFloat
    @ViewBuilder let list: ListContent
    @ViewBuilder let preview: (CGFloat) -> Preview
    @GestureState private var dragOffset = 0.0
    private let dividerWidth: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, Double(geometry.size.width - dividerWidth))
            let minimum = min(122, available / 2)
            let previewMinimum = max(180, Double(textSize) * 10)
            let limits = minimum...max(minimum, available - previewMinimum)
            let defaultWidth = min(280, max(122, available * 0.36))
            let baseWidth = clampedListWidth(listWidth ?? defaultWidth, to: limits)
            let width = clampedListWidth(baseWidth + dragOffset, to: limits)
            let paneWidth = available - width

            HStack(spacing: 0) {
                list.frame(width: width)
                divider(width: width, baseWidth: baseWidth, limits: limits)
                preview(paneWidth).frame(width: paneWidth)
            }
        }
    }

    private func divider(width: Double, baseWidth: Double, limits: ClosedRange<Double>) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: dividerWidth)
            .contentShape(.rect)
            .columnResizePointer()
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($dragOffset) { drag, offset, _ in offset = Double(drag.translation.width) }
                    .onEnded { drag in
                        let adjusted = clampedListWidth(baseWidth + Double(drag.translation.width), to: limits)
                        if adjusted != baseWidth { listWidth = adjusted }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("剪貼簿清單寬度"))
            .accessibilityValue(L10n.text("%@ 點", String(describing: Int(width.rounded()))))
            .accessibilityAdjustableAction { direction in
                let adjusted: Double
                switch direction {
                case .increment: adjusted = clampedListWidth(width + 10, to: limits)
                case .decrement: adjusted = clampedListWidth(width - 10, to: limits)
                @unknown default: return
                }
                if adjusted != width { listWidth = adjusted }
            }
    }

    private func clampedListWidth(_ width: Double, to limits: ClosedRange<Double>) -> Double {
        min(limits.upperBound, max(limits.lowerBound, width))
    }
}

private struct ClipboardItemPreview: View {
    let row: ClipboardHistory.Row
    let textSize: CGFloat
    let paneWidth: CGFloat
    private let contentPadding: CGFloat = 12

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                preview
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.text("項目資訊"))
                        .font(.system(size: textSize - 1, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 5)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                        switch row.contents {
                        case .text:
                            info(L10n.text("種類"), L10n.text("文字"))
                            info(L10n.text("大小"), size)
                        case .image(_, let data):
                            info(L10n.text("種類"), L10n.text("圖片"))
                            if let dimensions = ClipboardImage.dimensions(data) { info(L10n.text("尺寸"), dimensions) }
                            info(L10n.text("大小"), size)
                        case .files(let urls):
                            info(L10n.text("種類"), L10n.text("檔案"))
                            info(L10n.text("項目數量"), urls.count.formatted())
                        case .empty:
                            EmptyView()
                        }
                        info(L10n.text("複製時間"), row.copiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.system(size: textSize - 1))
                    .padding(8)
                    .background(.primary.opacity(0.045), in: .rect(cornerRadius: 7))
                }
            }
            .padding(contentPadding)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch row.contents {
        case .text(let text):
            Text(String(text.prefix(20_000)))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .files(let urls):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(urls.indices, id: \.self) { index in
                    let url = urls[index]
                    Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
            }
        case .image(_, let data):
            if let image = ClipboardImage.thumbnail(data, maxPixels: 1000) {
                // A legacy scrollbar narrows the image. Reserve its height using the full pane
                // so showing the scrollbar cannot shrink the document enough to hide it again.
                let width = max(0, paneWidth - 2 * contentPadding)
                let height = min(240, width * CGFloat(image.height) / CGFloat(image.width))
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel(L10n.text("剪貼簿圖片"))
            } else {
                Label(L10n.text("無法預覽此圖片"), systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        case .empty:
            EmptyView()
        }
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(row.contents.byteCount), countStyle: .file)
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private enum ClipboardImage {
    static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = source(data) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary)
    }

    static func dimensions(_ data: Data) -> String? {
        guard let source = source(data),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }

    private static func source(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
