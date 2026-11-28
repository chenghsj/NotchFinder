import AppKit
import SwiftUI

struct NativeSlider: NSViewRepresentable {
    let title: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>

    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: bounds.lowerBound, maxValue: bounds.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.change(_:)))
        slider.isContinuous = true
        slider.setAccessibilityLabel(title)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.isEnabled = isEnabled
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func change(_ slider: NSSlider) {
            if value.wrappedValue != slider.doubleValue { value.wrappedValue = slider.doubleValue }
        }
    }
}
