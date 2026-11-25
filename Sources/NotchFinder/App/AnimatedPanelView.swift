import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class AnimatedPanelView: NSView {
    private enum Presentation {
        case starting, expanded, hidden
    }

    private struct Frame {
        let size: CGSize
        let topCenter: CGPoint
        let radius: CGFloat
        let contentOpacity: CGFloat
        let contentOffset: CGFloat
        let surfaceOpacity: CGFloat

        func moving(toward target: Frame, shell: CGFloat, content: CGFloat, surfaceOpacity: CGFloat) -> Frame {
            Frame(
                size: CGSize(
                    width: size.width + (target.size.width - size.width) * shell,
                    height: size.height + (target.size.height - size.height) * shell
                ),
                topCenter: CGPoint(
                    x: topCenter.x + (target.topCenter.x - topCenter.x) * shell,
                    y: target.topCenter.y
                ),
                radius: radius + (target.radius - radius) * shell,
                contentOpacity: contentOpacity + (target.contentOpacity - contentOpacity) * content,
                contentOffset: contentOffset + (target.contentOffset - contentOffset) * content,
                surfaceOpacity: surfaceOpacity
            )
        }
    }

    private struct Motion {
        let start: Frame
        let target: Frame
        var firstFrameTime: TimeInterval? = nil
        let openingSpring: Spring?
        let contentDelay: TimeInterval
        let contentDuration: TimeInterval
        let duration: TimeInterval
        let rate: Double
        let expanded: Bool
        let completion: (@MainActor () -> Void)?
    }

    var collapsedCenterX: CGFloat?
    var collapsedWidth: CGFloat = 116

    private let hostingView: NSHostingView<BrowserPanel>
    private let materialView = NSVisualEffectView()
    private let revealMask = CALayer()
    private var renderedFrame: Frame?
    private var motion: Motion?
    private var tick: CADisplayLink?

    // Leave room for the spring to overshoot without clipping the visible edge.
    private var expandedBounds: CGRect {
        CGRect(x: bounds.minX + 6, y: bounds.minY + 8,
               width: max(0, bounds.width - 12), height: max(0, bounds.height - 8))
    }

    init(rootView: BrowserPanel) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        hostingView.wantsLayer = true
        hostingView.alphaValue = 0
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.setAccessibilityElement(false)
        addSubview(materialView)
        addSubview(hostingView)

        wantsLayer = true
        revealMask.backgroundColor = NSColor.black.cgColor
        revealMask.anchorPoint = CGPoint(x: 0.5, y: 1)
        revealMask.cornerCurve = .continuous
        layer?.mask = revealMask
        updateSurfaceAppearance()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        hostingView.frame = expandedBounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceAppearance()
    }

    func prepareForReveal() {
        stopMotion()
        layoutSubtreeIfNeeded()
        render(frame(for: .starting))
    }

    func fitExpandedPanel() {
        layoutSubtreeIfNeeded()
        render(frame(for: .expanded))
    }

    func setExpanded(_ expanded: Bool, animated: Bool, speed: PanelAnimationSpeed = .standard,
                     completion: (@MainActor () -> Void)? = nil) {
        stopMotion()
        let target = frame(for: expanded ? .expanded : .hidden)

        guard animated, speed != .off, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let renderedFrame else {
            render(target)
            if expanded { window?.invalidateShadow() }
            completion?()
            return
        }

        let openingSpring = expanded ? Spring(duration: 0.26, bounce: 0.12) : nil
        let contentDelay = expanded && renderedFrame.contentOpacity < 0.1 ? 0.085 : 0
        let contentDuration = expanded ? 0.115 : 0.08
        // End the reveal once the remaining spring motion is smaller than one screen point.
        let duration = expanded ? 0.34 : 0.18
        motion = Motion(start: renderedFrame, target: target, openingSpring: openingSpring,
                        contentDelay: contentDelay, contentDuration: contentDuration,
                        duration: duration, rate: speed.rate, expanded: expanded, completion: completion)

        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        tick = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let motion else { return }
        let firstFrameTime = motion.firstFrameTime ?? link.targetTimestamp
        if motion.firstFrameTime == nil { self.motion?.firstFrameTime = firstFrameTime }
        let elapsed = max(0, link.targetTimestamp - firstFrameTime) * motion.rate
        if elapsed >= motion.duration {
            finish(motion)
            return
        }

        let shell = motion.openingSpring?.value(target: 1.0, time: elapsed)
            ?? UnitCurve.easeInOut.value(at: elapsed / motion.duration)
        let fadeTime = min(1, max(0, (elapsed - motion.contentDelay) / motion.contentDuration))
        let content = UnitCurve.easeOut.value(at: fadeTime)
        let surfaceOpacity: CGFloat
        if motion.expanded {
            let reveal = UnitCurve.easeOut.value(at: min(1, elapsed / 0.075))
            surfaceOpacity = motion.start.surfaceOpacity + (1 - motion.start.surfaceOpacity) * reveal
        } else {
            // Blend out while there is still enough height to read as a panel.
            let height = motion.start.size.height * (1 - shell)
            let visibility = min(1, max(0, (height - 28) / 96))
            surfaceOpacity = min(motion.start.surfaceOpacity, UnitCurve.easeInOut.value(at: visibility))
            if surfaceOpacity == 0 {
                finish(motion)
                return
            }
        }
        render(motion.start.moving(toward: motion.target, shell: shell, content: content, surfaceOpacity: surfaceOpacity))
    }

    private func frame(for presentation: Presentation) -> Frame {
        let expanded = presentation == .expanded
        let width = min(collapsedWidth, bounds.width)
        let center = collapsedCenterX ?? bounds.midX
        let clampedCenter = min(max(center, bounds.minX + width / 2), bounds.maxX - width / 2)
        let collapsedHeight = presentation == .starting ? min(12, bounds.height) : 0
        return Frame(
            size: expanded ? expandedBounds.size : CGSize(width: width, height: collapsedHeight),
            topCenter: CGPoint(x: expanded ? bounds.midX : clampedCenter, y: bounds.maxY),
            radius: expanded ? 23 : collapsedHeight / 2,
            contentOpacity: expanded ? 1 : 0,
            contentOffset: expanded ? 0 : 6,
            surfaceOpacity: presentation == .hidden ? 0 : 1
        )
    }

    private func stopMotion() {
        tick?.invalidate()
        tick = nil
        motion = nil
    }

    private func finish(_ motion: Motion) {
        stopMotion()
        render(motion.target)
        if motion.expanded { window?.invalidateShadow() }
        motion.completion?()
    }

    private func render(_ frame: Frame) {
        let previous = renderedFrame
        renderedFrame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.bounds = CGRect(origin: .zero, size: frame.size)
        revealMask.position = frame.topCenter
        revealMask.cornerRadius = frame.radius
        if frame.surfaceOpacity != previous?.surfaceOpacity { revealMask.opacity = Float(frame.surfaceOpacity) }
        if frame.contentOpacity != previous?.contentOpacity { hostingView.alphaValue = frame.contentOpacity }
        if frame.contentOffset != previous?.contentOffset {
            hostingView.layer?.transform = CATransform3DMakeTranslation(0, frame.contentOffset, 0)
        }
        CATransaction.commit()
    }

    @objc private func displayOptionsDidChange(_ notification: Notification) {
        updateSurfaceAppearance()
    }

    private func updateSurfaceAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        materialView.isHidden = reduceTransparency
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = reduceTransparency ? NSColor.windowBackgroundColor.cgColor : nil
        }
        CATransaction.commit()
    }
}
