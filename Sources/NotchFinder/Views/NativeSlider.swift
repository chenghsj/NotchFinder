import AppKit
import SwiftUI

struct NativeSlider: NSViewRepresentable {
    let title: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    var step: Double?

    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, bounds: bounds, step: step)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: bounds.lowerBound, maxValue: bounds.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.change(_:)))
        slider.isContinuous = step == nil
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
        private let bounds: ClosedRange<Double>
        private let step: Double?

        init(value: Binding<Double>, bounds: ClosedRange<Double>, step: Double?) {
            self.value = value
            self.bounds = bounds
            self.step = step
        }

        @objc func change(_ slider: NSSlider) {
            var position = slider.doubleValue
            if let step {
                let previous = value.wrappedValue
                let nearest = bounds.lowerBound + ((position - bounds.lowerBound) / step).rounded() * step
                if nearest == previous && position != previous && NSApp.currentEvent?.type == .keyDown {
                    position = previous + (position > previous ? step : -step)
                } else {
                    position = nearest
                }
                position = min(bounds.upperBound, max(bounds.lowerBound, position))
                slider.doubleValue = position
            }
            if value.wrappedValue != position { value.wrappedValue = position }
        }
    }
}
