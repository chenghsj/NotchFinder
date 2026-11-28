import Carbon

@MainActor
final class PanelGlobalHotKeys {
    private struct Registration {
        let shortcut: KeyShortcut
        let reference: EventHotKeyRef
        let identifier: UInt32
    }

    private static let signature: OSType = 0x4e4f5443
    private var eventHandler: EventHandlerRef?
    private var registrations: [PanelCommand: Registration] = [:]
    private var nextIdentifier: UInt32 = 1
    private let action: (PanelCommand) -> Void

    init(action: @escaping (PanelCommand) -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<PanelGlobalHotKeys>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { owner.dispatch(identifier) }
            },
            1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
    }

    func update(_ changes: [PanelCommand: KeyShortcut]) -> Bool {
        guard eventHandler != nil else { return false }
        var updated = registrations
        var added: [Registration] = []
        for (command, shortcut) in changes {
            // A reset can move a registered key from one command to another.
            if let existing = registrations.values.first(where: { $0.shortcut.matches(shortcut) }) {
                updated[command] = existing
            } else if let registration = register(shortcut) {
                updated[command] = registration
                added.append(registration)
            } else {
                for registration in added { UnregisterEventHotKey(registration.reference) }
                return false
            }
        }
        let retained = Set(updated.values.map(\.identifier))
        for registration in registrations.values where !retained.contains(registration.identifier) {
            UnregisterEventHotKey(registration.reference)
        }
        registrations = updated
        return true
    }

    private func register(_ shortcut: KeyShortcut) -> Registration? {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: nextIdentifier)
        nextIdentifier &+= 1
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, identifier,
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { return nil }
        return Registration(shortcut: shortcut, reference: reference, identifier: identifier.id)
    }

    private func dispatch(_ identifier: EventHotKeyID) -> OSStatus {
        guard identifier.signature == Self.signature,
              let command = registrations.first(where: { $0.value.identifier == identifier.id })?.key else {
            return OSStatus(eventNotHandledErr)
        }
        action(command)
        return noErr
    }

    func stop() {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        registrations.removeAll()
        eventHandler = nil
    }
}
