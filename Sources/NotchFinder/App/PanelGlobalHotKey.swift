import Carbon

@MainActor
final class PanelGlobalHotKey {
    private var eventHandler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var shortcut: KeyShortcut?
    private var nextIdentifier: UInt32 = 1
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<PanelGlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.action() }
                return noErr
            },
            1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
    }

    func replace(with next: KeyShortcut) -> Bool {
        if let shortcut, shortcut.matches(next) { return registration != nil }
        guard eventHandler != nil else { return false }
        var newRegistration: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x4e4f5443, id: nextIdentifier)
        nextIdentifier &+= 1
        let status = RegisterEventHotKey(UInt32(next.keyCode), next.carbonModifiers, identifier,
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &newRegistration)
        guard status == noErr, let newRegistration else { return false }
        if let registration { UnregisterEventHotKey(registration) }
        registration = newRegistration
        shortcut = next
        return true
    }

    func stop() {
        if let registration { UnregisterEventHotKey(registration) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        registration = nil
        eventHandler = nil
        shortcut = nil
    }
}
