import AppKit
import SwiftUI

@MainActor
@Observable
final class UpdateProgressWindow {
    enum Stage {
        case downloading, extracting, ready, installing

        var title: String {
            switch self {
            case .downloading: L10n.text("正在下載更新…")
            case .extracting: L10n.text("正在準備更新…")
            case .ready: L10n.text("更新已準備就緒")
            case .installing: L10n.text("正在安裝更新…")
            }
        }
    }

    private(set) var stage = Stage.downloading
    var expectedBytes: UInt64 = 0
    var receivedBytes: UInt64 = 0
    var extractionProgress: Double?
    private(set) var action: (() -> Void)?
    @ObservationIgnored private var window: NSWindow?

    var fraction: Double? {
        switch stage {
        case .downloading where expectedBytes > 0: min(1, Double(receivedBytes) / Double(expectedBytes))
        case .extracting: extractionProgress
        default: nil
        }
    }

    func show(_ stage: Stage, action: (() -> Void)? = nil) {
        self.stage = stage
        self.action = action
        expectedBytes = 0
        receivedBytes = 0
        extractionProgress = nil
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: UpdateProgressView(progress: self)))
            window.styleMask = [.titled, .miniaturizable]
            window.title = "Notch Finder"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        if stage == .ready {
            window?.makeKeyAndOrderFront(nil)
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func performAction() {
        let action = action
        if stage != .installing { self.action = nil }
        action?()
    }

    func close() {
        action = nil
        window?.close()
        window = nil
    }
}

private struct UpdateProgressView: View {
    let progress: UpdateProgressWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.stage.title).font(.headline)
            if progress.stage != .ready {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(progress.stage.title)
            }
            HStack {
                if let fraction = progress.fraction {
                    Text(fraction.formatted(.percent.locale(L10n.locale))).monospacedDigit()
                } else if progress.stage == .downloading, progress.receivedBytes > 0 {
                    Text(Int64(clamping: progress.receivedBytes).formatted(.byteCount(style: .file).locale(L10n.locale)))
                }
                Spacer()
                switch progress.stage {
                case .downloading:
                    Button(L10n.text("取消"), action: progress.performAction)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("SUStatusCancel")
                        .disabled(progress.action == nil)
                case .ready:
                    Button(L10n.text("安裝並重新啟動"), action: progress.performAction)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("SUStatusInstallAndRelaunch")
                        .disabled(progress.action == nil)
                case .installing where progress.action != nil:
                    Button(L10n.text("重試"), action: progress.performAction)
                default:
                    EmptyView()
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
