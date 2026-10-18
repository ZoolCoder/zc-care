import Carbon.HIToolbox

/// A system-wide shortcut through Carbon, which needs no Accessibility
/// permission: ⌃⌥Z.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue()
            // Carbon delivers hotkeys on the main thread.
            MainActor.assumeIsolated { me.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x5A43_4252), id: 1) // "ZCBR"
        RegisterEventHotKey(UInt32(kVK_ANSI_Z), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}
