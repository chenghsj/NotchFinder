import AppKit
import Foundation
import Observation

struct BrowserLocation: Identifiable {
    enum Title {
        case localized(String)
        case literal(String)
    }

    let title: Title
    let symbol: String
    let url: URL

    var id: URL { url }
    var name: String {
        switch title {
        case .localized(let key): L10n.text(key)
        case .literal(let value): value
        }
    }
}

enum SidebarVolumeKind: String, CaseIterable {
    case internalDisks, externalDisks, servers

    var title: String {
        switch self {
        case .internalDisks: L10n.text("硬碟")
        case .externalDisks: L10n.text("外接磁碟")
        case .servers: L10n.text("連接的伺服器")
        }
    }

    var symbol: String { self == .servers ? "server.rack" : "externaldrive" }
}

@MainActor
@Observable
final class SidebarLocations {
    private struct MountedLocation {
        let kind: SidebarVolumeKind
        let location: BrowserLocation
        let canEject: Bool
    }

    @ObservationIgnored private let defaults: UserDefaults
    private let standardFavorites: [BrowserLocation]
    private let optionalFavoritePaths: Set<String>
    private let standardLocations: [BrowserLocation]
    private var mounts: [MountedLocation] = []
    private(set) var isEjectingVolume = false
    private var favorites: [URL]
    private var order: [String]
    private var hidden: Set<String>
    private var enabledOptionalFavorites: Set<String>
    private var hiddenVolumeKinds: Set<String>
    var showsRecents: Bool { didSet { defaults.set(showsRecents, forKey: "showsSidebarRecents") } }
    var showsTags: Bool { didSet { defaults.set(showsTags, forKey: "showsSidebarTags") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL
        let userFolders: [(FileManager.SearchPathDirectory, String, String, Bool)] = [
            (.desktopDirectory, "桌面", "menubar.dock.rectangle", true),
            (.documentDirectory, "文件", "doc", true),
            (.downloadsDirectory, "下載項目", "arrow.down.circle", true),
            (.moviesDirectory, "影片", "film", false),
            (.musicDirectory, "音樂", "music.note", false),
            (.picturesDirectory, "圖片", "photo", false)
        ]
        let builtIn = userFolders.compactMap { folder, titleKey, symbol, visible -> (BrowserLocation, Bool)? in
            guard let url = manager.urls(for: folder, in: .userDomainMask).first else { return nil }
            return (BrowserLocation(title: .localized(titleKey), symbol: symbol, url: url.standardizedFileURL), visible)
        }
        standardFavorites = [
            BrowserLocation(title: .localized("應用程式"), symbol: "app.dashed", url: DiskImageInstall.applicationsDirectory)
        ] + builtIn.map(\.0)
        optionalFavoritePaths = Set(builtIn.filter { !$0.1 }.map { $0.0.url.path })
        let cloudFolders = [
            ("iCloud 雲碟", home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)),
            ("雲端儲存空間", home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory))
        ]
        var places = cloudFolders.compactMap { titleKey, url -> BrowserLocation? in
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
            return BrowserLocation(title: .localized(titleKey), symbol: "icloud", url: url.standardizedFileURL)
        }
        places.append(BrowserLocation(title: .localized("個人資料夾"), symbol: "house", url: home))
        if let trash = manager.urls(for: .trashDirectory, in: .userDomainMask).first {
            places.append(BrowserLocation(title: .localized("垃圾桶"), symbol: "trash", url: trash.standardizedFileURL))
        }
        standardLocations = places
        favorites = (defaults.stringArray(forKey: "favoriteFolders") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        order = defaults.stringArray(forKey: "sidebarLocationOrder") ?? []
        hidden = Set(defaults.stringArray(forKey: "hiddenSidebarLocations") ?? [])
        enabledOptionalFavorites = Set(defaults.stringArray(forKey: "enabledOptionalSidebarFavorites") ?? [])
        hiddenVolumeKinds = Set(defaults.stringArray(forKey: "hiddenSidebarVolumeKinds") ?? [])
        showsRecents = defaults.object(forKey: "showsSidebarRecents") as? Bool ?? true
        showsTags = defaults.bool(forKey: "showsSidebarTags")
        refreshVolumes()
    }

    var items: [BrowserLocation] { favoriteItems + locationItems + mounts.map(\.location) }
    var builtInFavorites: [BrowserLocation] { standardFavorites }
    var locationItems: [BrowserLocation] { standardLocations }

    var favoriteItems: [BrowserLocation] {
        let locations = standardFavorites + favorites.filter { url in
            !standardLocations.contains { $0.url.path == url.path }
        }.map {
            BrowserLocation(title: $0.path == "/" ? .localized("根目錄") : .literal($0.lastPathComponent), symbol: "folder", url: $0)
        }
        let byPath = Dictionary(locations.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return (order.compactMap { byPath[$0] } + locations).filter { seen.insert($0.url.path).inserted }
    }

    var visibleFavorites: [BrowserLocation] { favoriteItems.filter(isVisible) }
    var visibleLocations: [BrowserLocation] {
        locationItems.filter(isVisible) + mounts.filter { isVisible($0.kind) }.map(\.location)
    }

    var visibleTags: [String] {
        guard showsTags else { return [] }
        var seen: Set<String> = []
        return NSWorkspace.shared.fileLabels.dropFirst().filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func refreshVolumes() {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey
        ]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        mounts = volumes.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            let kind: SidebarVolumeKind
            if values?.volumeIsLocal == false { kind = .servers }
            else { kind = values?.volumeIsInternal == true || url.path == "/" ? .internalDisks : .externalDisks }
            let title = values?.volumeLocalizedName.map(BrowserLocation.Title.literal)
                ?? (url.path == "/" ? .localized("根目錄") : .literal(url.lastPathComponent))
            let location = BrowserLocation(title: title, symbol: kind.symbol, url: url.standardizedFileURL)
            // USB drives can report fixed media even though the entire device can be disconnected.
            let canEject = url.path != "/" && (values?.volumeIsInternal == false || values?.volumeIsLocal == false
                || values?.volumeIsRemovable == true || values?.volumeIsEjectable == true)
            return MountedLocation(kind: kind, location: location, canEject: canEject)
        }
    }

