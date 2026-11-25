import SwiftUI

struct BrowserTabStrip: View {
    let tabs: BrowserTabs
    let height: CGFloat
    let iconSize: CGFloat
    let textSize: CGFloat
    @State private var hoveredTab: UUID?

    private var inset: CGFloat { height / 14 }
    private var tabHeight: CGFloat { height - 2 * inset }
    private var closeSize: CGFloat { tabHeight * 0.8 }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width - 2 * inset
            let tabWidth = max(96, availableWidth / CGFloat(tabs.items.count))
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(tabs.items) { tab in
                            tabView(tab)
                                .frame(width: tabWidth, height: tabHeight)
                                .id(tab.id)
                        }
                    }
                    .padding(inset)
                }
                .scrollIndicators(.hidden)
                .onChange(of: tabs.active.id, initial: true) { _, id in
                    reader.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: height)
        .background(.primary.opacity(0.075), in: Capsule())
        .clipShape(.capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("分頁"))
    }

    private func tabView(_ tab: BrowserTabs.Tab) -> some View {
        let isActive = tab.id == tabs.active.id
        let isHovered = hoveredTab == tab.id
        return ZStack(alignment: .leading) {
            Button {
                tabs.select(tab.id)
            } label: {
                Text(tab.browser.title)
                    .font(.system(size: textSize, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, closeSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityAction(named: L10n.text("關閉分頁")) { tabs.close(tab.id) }
            .help(tab.browser.showsRecentItems ? tab.browser.title : tab.browser.directory.path)

            Button(L10n.text("關閉「%@」分頁", String(describing: tab.browser.title)), systemImage: "xmark") { tabs.close(tab.id) }
                .labelStyle(.iconOnly)
                .font(.system(size: iconSize * 0.72, weight: .medium))
                .frame(width: closeSize, height: closeSize)
                .buttonStyle(.borderless)
                .padding(.leading, inset)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
        }
        .background {
            if isActive {
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .onHover { hovering in
            if hovering { hoveredTab = tab.id }
            else if isHovered { hoveredTab = nil }
        }
    }
}
