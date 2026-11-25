import Foundation

struct NotchHover {
    enum Event {
        case show, hide
    }

    private enum State {
        case hidden(enteredAt: TimeInterval?)
        case visible(awaitingEntry: Bool, leftAt: TimeInterval?)
        case waitingForExit
    }

    private var state: State = .hidden(enteredAt: nil)

    mutating func didShow(manually: Bool) {
        state = .visible(awaitingEntry: manually, leftAt: nil)
    }

    mutating func didInteract() {
        guard case .visible = state else { return }
        state = .visible(awaitingEntry: false, leftAt: nil)
    }

    mutating func didHide(suppressUntilExit: Bool) {
        state = suppressUntilExit ? .waitingForExit : .hidden(enteredAt: nil)
    }

    mutating func update(insideTrigger: Bool, insidePanel: Bool, mouseDown: Bool, now: TimeInterval,
                         showDelay: TimeInterval = 0.15, hideDelay: TimeInterval = 0.24) -> Event? {
        switch state {
        case .waitingForExit:
            if !insideTrigger { state = .hidden(enteredAt: nil) }

        case .hidden(let enteredAt):
            guard insideTrigger, !mouseDown else {
                state = .hidden(enteredAt: nil)
                return nil
            }
            if let enteredAt {
                if now - enteredAt >= showDelay { return .show }
            } else {
                if showDelay == 0 { return .show }
                state = .hidden(enteredAt: now)
            }

        case .visible(let awaitingEntry, let leftAt):
            if insidePanel {
                state = .visible(awaitingEntry: false, leftAt: nil)
            } else if insideTrigger || mouseDown || awaitingEntry {
                state = .visible(awaitingEntry: awaitingEntry, leftAt: nil)
            } else if let leftAt {
                if now - leftAt >= hideDelay { return .hide }
            } else {
                if hideDelay == 0 { return .hide }
                state = .visible(awaitingEntry: false, leftAt: now)
            }
        }

        return nil
    }
}
