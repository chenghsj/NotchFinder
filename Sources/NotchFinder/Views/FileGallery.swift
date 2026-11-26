import QuickLookUI
import SwiftUI

struct FileGallery: View {
    let browser: FileBrowser
    let entries: [FileEntry]
    let settings: NotchSettings
    let releaseSearchFocus: () -> Void
    let onFileDragEnded: () -> Void

    var body: some View {
        if let entry = entries.first(where: { browser.selection.contains($0.id) }) ?? entries.first {
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    Group {
                        if entry.isFolder {
                            BrowserFileIcon(entry: entry, side: settings.interfaceSize.grid.icon * 1.5,
                                            loadsFileIcon: browser.fileIconsEnabled)
                                .id(entry.id)
                        } else {
                            GalleryPreview(entry: entry)
                                .accessibilityLabel(entry.name)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(entry.name)
                        .font(settings.panelFont(size: settings.interfaceSize.panelText, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.name)
                }
                .padding(8)
                Divider()
                FileTiles(browser: browser, entries: entries, settings: settings, layout: .filmstrip,
                          releaseSearchFocus: releaseSearchFocus, onFileDragEnded: onFileDragEnded)
            }
        } else {
            Color.clear
        }
    }
}

private struct GalleryPreview: NSViewRepresentable {
    let entry: FileEntry

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != entry.url {
            view.previewItem = entry.url as NSURL
        } else if context.coordinator.modified != entry.modified {
            view.refreshPreviewItem()
        }
        context.coordinator.modified = entry.modified
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) { view.close() }

    final class Coordinator {
        var modified: Date?
    }
}
