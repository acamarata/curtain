import Cocoa

/// Purpose: Block PHYSICAL keyboard/mouse from reaching apps while passing REMOTE
///          (Screen Sharing) input through, so the host desk is inert but the
///          remote operator controls normally.
/// How: a CGEventTap inspects each event's source-state. Physical hardware events
///      report sourceStateID == 1 (kCGEventSourceStateHIDSystemState); Screen
///      Sharing injects synthetic events with a large per-session state ID (!= 1).
///      Verified empirically (see Lessons). Block ==1, pass everything else.
/// Constraints: requires Accessibility permission. Physical key-downs are routed
///      to `onPhysicalKey` to drive the password box.
/// SPORT: MASTER-INPUTFILTER
final class InputFilter {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onPhysicalKey: ((Int, String?) -> Void)?

    /// Returns false if the tap could not be created (missing Accessibility).
    @discardableResult
    func start() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        let mask: CGEventMask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: me) else {
            return false
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        tap = nil; runLoopSource = nil
    }

    fileprivate func handlePhysicalKeyDown(_ event: CGEvent) {
        let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
        DispatchQueue.main.async { self.onPhysicalKey?(kc, chars) }
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }
}

private let callback: CGEventTapCallBack = { _, type, event, refcon in
    let filter = Unmanaged<InputFilter>.fromOpaque(refcon!).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        filter.reenable()
        return Unmanaged.passUnretained(event)
    }
    let physical = (event.getIntegerValueField(.eventSourceStateID) == 1)
    if physical {
        if type == .keyDown { filter.handlePhysicalKeyDown(event) }
        return nil                                   // block hardware input from apps
    }
    return Unmanaged.passUnretained(event)           // pass remote (synthetic) input
}
