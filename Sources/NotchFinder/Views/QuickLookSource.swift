import AppKit
import SwiftUI

@MainActor
final class QuickLookSources {
    private let views = NSMapTable<NSURL, NSView>.strongToWeakObjects()

    func register(_ view: NSView, for url: URL) {
        views.setObject(view, forKey: url as NSURL)
    }

    func unregister(_ view: NSView, for url: URL) {
        let key = url as NSURL
        if views.object(forKey: key) === view { views.removeObject(forKey: key) }
    }

    func screenFrame(for url: URL, in window: NSWindow) -> NSRect {
        guard window.isVisible, let view = views.object(forKey: url as NSURL),
              view.window === window, !view.isHiddenOrHasHiddenAncestor else { return .zero }
        let visibleBounds = view.bounds.intersection(view.visibleRect)
        guard !visibleBounds.isEmpty else { return .zero }
        return window.convertToScreen(view.convert(visibleBounds, to: nil))
    }
}

private struct QuickLookSourcesKey: EnvironmentKey {
    static let defaultValue: QuickLookSources? = nil
}

extension EnvironmentValues {
    var quickLookSources: QuickLookSources? {
        get { self[QuickLookSourcesKey.self] }
        set { self[QuickLookSourcesKey.self] = newValue }
    }
}

struct QuickLookSource: NSViewRepresentable {
    let url: URL
    let sources: QuickLookSources

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.configure(url: url, sources: sources)
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.configure(url: nil, sources: nil)
    }

    final class Anchor: NSView {
        private var url: URL?
        private weak var sources: QuickLookSources?

        func configure(url: URL?, sources: QuickLookSources?) {
            guard self.url != url || self.sources !== sources else { return }
            if let previousURL = self.url { self.sources?.unregister(self, for: previousURL) }
            self.url = url
            self.sources = sources
            if let url, window != nil { sources?.register(self, for: url) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let url else { return }
            if window != nil { sources?.register(self, for: url) }
            else { sources?.unregister(self, for: url) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
