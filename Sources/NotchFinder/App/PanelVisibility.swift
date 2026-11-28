import Foundation

struct PanelVisibility {
    enum Event: Equatable {
        case show
        case hide(suppressUntilExit: Bool)
    }

    struct Sample {
        let now: TimeInterval
        let insideTrigger: Bool
        let insideAnyTrigger: Bool
        let insidePanel: Bool
        let mouseDown: Bool
        let trackingEvents: Bool
        let resizing: Bool
        let editing: Bool
        let previewVisible: Bool
        let automaticHide: Bool
        let showDelay: TimeInterval
        let hideDelay: TimeInterval

        var keepsPanelOpen: Bool { resizing || editing || previewVisible || !automaticHide }
    }

    private enum State {
        case hidden(enteredAt: TimeInterval?)
        case visible(awaitingEntry: Bool, leftAt: TimeInterval?)
        case waitingForExit
    }

    private var state: State = .hidden(enteredAt: nil)
    private var dropDeadline: TimeInterval?
    private var resumesAfterDrop = false
    private var wasPreviewVisible = false

    mutating func didShow(manually: Bool) {
        dropDeadline = nil
        state = .visible(awaitingEntry: manually, leftAt: nil)
    }

    mutating func didInteract() {
        dropDeadline = nil
        resumesAfterDrop = false
        guard case .visible = state else { return }
        state = .visible(awaitingEntry: false, leftAt: nil)
    }

    mutating func didHide(suppressUntilExit: Bool) {
        dropDeadline = nil
        wasPreviewVisible = false
        state = suppressUntilExit ? .waitingForExit : .hidden(enteredAt: nil)
    }

    mutating func fileDragEnded(now: TimeInterval, hideDelay: TimeInterval, automaticHide: Bool) {
        guard automaticHide, case .visible = state else { return }
        dropDeadline = now + hideDelay
    }

    mutating func update(_ sample: Sample, pointerIsOverPanelWindow: () -> Bool) -> Event? {
        if !sample.trackingEvents { resumesAfterDrop = false }
        if let deadline = dropDeadline, sample.now >= deadline {
            dropDeadline = nil
            if !sample.keepsPanelOpen, !pointerIsOverPanelWindow() {
                resumesAfterDrop = true
                return .hide(suppressUntilExit: sample.insideAnyTrigger)
            }
        }

        guard !sample.resizing, !sample.trackingEvents || resumesAfterDrop else { return nil }
        if wasPreviewVisible, !sample.previewVisible, case .visible = state {
            state = .visible(awaitingEntry: true, leftAt: nil)
        }
        wasPreviewVisible = sample.previewVisible

        switch state {
        case .waitingForExit:
            if !sample.insideTrigger { state = .hidden(enteredAt: nil) }

        case .hidden(let enteredAt):
            guard sample.insideTrigger, !sample.mouseDown else {
                state = .hidden(enteredAt: nil)
                return nil
            }
            if let enteredAt {
                if sample.now - enteredAt >= sample.showDelay { return .show }
            } else {
                if sample.showDelay == 0 { return .show }
                state = .hidden(enteredAt: sample.now)
            }

        case .visible(let awaitingEntry, let leftAt):
            if sample.insidePanel || sample.keepsPanelOpen {
                state = .visible(awaitingEntry: false, leftAt: nil)
            } else if sample.insideTrigger || sample.mouseDown || awaitingEntry {
                state = .visible(awaitingEntry: awaitingEntry, leftAt: nil)
            } else if let leftAt {
                if sample.now - leftAt >= sample.hideDelay { return .hide(suppressUntilExit: false) }
            } else {
                if sample.hideDelay == 0 { return .hide(suppressUntilExit: false) }
                state = .visible(awaitingEntry: false, leftAt: sample.now)
            }
        }

        return nil
    }
}