    func canEject(_ location: BrowserLocation) -> Bool {
        mounts.contains { $0.canEject && $0.location.id == location.id }
    }

    func eject(_ location: BrowserLocation) async throws {
        guard !isEjectingVolume, canEject(location) else { return }
        isEjectingVolume = true
        defer {
            refreshVolumes()
            isEjectingVolume = false
        }
        let volume = location.url
        try await Task.detached(priority: .userInitiated) {
            if try !DiskImageInstall.ejectMountedImage(at: volume) {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            }
        }.value
    }

    func isVisible(_ location: BrowserLocation) -> Bool {
        let path = location.url.path
        return !hidden.contains(path) && (!optionalFavoritePaths.contains(path) || enabledOptionalFavorites.contains(path))
    }

    func setVisible(_ visible: Bool, for location: BrowserLocation) {
        let path = location.url.path
        if visible {
            hidden.remove(path)
            if optionalFavoritePaths.contains(path) { enabledOptionalFavorites.insert(path) }
        } else {
            hidden.insert(path)
            enabledOptionalFavorites.remove(path)
        }
        persistVisibility()
    }

    func isVisible(_ kind: SidebarVolumeKind) -> Bool { !hiddenVolumeKinds.contains(kind.rawValue) }

    func setVisible(_ visible: Bool, for kind: SidebarVolumeKind) {
        if visible { hiddenVolumeKinds.remove(kind.rawValue) }
        else { hiddenVolumeKinds.insert(kind.rawValue) }
        defaults.set(hiddenVolumeKinds.sorted(), forKey: "hiddenSidebarVolumeKinds")
    }

    func canRemove(_ location: BrowserLocation) -> Bool { !mounts.contains { $0.location.id == location.id } }

    private func persistVisibility() {
        defaults.set(hidden.sorted(), forKey: "hiddenSidebarLocations")
        defaults.set(enabledOptionalFavorites.sorted(), forKey: "enabledOptionalSidebarFavorites")
    }

    func insertFolders(_ urls: [URL], before anchor: URL?) {
        let paths = favoriteItems.map(\.url.path)
        let known = Set(paths)
        var inserted: Set<String> = []
        var moving: [String] = []
        var addedFavorites: [URL] = []

        for source in urls where source.isFileURL {
            let url = source.standardizedFileURL
            let path = url.path
            let existsInSidebar = known.contains(path)
            guard (existsInSidebar || canFavorite(url)),
                  (existsInSidebar || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true),
                  inserted.insert(path).inserted else { continue }
            moving.append(path)
            if !existsInSidebar { addedFavorites.append(url) }
        }

        guard !moving.isEmpty else { return }
        let boundary = anchor.flatMap { paths.firstIndex(of: $0.path) } ?? paths.count
        let insertionIndex = paths.prefix(boundary).count { !inserted.contains($0) }
        var updatedOrder = paths.filter { !inserted.contains($0) }
        updatedOrder.insert(contentsOf: moving, at: insertionIndex)

        if !addedFavorites.isEmpty {
            favorites.append(contentsOf: addedFavorites)
            defaults.set(favorites.map(\.path), forKey: "favoriteFolders")
        }
        hidden.subtract(inserted)
        enabledOptionalFavorites.formUnion(inserted.intersection(optionalFavoritePaths))
        persistVisibility()
        if updatedOrder != order {
            order = updatedOrder
            defaults.set(order, forKey: "sidebarLocationOrder")
        }
    }

    func remove(_ location: BrowserLocation) {
        if canFavorite(location.url) {
            removeFavorite(location.url)
        } else {
            setVisible(false, for: location)
        }
    }

    func canFavorite(_ url: URL) -> Bool {
        !standardLocations.contains { $0.url.path == url.path } &&
        !standardFavorites.contains { $0.url.path == url.path }
    }

    func isFavorite(_ url: URL) -> Bool { favorites.contains(url) }

    func toggleFavorite(_ url: URL) {
        guard canFavorite(url) else { return }
        if isFavorite(url) {
            removeFavorite(url)
        } else {
            favorites.append(url)
            defaults.set(favorites.map(\.path), forKey: "favoriteFolders")
        }
    }

    private func removeFavorite(_ url: URL) {
        favorites.removeAll { $0 == url }
        order.removeAll { $0 == url.path }
        hidden.remove(url.path)
        defaults.set(order, forKey: "sidebarLocationOrder")
        defaults.set(hidden.sorted(), forKey: "hiddenSidebarLocations")
        defaults.set(favorites.map(\.path), forKey: "favoriteFolders")
    }
}
