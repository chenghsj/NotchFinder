import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserPanel: View {
    private static let breadcrumbFolderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let breadcrumbVolumeIcon = NSWorkspace.shared.icon(forFile: "/")

    let tabs: BrowserTabs
    @Bindable var settings: NotchSettings
    let quickLookSources: QuickLookSources
    var close: () -> Void
    var openSettings: () -> Void
    var clipboardPasteTarget: () -> String?
    var pasteClipboard: (ClipboardHistory.Row) -> ClipboardPasteResult
    var resizeHandle: PanelResizeHandle
    var onFileDragEnded: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsFilter = false
    @State private var sidebarDragStart: Double?
    @State private var draggedSidebarWidth: Double?
    @State private var sidebarDropIndex: Int?
    @FocusState private var filterFocused: Bool

    private let sidebarDividerWidth: CGFloat = 7
    private let sidebarToolbarSpacing: CGFloat = 4
    private let sidebarToolbarInset: CGFloat = 8
    private let sidebarRowSpacing: CGFloat = 2
    private var browser: FileBrowser { tabs.active.browser }
    private var clipboardHistory: ClipboardHistory { tabs.clipboardHistory }
    private var preset: PanelStylePreset { settings.appearance.preset(for: colorScheme) }
    private var panelIconSize: CGFloat { settings.interfaceSize.panelIcon }
    private var panelTextSize: CGFloat { settings.interfaceSize.panelText }
    private var toolbarScale: CGFloat { panelIconSize / NSFont.systemFontSize }
    private var toolbarHeight: CGFloat { 46 * toolbarScale }
    private var toolbarButtonSide: CGFloat { 28 * toolbarScale }
    private var toolbarGroupInset: CGFloat { 2 * toolbarScale }
    private var sidebarRowHeight: CGFloat { max(27, panelIconSize + 11, panelTextSize + 12) }
    private var sidebarMinimumWidth: Double {
        let controlsWidth = 3 * (toolbarButtonSide + sidebarToolbarSpacing) + 2 * sidebarToolbarInset
        return max(NotchSettings.sidebarWidths.lowerBound, Double(controlsWidth))
    }
    private var browserMinimumWidth: Double {
        // Leave room for the eight icon slots, their spacing, and a visible folder title.
        max(334, Double(8 * toolbarButtonSide + 4 * toolbarGroupInset + 76))
    }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = Double(geometry.size.width - sidebarDividerWidth)
            let maximum = min(NotchSettings.sidebarWidths.upperBound,
                              max(sidebarMinimumWidth, availableWidth - browserMinimumWidth))
            let width = min(max(draggedSidebarWidth ?? settings.sidebarWidth, sidebarMinimumWidth), maximum)
            HStack(spacing: 0) {
                sidebar.frame(width: width)
                sidebarDivider(width: width, maximum: maximum)
                browserPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .strokeBorder(.primary.opacity(0.13), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            resizeHandle.at(.left).frame(width: 6).padding(.vertical, 16)
        }
        .overlay(alignment: .trailing) {
            resizeHandle.at(.right).frame(width: 6).padding(.vertical, 16)
        }
        .overlay(alignment: .bottomLeading) {
            resizeHandle.at(.bottomLeft).frame(width: 12, height: 16)
        }
        .overlay(alignment: .bottomTrailing) {
            resizeHandle.at(.bottomRight).frame(width: 12, height: 16)
        }
        .environment(\.quickLookSources, quickLookSources)
        .environment(\.panelStyle, preset)
        .accentColor(settings.appearance.accentColor(for: colorScheme))
        .tint(settings.appearance.accentColor(for: colorScheme))
        .fontDesign(settings.appearance.fontStyle.design)
        .onChange(of: browser.destination) { _, _ in restoreFilterState() }
        .onChange(of: tabs.active.id) { _, _ in restoreFilterState() }
        .onChange(of: settings.filterFocusRequest) { _, _ in
            if !tabs.showsClipboard { showFilter() }
        }
        .onChange(of: settings.showsClipboardInSidebar) { _, visible in
            if !visible { tabs.closeClipboard() }
        }
    }

    private var browserPane: some View {
        let clipboard = tabs.showsClipboard ? clipboardHistory.timeline : nil
        return VStack(spacing: 0) {
            if let clipboard {
                clipboardToolbar(current: clipboard.current)
            } else {
                toolbar
            }
            Divider()
            if tabs.items.count > 1 {
                tabBar
                Divider()
            }
            if let clipboard {
                ClipboardContentsView(rows: clipboard.rows, history: clipboardHistory,
                                      focusSearchRequest: settings.filterFocusRequest,
                                      pasteTargetName: clipboardPasteTarget(),
                                      canPasteFiles: !browser.showsRecentItems,
                                      interfaceSize: settings.interfaceSize,
                                      paste: pasteClipboard) {
                    footerTools(L10n.text("重新整理剪貼簿")) { clipboardHistory.refreshPreview() }
                }
                .background(preset.contentColor)
            } else {
                folderContents
            }
        }
        .background(preset.windowColor)
    }

    @ViewBuilder
    private var folderContents: some View {
        let listing = FileListing(browser: browser, settings: settings)
        if let request = browser.editing {
            FileNameEditor(browser: browser, request: request, textSize: panelTextSize)
                .id(request.title)
            Divider()
        }
        FileList(browser: browser, settings: settings, listing: listing,
                 releaseSearchFocus: { filterFocused = false }, onFileDragEnded: onFileDragEnded)
            .id(tabs.active.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(preset.contentColor)
        Divider()
        pathBar
        footer(for: listing)
    }

    private func clipboardToolbar(current: ClipboardSnapshot?) -> some View {
        glassToolbar {
            HStack(spacing: 9) {
                toolbarButton(L10n.text("返回目前的資料夾"), symbol: "chevron.backward", action: tabs.closeClipboard)
                Text(L10n.text("剪貼簿"))
                    .font(settings.panelFont(size: panelTextSize + 2, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let current, current.contents.hasFiles, !browser.showsRecentItems {
                    Button(L10n.text("貼到目前資料夾")) {
                        _ = pasteClipboard(.current(current))
                    }
                    .disabled(browser.isUpdatingFiles)
                    .help(browser.title)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: toolbarHeight)
        }
    }

    private func sidebarDivider(width: Double, maximum: Double) -> some View {
        let lowerBound = sidebarMinimumWidth
        let divider = Rectangle()
            .fill(preset.windowColor)
            .frame(width: sidebarDividerWidth)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(.rect)
        return sidebarResizePointer(divider)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = sidebarDragStart ?? width
                        sidebarDragStart = start
                        draggedSidebarWidth = min(maximum, max(lowerBound, start + Double(drag.translation.width)))
                    }
                    .onEnded { _ in
                        if let draggedSidebarWidth { settings.sidebarWidth = draggedSidebarWidth }
                        draggedSidebarWidth = nil
                        sidebarDragStart = nil
                    }
            )
            .accessibilityLabel(L10n.text("側邊欄寬度"))
            .accessibilityValue(L10n.text("%@ 點", String(describing: Int(width.rounded()))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: settings.sidebarWidth = min(maximum, width + 10)
                case .decrement: settings.sidebarWidth = max(lowerBound, width - 10)
                @unknown default: break
                }
            }
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

    private var toolbar: some View {
        GeometryReader { geometry in
            glassToolbar { toolbarContent(width: geometry.size.width) }
                .animation(filterAnimation, value: showsFilter)
        }
        .frame(height: toolbarHeight)
    }

    @ViewBuilder
    private func glassToolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) { content() }
        } else {
            content()
        }
    }

    private func toolbarContent(width: CGFloat) -> some View {
        let spacing: CGFloat = 9
        let trailingSpacing: CGFloat = 5
        let inset: CGFloat = 12
        let titleWidth: CGFloat = 112
        let minimumSearchWidth: CGFloat = 112
        let showsNewTab = tabs.items.count == 1
        let leadingControls = 3 * toolbarButtonSide + 2 * toolbarGroupInset + 1
        let newTabWidth = showsNewTab ? toolbarButtonSide + trailingSpacing : 0
        let reservedWidth = leadingControls + newTabWidth + 3 * spacing + 2 * inset + titleWidth
        let viewModesWidth = CGFloat(FileDisplayMode.allCases.count) * toolbarButtonSide + 2 * toolbarGroupInset + spacing
        let toolbarWidth = showsFilter
            ? reservedWidth + viewModesWidth + minimumSearchWidth
            : reservedWidth - titleWidth + viewModesWidth + toolbarButtonSide + 32
        let showsViewModes = width >= toolbarWidth
        let availableSearchWidth = width - reservedWidth - (showsViewModes ? viewModesWidth : 0)
        let searchWidth = min(224 * toolbarScale, max(minimumSearchWidth, availableSearchWidth))
        return HStack(spacing: spacing) {
            historyButtons

            Text(browser.title)
                .font(settings.panelFont(size: panelTextSize + 2, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
                .help(browser.title)
                .frame(maxWidth: .infinity, alignment: .leading)

            fileActions(includesDisplayModes: !showsViewModes)
            if showsViewModes { displayModeButtons }

            HStack(spacing: trailingSpacing) {
                if showsNewTab {
                    toolbarButton(L10n.text("新增分頁"), symbol: "plus", action: tabs.add)
                }
                searchControl(expandedWidth: searchWidth)
            }
        }
        .padding(.horizontal, inset)
        .frame(height: toolbarHeight)
    }

    private var filterAnimation: Animation? {
        guard !reduceMotion, settings.animation != .off else { return nil }
        return .easeInOut(duration: 0.20 / settings.animation.rate)
    }

    private func searchControl(expandedWidth: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            if showsFilter {
                filterBar.id(tabs.active.id).transition(.opacity)
            } else {
                toolbarButton(L10n.text("篩選此資料夾"), symbol: "magnifyingglass", action: showFilter)
                    .transition(.opacity)
            }
        }
        .frame(width: showsFilter ? expandedWidth : toolbarButtonSide, height: toolbarButtonSide)
    }

    private var historyButtons: some View {
        toolbarGroup {
            HStack(spacing: 0) {
                groupedToolbarButton(L10n.text("上一個資料夾"), symbol: "chevron.backward", action: browser.goBack)
                    .disabled(!browser.canGoBack)
                Divider().frame(height: 13 * toolbarScale).accessibilityHidden(true)
                groupedToolbarButton(L10n.text("下一個資料夾"), symbol: "chevron.forward", action: tabs.goForward)
                    .disabled(!browser.canGoForward)
            }
        }
    }

    private var displayModeButtons: some View {
        toolbarGroup {
            HStack(spacing: 0) {
                ForEach(FileDisplayMode.allCases, id: \.self) { mode in
                    groupedToolbarButton(mode.title, symbol: mode.symbol, selected: mode == settings.displayMode) {
                        settings.displayMode = mode
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("檔案顯示方式"))
    }

    @ViewBuilder
    private func toolbarGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let group = content().padding(.horizontal, toolbarGroupInset).fixedSize()
        if #available(macOS 26, *) {
            group.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            group
                .background(.primary.opacity(0.045), in: Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.09)).allowsHitTesting(false) }
        }
    }

    private func groupedToolbarButton(_ title: String, symbol: String, selected: Bool = false,
                                      action: @escaping () -> Void) -> some View {
        let isDark = colorScheme == .dark
        let selectedGlyph = isDark ? Color.white : Color.black
        return Button(action: action) {
            toolbarSymbol(symbol)
                .foregroundStyle(selected ? selectedGlyph : .primary)
                .frame(width: toolbarButtonSide, height: toolbarButtonSide)
                .background {
                    if selected {
                        Circle()
                            .fill(Color(white: isDark ? 0.35 : 0.86))
                            .overlay { Circle().strokeBorder(selectedGlyph.opacity(0.12)) }
                            .padding(toolbarGroupInset)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    private var tabBar: some View {
        glassToolbar {
            HStack(spacing: 5) {
                BrowserTabStrip(tabs: tabs, height: toolbarButtonSide, iconSize: panelIconSize, textSize: panelTextSize)
                toolbarButton(L10n.text("新增分頁"), symbol: "plus", action: tabs.add)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4 * toolbarScale)
        }
    }

    private func fileActions(includesDisplayModes: Bool) -> some View {
        let menu = Menu {
            if includesDisplayModes {
                Picker(L10n.text("檔案顯示方式"), selection: $settings.displayMode) {
                    ForEach(FileDisplayMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Divider()
            }
            if browser.canPinFolder {
                Button(browser.isPinned ? L10n.text("從側欄移除") : L10n.text("加入側欄"), action: browser.toggleFavorite)
                Divider()
            }
            FileCommands(browser: browser, items: browser.selection, cleanupInstaller: settings.cleansDiskImageAfterInstall)
        } label: {
            Color.clear
                .frame(width: toolbarButtonSide, height: toolbarButtonSide)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: toolbarButtonSide, height: toolbarButtonSide)
        .overlay {
            toolbarSymbol("ellipsis")
                .foregroundStyle(Color.primary)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(L10n.text("檔案操作"))
        .help(L10n.text("檔案操作"))

        return glassCircle(menu)
    }

    private var filterBar: some View {
        @Bindable var browser = self.browser
        let isEmpty = browser.filter.isEmpty
        let field = HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: panelIconSize))
                .foregroundStyle(.secondary)
            TextField(L10n.text("搜尋"), text: $browser.filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .accessibilityLabel(L10n.text("篩選此資料夾"))
                .task {
                    // Wait for the new field to enter the window's key-view loop.
                    await Task.yield()
                    if showsFilter && !Task.isCancelled { filterFocused = true }
                }
            Button(L10n.text(isEmpty ? "完成" : "清除篩選"), systemImage: "xmark.circle.fill") {
                if isEmpty { hideFilter() }
                else {
                    browser.filter = ""
                    filterFocused = true
                }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: panelIconSize))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(settings.panelFont(size: panelTextSize))
        .padding(.horizontal, 8 * toolbarScale)
        .frame(height: toolbarButtonSide)
        return searchFieldSurface(field)
            .overlay {
                Capsule()
                    .strokeBorder(filterFocused ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func searchFieldSurface<Content: View>(_ field: Content) -> some View {
        if #available(macOS 26, *) {
            field.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            field.background(.quaternary, in: Capsule())
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            glassToolbar {
                HStack(spacing: sidebarToolbarSpacing) {
                    toolbarButton(L10n.text("收合"), symbol: "xmark", action: close)
                    Spacer(minLength: 0)
                    toolbarButton(settings.panelPinned ? L10n.text("解除固定面板") : L10n.text("固定面板"),
                                  symbol: settings.panelPinned ? "pin.fill" : "pin", selected: settings.panelPinned) {
                        settings.panelPinned.toggle()
                    }
                    toolbarButton(L10n.text("設定…"), symbol: "gearshape", action: openSettings)
                }
                .padding(.horizontal, sidebarToolbarInset)
                .frame(height: toolbarHeight)
            }

            sidebarLocations

            if settings.showsClipboardInSidebar {
                let selected = tabs.showsClipboard
                Button {
                    filterFocused = false
                    tabs.showClipboard()
                } label: {
                    sidebarLabel(L10n.text("剪貼簿"), symbol: "clipboard", selected: selected)
                }
                .buttonStyle(PanelButtonStyle(selected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }

            Menu {
                ForEach(PanelTheme.allCases, id: \.self) { option in
                    Button {
                        settings.selectColorMode(option)
                    } label: {
                        if settings.appearance.colorMode == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Label {
                    Text(settings.appearance.colorMode.label)
                        .font(settings.panelFont(size: panelTextSize))
                } icon: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: panelIconSize))
                }
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L10n.text("外觀"))
            .accessibilityValue(settings.appearance.colorMode.label)
            .help(L10n.text("切換面板外觀"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .frame(height: PanelFooterStyle.rowHeight)
            .padding(.bottom, PanelFooterStyle.bottomPadding)
        }
        .background(preset.windowColor.opacity(colorScheme == .dark ? 0.74 : 0.83))
    }

    private var sidebarLocations: some View {
        let locations = browser.sidebar
        let favorites = locations.visibleFavorites
        let places = locations.visibleLocations
        let tags = locations.visibleTags
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if locations.showsRecents {
                    let selected = browser.showsRecentItems && !tabs.showsClipboard
                    Button(action: tabs.showRecentItems) {
                        sidebarLabel(L10n.text("最近項目"), symbol: "clock", selected: selected)
                    }
                    .buttonStyle(PanelButtonStyle(selected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }

                VStack(alignment: .leading, spacing: 3) {
                    sidebarHeading(L10n.text("喜好項目"))
                    VStack(alignment: .leading, spacing: sidebarRowSpacing) {
                        if favorites.isEmpty {
                            Text(L10n.text("將資料夾拖到這裡"))
                                .font(settings.panelFont(size: panelTextSize))
                                .foregroundStyle(.secondary)
                                .padding(9)
                        }
                        ForEach(favorites) { location in
                            sidebarRow(location).onDrag { SidebarFolderDrop.provider(for: location.url) }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
                    .contentShape(.rect)
                    .overlay(alignment: .top) {
                        if let sidebarDropIndex {
                            Rectangle()
                                .fill(Color(nsColor: .secondaryLabelColor))
                                .frame(height: 1)
                                .offset(y: CGFloat(sidebarDropIndex) * (sidebarRowHeight + sidebarRowSpacing))
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                    }
                    .onDrop(of: SidebarFolderDrop.types, delegate: SidebarFolderDrop(
                        sidebar: locations, visibleItems: favorites,
                        rowHeight: sidebarRowHeight, rowSpacing: sidebarRowSpacing, insertionIndex: $sidebarDropIndex
                    ))
                }

                if !places.isEmpty {
                    VStack(alignment: .leading, spacing: sidebarRowSpacing) {
                        sidebarHeading(L10n.text("位置"))
                        ForEach(places, content: sidebarRow)
                    }
                }

                if !tags.isEmpty {
                    VStack(alignment: .leading, spacing: sidebarRowSpacing) {
                        sidebarHeading(L10n.text("標籤"))
                        ForEach(tags, id: \.self) { tag in
                            sidebarShortcut(tag, symbol: "tag") {
                                let query = NSPredicate(format: "%K == %@", "kMDItemUserTags", tag)
                                return NSWorkspace.shared.showSearchResults(forQueryString: query.predicateFormat)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(maxHeight: .infinity)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(settings.panelFont(size: panelTextSize - 1, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 9)
            .accessibilityAddTraits(.isHeader)
    }

    private func sidebarShortcut(_ title: String, symbol: String, action: @escaping () -> Bool) -> some View {
        Button { _ = action() } label: {
            sidebarLabel(title, symbol: symbol, selected: false)
        }
        .buttonStyle(PanelButtonStyle())
    }

    private func sidebarRow(_ location: BrowserLocation) -> some View {
        let selected = !tabs.showsClipboard && !browser.showsRecentItems
            && location.url == browser.directory
        return Button {
            tabs.navigate(to: location.url)
        } label: {
            sidebarLabel(location.name, selected: selected) {
                SidebarLocationIcon(location: location, size: panelIconSize)
            }
        }
        .buttonStyle(PanelButtonStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if browser.sidebar.canRemove(location) {
                Button(L10n.text("從側邊欄移除"), systemImage: "minus.circle") { browser.sidebar.remove(location) }
            }
        }
    }

    private func sidebarLabel(_ title: String, symbol: String, selected: Bool) -> some View {
        sidebarLabel(title, selected: selected) {
            Image(systemName: symbol).font(.system(size: panelIconSize))
        }
    }

    private func sidebarLabel<Icon: View>(_ title: String, selected: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            icon()
                .foregroundStyle(Color.accentColor)
                .frame(width: max(16, panelIconSize + 2))
            Text(title)
                .font(settings.panelFont(size: panelTextSize, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: sidebarRowHeight)
        .padding(.horizontal, 9)
    }

    private var pathBar: some View {
        HStack(spacing: 7) {
            Group {
                if browser.showsRecentItems {
                    Label(L10n.text("最近項目"), systemImage: "clock")
                        .font(settings.panelFont(size: panelTextSize - 1))
                        .foregroundStyle(.secondary)
                } else {
                    breadcrumbTrail(browser.breadcrumbs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.text("上一層"), systemImage: "arrow.up", action: tabs.goUp)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: panelIconSize - 2, weight: .medium))
                .foregroundStyle(.secondary)
                .help(L10n.text("上一層"))
                .disabled(!browser.canGoUp)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private func breadcrumbTrail(_ breadcrumbs: [URL]) -> some View {
        let parents = breadcrumbs.dropLast()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                ForEach(parents, id: \.self) { folder in
                    Button {
                        tabs.navigate(to: folder)
                    } label: {
                        breadcrumb(for: folder)
                    }
                    .buttonStyle(.plain)
                    .help(folder.path)
                    breadcrumbSeparator
                }
                currentBreadcrumb
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 5) {
                if !parents.isEmpty {
                    Menu {
                        ForEach(parents.reversed(), id: \.self) { folder in
                            Button(browser.name(for: folder)) { tabs.navigate(to: folder) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: panelIconSize - 2))
                            .frame(width: 17, height: 17)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(L10n.text("上層資料夾"))
                    .help(L10n.text("上層資料夾"))
                    breadcrumbSeparator
                }
                currentBreadcrumb
            }
        }
        .font(settings.panelFont(size: panelTextSize - 1))
        .foregroundStyle(.secondary)
        .frame(height: 19)
    }

    private var currentBreadcrumb: some View {
        breadcrumb(for: browser.directory)
            .help(browser.directory.path)
    }

    private func breadcrumb(for folder: URL) -> some View {
        Label {
            Text(browser.name(for: folder))
        } icon: {
            Image(nsImage: folder.path == "/" ? Self.breadcrumbVolumeIcon : Self.breadcrumbFolderIcon)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: panelIconSize, height: panelIconSize)
                .accessibilityHidden(true)
        }
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: panelIconSize - 6))
            .accessibilityHidden(true)
    }

    private func footer(for listing: FileListing) -> some View {
        HStack(spacing: 9) {
            Text(statusText(for: listing))
                .foregroundStyle(.secondary)
            if let error = browser.openError {
                Text(error)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            }
            Spacer(minLength: 0)

            footerTools(L10n.text("重新載入"), reload: browser.reload)
        }
        .modifier(PanelFooterStyle(textSize: panelTextSize - 1))
    }

    @ViewBuilder
    private func footerTools(_ reloadTitle: String, reload: @escaping () -> Void) -> some View {
        interfaceSizeSlider
        iconButton(reloadTitle, symbol: "arrow.clockwise", action: reload)
    }

    private var interfaceSizeSlider: some View {
        let bounds = 0...Double(FileDisplaySize.allCases.count - 1)
        let value = Binding(
            get: { interfaceSizeIndex },
            set: { setInterfaceSize(at: $0) }
        )
        return HStack(spacing: 6) {
            Button(L10n.text("最小介面"), systemImage: "rectangle.on.rectangle") { setInterfaceSize(at: bounds.lowerBound) }
                .font(.system(size: panelIconSize - 3))
                .foregroundStyle(.secondary)
            NativeSlider(title: L10n.text("介面大小"), value: value, bounds: bounds, step: 1)
            .accessibilityValue(settings.interfaceSize.title)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setInterfaceSize(at: interfaceSizeIndex + 1)
                case .decrement: setInterfaceSize(at: interfaceSizeIndex - 1)
                @unknown default: break
                }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                setInterfaceSize(at: interfaceSizeIndex + (press.key == .leftArrow ? -1 : 1))
                return .handled
            }
            Button(L10n.text("最大介面"), systemImage: "rectangle.on.rectangle.fill") { setInterfaceSize(at: bounds.upperBound) }
                .font(.system(size: panelIconSize))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .frame(width: 196)
        .help(L10n.text("介面大小：%@", String(describing: settings.interfaceSize.title)))
    }

    private var interfaceSizeIndex: Double {
        Double(FileDisplaySize.allCases.firstIndex(of: settings.interfaceSize) ?? 0)
    }

    private func setInterfaceSize(at position: Double) {
        let sizes = FileDisplaySize.allCases
        let index = min(sizes.count - 1, max(0, Int(position.rounded())))
        if settings.interfaceSize != sizes[index] { settings.interfaceSize = sizes[index] }
    }

    private func showFilter() {
        if showsFilter { filterFocused = true }
        else { showsFilter = true }
    }

    private func hideFilter() {
        filterFocused = false
        showsFilter = false
        browser.filter = ""
    }

    private func restoreFilterState() {
        filterFocused = false
        showsFilter = !browser.filter.isEmpty
    }

    private func statusText(for listing: FileListing) -> String {
        if browser.isUpdatingFiles { return L10n.text("正在處理檔案…") }
        if browser.isLoading { return L10n.text("正在讀取…") }
        let selectedCount = listing.selected(browser.selection).count
        return selectedCount > 0 ? L10n.text("已選取 %@ 個", String(describing: selectedCount)) : L10n.text("%@ 個項目", String(describing: listing.entries.count))
    }

    @ViewBuilder
    private func toolbarButton(_ title: String, symbol: String, selected: Bool = false,
                               action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            toolbarSymbol(symbol)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(width: toolbarButtonSide, height: toolbarButtonSide)
                .contentShape(.circle)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)

        if #available(macOS 26, *) {
            glassCircle(button.buttonStyle(.plain))
        } else {
            button.buttonStyle(PanelButtonStyle(selected: selected, cornerRadius: toolbarButtonSide / 2))
        }
    }

    @ViewBuilder
    private func glassCircle<Control: View>(_ control: Control) -> some View {
        if #available(macOS 26, *) {
            control.glassEffect(.regular.interactive(), in: .circle)
        } else {
            control
        }
    }

    private func toolbarSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .resizable()
            .scaledToFit()
            .frame(width: panelIconSize, height: panelIconSize)
            .font(.system(size: panelIconSize, weight: .medium))
    }

    private func iconButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolbarSymbol(symbol)
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .frame(width: 28, height: 27)
        }
        .buttonStyle(PanelButtonStyle(selected: selected, cornerRadius: 13))
        .accessibilityLabel(title)
        .help(title)
    }
}

struct PanelButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonLabel(configuration: configuration, selected: selected, cornerRadius: cornerRadius)
    }
}

private struct PanelButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.15) : .primary.opacity(isEnabled && isHovered ? 0.07 : 0))
            }
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.68 : 1)
            .contentShape(.rect)
            .onHover { isHovered = $0 }
    }
}
