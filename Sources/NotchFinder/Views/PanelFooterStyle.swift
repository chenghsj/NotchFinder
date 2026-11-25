import SwiftUI

struct PanelFooterStyle: ViewModifier {
    static let rowHeight: CGFloat = 29
    static let bottomPadding: CGFloat = 8

    let textSize: CGFloat
    @Environment(\.panelStyle) private var panelStyle

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            content
                .font(.system(size: textSize))
                .padding(.horizontal, 12)
                .frame(height: Self.rowHeight)
                .padding(.bottom, Self.bottomPadding)
        }
        .background(panelStyle.windowColor)
    }
}
