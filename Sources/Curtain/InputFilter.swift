import Cocoa

/// Purpose: Block PHYSICAL keyboard/mouse from reaching apps while passing REMOTE
///          (Screen Sharing) input through, so the host desk is inert but the
///          remote operator controls normally.
/// How: a CGEventTap inspects each event's source-state. Physical hardware events
///      report sourceStateID == 1 (kCGEventSourceStateHIDSystemState); Screen
///      Sharing injects synthetic events with a per-session state ID (!= 1).
///      Block ==1 (and route physical key-downs to the password box), pass the rest.
/// Honesty: this is a CONVENIENCE filter, not a security boundary. Any local process
///      can post events with an arbitrary sourceStateID, so injected input can be made
///      to look "remote" and slip past. It keeps a person at the desk from interfering;
///      it does not stop hostile local code. Some HID paths may also bypass a session
///      tap entirely (documented residual).
/// Inputs: `onPhysicalKey(keycode, characters, flags)` fires on the main thread for
///      each physical key-down, where flags is the CGEvent modifier mask raw value.
///      `start()`/`stop()`/`ensureActive()`/retry helpers drive it.
/// Outputs: returns false from start() when the tap can't be created (no Accessibility);
///      `isTapInstalled` lets the coordinator surface that to the user.
/// Constraints: requires Accessibility permission. Tap callback runs on a dedicated tap
///      thread; all Cocoa work is hopped to main. Pinned to the main run loop.
/// SPORT: MASTER-INPUTFILTER
@MainActor
final class InputFilter {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var retryTimer: Timer?

    /// Fired on the main thread for every physical key-down: (keycode, characters,
    /// modifier-flags raw value). The flags let the controller match a reveal combo.
    var onPhysicalKey: ((Int, String?, UInt64) -> Void)?

    /// True once a tap is live. Coordinator shows an "Accessibility needed" warning
    /// when this stays false after start().
    var isTapInstalled: Bool { tap != nil }

    // physicalStateID lives in the nonisolated extension below so the C-callback
    // can reach it without an actor hop. See InputFilter extension at end of file.

    /// Install the tap on the main run loop. Returns false if the tap could not be
    /// created (missing Accessibility), so the caller can prompt or retry.
    @discardableResult
    func start() -> Bool {
        assert(Thread.isMainThread, "InputFilter.start() must run on the main thread")
        if tap != nil { return true }

        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel]
        // CGEventType has no .systemDefined case, but the underlying tap accepts its raw
        // value (14 == NX_SYSDEFINED). Including it blocks physical media / brightness /
        // volume / Mission-Control keys too. Some lower-level HID paths can still bypass a
        // session tap; that residual is accepted.
        let systemDefinedMask: CGEventMask = CGEventMask(1) << 14
        let mask: CGEventMask = types.reduce(systemDefinedMask) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: me) else {
            Log.event("event tap NOT installed (Accessibility?)")
            return false
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        runLoopSource = src
        // Pin to the main run loop so the tap fires no matter which thread called start().
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        startWatchdog()
        Log.event("event tap installed")
        return true
    }

    func stop() {
        cancelRetry()
        watchdog?.invalidate(); watchdog = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; runLoopSource = nil
    }

    /// Re-enable the tap if the system disabled it (timeout / heavy input). Safe to call
    /// repeatedly; backs the watchdog and any coordinator-driven retry.
    func ensureActive() {
        guard let t = tap else { return }
        if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
    }

    /// While the tap is NOT installed, poll Accessibility trust ~every 2s and retry
    /// start() once it flips true. `onSuccess` fires exactly once after install.
    func retryUntilTrusted(onSuccess: @escaping () -> Void) {
        if isTapInstalled { onSuccess(); return }
        cancelRetry()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if self.isTapInstalled { self.cancelRetry(); onSuccess(); return }
                if AXIsProcessTrusted(), self.start() {
                    Log.event("event tap installed after Accessibility grant")
                    self.cancelRetry(); onSuccess()
                }
            }
        }
    }

    /// Stop the trust-polling loop started by retryUntilTrusted.
    func cancelRetry() {
        retryTimer?.invalidate(); retryTimer = nil
    }

    // Nudge a disabled tap back to life without caller intervention.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureActive() }
        }
    }

    // Builds the Cocoa key string on the main thread, off the tap thread.
    // Guard tap != nil: both this method and stop() are @MainActor, so the check
    // is race-correct. If stop() ran before this async hop landed, discard the key
    // rather than delivering it to an already-torn-down handler.
    fileprivate func deliverPhysicalKey(keyCode: Int, characters: String?, flags: UInt64) {
        guard tap != nil else { return }
        onPhysicalKey?(keyCode, characters, flags)
    }

    fileprivate func reenableFromCallback() {
        ensureActive()
    }
}

// Top-level C callback. A CGEventTapCallBack is a bare C function pointer: it can't
// capture context, so the InputFilter is recovered from `refcon`. Only cheap field
// reads happen here; any Cocoa work is hopped to main.
private let callback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let unmanaged = Unmanaged<InputFilter>.fromOpaque(refcon)

    // The system disables the tap on timeout or under input load. Re-enable and let the
    // notification event pass through untouched (do not return nil for these types).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { unmanaged.takeUnretainedValue().reenableFromCallback() }
        return Unmanaged.passUnretained(event)
    }

    // Cheap read only. Physical hardware reports sourceStateID == 1.
    let physical = event.getIntegerValueField(.eventSourceStateID) == InputFilter.physicalStateIDValue
    guard physical else {
        return Unmanaged.passUnretained(event)   // remote / injected input: pass through
    }

    // Physical input: block it from apps. Route key-downs to the password box, resolving
    // the unicode cheaply on the tap thread and hopping value types to main.
    if type == .keyDown {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        let chars = length > 0 ? String(utf16CodeUnits: buffer, count: length) : nil
        // Cheap modifier read on the tap thread; a plain UInt64 crosses to main safely.
        let flags = event.flags.rawValue
        DispatchQueue.main.async {
            unmanaged.takeUnretainedValue().deliverPhysicalKey(keyCode: keyCode, characters: chars, flags: flags)
        }
    }
    return nil
}

extension InputFilter {
    // Both constants live here (nonisolated context) so the C-callback can read them
    // without crossing actor isolation. physicalStateID is the single source of truth;
    // physicalStateIDValue is the name exposed at the call site in the callback.
    fileprivate static let physicalStateID: Int64 = 1
    fileprivate nonisolated static var physicalStateIDValue: Int64 { physicalStateID }
}
