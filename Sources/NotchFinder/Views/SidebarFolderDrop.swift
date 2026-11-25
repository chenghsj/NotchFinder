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
        insertionIndex = nil
        let providers = info.itemProviders(for: Self.types)
        guard !providers.isEmpty else { return false }
        let target = index(at: info.location.y)
        let anchor = visibleItems.indices.contains(target) ? visibleItems[target].url : nil
        let loader = SidebarDropLoad(count: providers.count) { urls in
            sidebar.insertFolders(urls, before: anchor)
        }
        for (index, provider) in providers.enumerated() {
            let type = provider.hasItemConformingToTypeIdentifier(Self.locationType.identifier) ? Self.locationType : .fileURL
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in loader.finish(url, at: index) }
            }
        }
        return true
    }

    private func index(at y: CGFloat) -> Int {
        let beyondFirstMidpoint = max(0, y - rowHeight / 2)
        if y < rowHeight / 2 { return 0 }
        return min(visibleItems.count, Int(beyondFirstMidpoint / (rowHeight + rowSpacing)) + 1)
    }
}

@MainActor
private final class SidebarDropLoad {
    private var urls: [URL?]
    private var remaining: Int
    private let completion: ([URL]) -> Void

    init(count: Int, completion: @escaping ([URL]) -> Void) {
        urls = Array(repeating: nil, count: count)
        remaining = count
        self.completion = completion
    }

    func finish(_ url: URL?, at index: Int) {
        urls[index] = url
        remaining -= 1
        if remaining == 0 { completion(urls.compactMap { $0 }) }
    }
}
