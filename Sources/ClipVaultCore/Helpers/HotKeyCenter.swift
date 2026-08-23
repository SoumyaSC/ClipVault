import Foundation
import Carbon.HIToolbox

/// Thin, safe wrapper around the legacy-but-still-canonical Carbon hot key API.
final class HotKeyCenter {

    private static let signature = OSType(0x43_56_4C_54)  // 'CVLT'

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?
    private(set) var isRegistered = false

    deinit {
        unregister()
    }

    /// Registers ⌘⇧V (defaults). Replaces any existing registration.
    func registerDefault(handler: @escaping () -> Void) {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            if hotKeyID.signature == HotKeyCenter.signature, hotKeyID.id == 1, let userData {
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                center.handler?()
            }
            return noErr
        }

        let installResult = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installResult == noErr else {
            NSLog("ClipVault: InstallEventHandler failed (\(installResult))")
            return
        }

        var ref: EventHotKeyRef?
        // cmdKey | shiftKey → Command(⌘) + Shift(⇓⇧) Carbon modifier mask.
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let regResult = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            modifiers,
            EventHotKeyID(signature: HotKeyCenter.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard regResult == noErr, ref != nil else {
            NSLog("ClipVault: RegisterEventHotKey failed (\(regResult))")
            return
        }
        hotKeyRef = ref
        isRegistered = true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handlerRef = eventHandler {
            RemoveEventHandler(handlerRef)
            eventHandler = nil
        }
        handler = nil
        isRegistered = false
    }
}
