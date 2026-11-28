import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarFolderDrop: DropDelegate {
    private static let locationType = UTType(exportedAs: "local.notchfinder.sidebar-location")
    static let types: [UTType] = [locationType, .fileURL]

    let sidebar: SidebarLocations
    let visibleItems: [BrowserLocation]
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    @Binding var insertionIndex: Int?

    static func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: locationType.identifier, visibility: .ownProcess) {
            complete in
            complete(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }

    func dropEntered(info: DropInfo) {
        insertionIndex = index(at: info.location.y)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionIndex = index(at: info.location.y)
        return DropProposal(operation: info.hasItemsConforming(to: [Self.locationType]) ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        insertionIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = index(at: info.location.y)
        insertionIndex = nil
        let providers = info.itemProviders(for: Self.types)
        guard !providers.isEmpty else { return false }
        let anchor = visibleItems.indices.contains(index) ? visibleItems[index].url : nil
        DropURLLoader.load(providers, as: {
            $0.hasItemConformingToTypeIdentifier(Self.locationType.identifier) ? Self.locationType : .fileURL
        }) { urls in
            sidebar.insertFolders(urls, before: anchor)
        }
        return true
    }

    private func index(at y: CGFloat) -> Int {
        let step = rowHeight + rowSpacing
        let beyondFirstMidpoint = max(0, y - rowHeight / 2)
        return y < rowHeight / 2 ? 0 : min(visibleItems.count, Int(beyondFirstMidpoint / step) + 1)
    }
}
