import AppKit
import SwiftUI

struct FileIconGrid: View {
    let browser: FileBrowser
    let entries: [FileEntry]
    let interfaceSize: FileDisplaySize
    let fontDesign: Font.Design
    let cleanupInstaller: Bool
    let releaseSearchFocus: () -> Void
    @State private var anchor: URL?

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                grid
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    .background {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture {
                                browser.selection.removeAll()
                                anchor = nil
                            }
                    }
            }
        }
    }

    private var grid: some View {
        let tileWidth = interfaceSize.grid.width
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 8)], spacing: 9) {
            ForEach(entries) { entry in
                let selected = browser.selection.contains(entry.id)
                Button { select(entry.id) } label: {
                    VStack(spacing: 6) {
                        BrowserFileIcon(entry: entry, side: interfaceSize.grid.icon, loadsFileIcon: browser.fileIconsEnabled)
                        Text(entry.name)
                            .font(.system(size: interfaceSize.panelText, design: fontDesign))
                            .multilineTextAlignment(.center)
                            .truncationMode(.middle)
                            .lineLimit(2)
                    }
                    .padding(4)
                }
                .buttonStyle(PanelButtonStyle(selected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .onDrag { NSItemProvider(object: entry.url as NSURL) }
                .simultaneousGesture(TapGesture(count: 2).onEnded { browser.openItems([entry.id]) })
                .contextMenu {
                    FileCommands(browser: browser, items: selected ? browser.selection : [entry.id],
                                 cleanupInstaller: cleanupInstaller)
                }
                .help(entry.name)
                .frame(maxWidth: .infinity)
                .frame(height: interfaceSize.grid.height)
            }
        }
    }

    private func select(_ item: URL) {
        releaseSearchFocus()
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor,
           let first = entries.firstIndex(where: { $0.id == anchor }),
           let last = entries.firstIndex(where: { $0.id == item }) {
            let range = Set(entries[min(first, last)...max(first, last)].map(\.id))
            browser.selection = modifiers.contains(.command) ? browser.selection.union(range) : range
            return
        }
        if modifiers.contains(.command) {
            if browser.selection.contains(item) { browser.selection.remove(item) }
            else { browser.selection.insert(item) }
        } else {
            browser.selection = [item]
        }
        anchor = item
    }
}
