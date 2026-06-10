import Cocoa
import Carbon.HIToolbox
import os.log

/// Purpose: A last-resort, always-available "take the cover down" hotkey that works
///          even when Accessibility is NOT granted. Wraps Carbon `RegisterEventHotKey`,
///          which (unlike a CGEventTap or NSEvent global monitor) needs no Accessibility
///          permission, so it remains the guaranteed escape if anything ever traps the
///          screen at the desk.
/// Inputs: register(_:) takes a () -> Void handler invoked on the main actor when the
///          fixed combo Control+Option+Command+U is pressed.
/// Outputs: none directly — it drives the stored handler.
/// Constraints: Carbon hotkey APIs are C. The event handler MUST be a top-level C
///          function (no Swift context capture), so the Swift handler is held in a
///          static registry keyed by hotkey id and the C callback hops to the main
///          actor via DispatchQueue.main.async before calling it. Single instance is
///          assumed; the static registry keys by signature+id to stay correct anyway.
/// SPORT: MASTER-EMERGENCYHOTKEY
@MainActor
final class EmergencyHotkey {

    /// Fixed combo: Control+Option+Command+U. U keycode = 32 (kVK_ANSI_U).
    private static let keyCode: UInt32 = 32
    private static let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x4355_5254 // 'CURT'
    private static let hotKeyID: UInt32 = 1

    /// Bridge store: Carbon C callbacks can't capture Swift context, so the handler
    /// lives here keyed by hotkey id and the C trampoline looks it up.
    private static var handlers: [UInt32: () -> Void] = [:]

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init() {}

    /// Install the global hotkey and store the handler. Idempotent: a second call
    /// unregisters the prior registration first.
    func register(_ handler: @escaping () -> Void) {
        unregister()
        EmergencyHotkey.handlers[EmergencyHotkey.hotKeyID] = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            emergencyHotkeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard status == noErr else {
            NSLog("Curtain: emergency hotkey handler install failed (\(status))")
            return
        }

        let id = EventHotKeyID(signature: EmergencyHotkey.signature, id: EmergencyHotkey.hotKeyID)
        let regStatus = RegisterEventHotKey(
            EmergencyHotkey.keyCode,
            EmergencyHotkey.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if regStatus == noErr {
            os_log("Curtain: emergency hotkey registered (Control+Option+Command+U)")
        } else {
            NSLog("Curtain: emergency hotkey registration failed (\(regStatus))")
        }
    }

    /// Tear down the hotkey and clear the stored handler.
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        EmergencyHotkey.handlers[EmergencyHotkey.hotKeyID] = nil
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }

    /// Called by the C trampoline (in a nonisolated context) when the combo fires.
    /// Hops to the main actor, looks up the stored handler by id, and runs it. The
    /// `handlers` read happens inside the main-actor hop, so it's isolation-safe.
    nonisolated fileprivate static func fire(id: UInt32) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handlers[id]?()
            }
        }
    }
}

/// Top-level C event handler. Carbon hands us the hotkey id; we forward it to the
/// Swift bridge, which hops to the main actor. No Swift context is captured here.
private func emergencyHotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    guard status == noErr else { return status }
    EmergencyHotkey.fire(id: hkID.id)
    return noErr
}
