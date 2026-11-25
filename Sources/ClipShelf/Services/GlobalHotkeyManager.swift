import Carbon
import ClipShelfCore
import Foundation

@MainActor
public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private static let signature: OSType = 0x43534846 // 'CSHF'
    private static let hotKeyID: UInt32 = 1

    private init() {}

    public func register(shortcut: ShortcutSpec, handler: @escaping () -> Void) {
        unregister()
        self.onTrigger = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.id == GlobalHotkeyManager.hotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        let hkID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }
}
