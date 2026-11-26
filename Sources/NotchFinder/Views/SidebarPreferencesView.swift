import AppKit
import SwiftUI

struct SidebarPreferencesView: View {
    @Bindable var settings: NotchSettings
    @Bindable var locations: SidebarLocations

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $locations.showsRecents) {
                    Label(L10n.text("最近項目"), systemImage: "clock")
                }
                .toggleStyle(.checkbox)
            }
            Section(L10n.text("喜好項目")) {
                ForEach(locations.builtInFavorites, content: locationToggle)
            }
            Section(L10n.text("位置")) {
                ForEach(locations.locationItems, content: locationToggle)
                ForEach(SidebarVolumeKind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(
                        get: { locations.isVisible(kind) },
                        set: { locations.setVisible($0, for: kind) }
                    )) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Section(L10n.text("標籤")) {
                Toggle(isOn: $locations.showsTags) {
                    Label(L10n.text("顯示 Finder 標籤"), systemImage: "tag")
                }
                .toggleStyle(.checkbox)
            }
            Section(L10n.text("工具")) {
                Toggle(isOn: $settings.showsClipboardInSidebar) {
                    Label(L10n.text("剪貼簿"), systemImage: "clipboard")
                }
                .toggleStyle(.checkbox)
            }
        }
        .formStyle(.grouped)
    }

    private func locationToggle(_ location: BrowserLocation) -> some View {
        Toggle(isOn: Binding(
            get: { locations.isVisible(location) },
            set: { locations.setVisible($0, for: location) }
        )) {
            Label {
                Text(location.name)
            } icon: {
                SidebarLocationIcon(location: location, size: settings.interfaceSize.panelIcon)
            }
        }
        .toggleStyle(.checkbox)
    }
}

struct SidebarLocationIcon: View {
    private static let applicationsImage: NSImage? = {
        let coreTypes = Bundle(path: "/System/Library/CoreServices/CoreTypes.bundle")
        guard let url = coreTypes?.url(forResource: "SidebarApplicationsFolder", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        // The 18-pixel representation can render distorted when drawn as a template.
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }
        guard let bitmap, let cgImage = bitmap.cgImage else { return image }
        return NSImage(cgImage: cgImage, size: bitmap.size)
    }()

    let location: BrowserLocation
    let size: CGFloat

    var body: some View {
        if location.url.path == DiskImageInstall.applicationsDirectory.path,
           let image = Self.applicationsImage {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: location.symbol)
                .font(.system(size: size))
        }
    }
}
