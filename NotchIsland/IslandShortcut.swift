import AppKit
import Carbon

/// Registers Command-period with the system, without requiring Accessibility permission.
final class IslandShortcut {
    var onToggle: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var registered = false

    func start() {
        guard !registered else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4E49484B, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<IslandShortcut>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.onToggle?() }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event,
                                  Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return }
        registered = RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(cmdKey),
                                        EventHotKeyID(signature: 0x4E49484B, id: 1),
                                        GetApplicationEventTarget(), 0, &hotKey) == noErr
        if !registered, let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
