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

    // MARK: - Re-enable circuit breaker (T-P1-E08-04)
    //
    // Both the 1Hz watchdog and the tap-thread callback funnel into ensureActive()
    // whenever the system reports the tap disabled. Left uncapped, a pathological
    // state (a misbehaving app hammering the event system, or a genuine OS-level
    // fault) makes Curtain re-enable forever with zero user-visible signal — the
    // privacy cover could be silently degraded for an entire session.
    //
    // Threshold: 5 re-enables within a rolling 10-second window. Reasoning: the
    // watchdog alone can contribute at most ~10 ticks in that window (1Hz), and the
    // callback path fires independently of the watchdog, so 5 genuine re-enables
    // within 10s is already well beyond an isolated timeout/user-input flap (which
    // the system triggers rarely and which self-resolves in one re-enable) and
    // reliably indicates a persistent, repeating fault rather than normal noise.
    private static let circuitBreakerThreshold = 5
    private static let circuitBreakerWindow: TimeInterval = 10.0
    // An isolated flap (well below threshold) should not permanently poison the
    // counter across an otherwise-healthy multi-hour session. Once the tap has
    // needed no re-enable for this long, treat the prior flap(s) as resolved and
    // reset the counter back to a clean slate.
    private static let circuitBreakerStableResetInterval: TimeInterval = 30.0

    /// Count of genuine re-enables (tap found disabled, then re-enabled) since
    /// `reenableWindowStart`. Only incremented when `ensureActive()` actually found
    /// the tap disabled — normal watchdog ticks where the tap is already enabled
    /// never touch this.
    private var reenableCount = 0
    /// Start of the current rolling window; reset whenever a re-enable happens after
    /// the window has expired, so the count only reflects the trailing `circuitBreakerWindow`.
    private var reenableWindowStart: Date?
    /// Timestamp of the most recent genuine re-enable; used to detect the stable
    /// period that clears the breaker after a resolved flap.
    private var lastReenableAt: Date?
    /// True once the threshold has been exceeded and the degraded-state notification
    /// has fired. Prevents re-notifying on every subsequent tick while still tripped.
    private var circuitBreakerTripped = false

    /// Fired on the main thread for every physical key-down: (keycode, characters,
    /// modifier-flags raw value). The flags let the controller match a reveal combo.
    var onPhysicalKey: ((Int, String?, UInt64) -> Void)?

    /// True once a tap is live. Coordinator shows an "Accessibility needed" warning
    /// when this stays false after start().
    var isTapInstalled: Bool { tap != nil }

    // Test-injection point (additive, always compiled in — never #if DEBUG, so
    // release behavior can never diverge from what tests exercise). A real CGEventTap
    // cannot be created headlessly in CI, so InputFilterTests drives the two
    // disabled-tap recovery branches directly through `simulateTapDisabled(_:)` below
    // instead of the C callback, and observes the re-arm via this counter rather than
    // a real tap re-enabling. Incremented by `reenableFromCallback()` on every call;
    // production code never reads it.
    private(set) var reenableInvocationCount = 0

    // physicalStateID lives in the nonisolated extension below so the C-callback
    // can reach it without an actor hop. See InputFilter extension at end of file.

    /// Install the tap on the main run loop. Returns false if the tap could not be
    /// created (missing Accessibility), so the caller can prompt or retry.
    @discardableResult
    func start() -> Bool {
        assert(Thread.isMainThread, "InputFilter.start() must run on the main thread")
        if tap != nil { return true }

        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .scrollWheel
        ]
        // CGEventType has no .systemDefined case, but the underlying tap accepts its raw
        // value (14 == NX_SYSDEFINED). Including it blocks physical media / brightness /
        // volume / Mission-Control keys too. Some lower-level HID paths can still bypass a
        // session tap; that residual is accepted.
        let systemDefinedMask: CGEventMask = CGEventMask(1) << 14
        let mask: CGEventMask = types.reduce(systemDefinedMask) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard
            let t = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: me)
        else {
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
        // A future start() begins a fresh tap lifetime; don't carry a trip/count from
        // the torn-down one into it.
        reenableCount = 0
        reenableWindowStart = nil
        lastReenableAt = nil
        circuitBreakerTripped = false
    }

    /// Re-enable the tap if the system disabled it (timeout / heavy input). Safe to call
    /// repeatedly; backs the watchdog and any coordinator-driven retry. Once the
    /// circuit breaker has tripped (see the threshold constants above), this stops
    /// calling `CGEvent.tapEnable` — see the trip site below for why "stop entirely"
    /// was chosen over a slower backoff.
    func ensureActive() {
        guard let t = tap else { return }
        maybeResetCircuitBreaker()
        guard !circuitBreakerTripped else { return }
        if !CGEvent.tapIsEnabled(tap: t) {
            recordReenableAttempt()
            CGEvent.tapEnable(tap: t, enable: true)
        }
    }

    /// Record one genuine re-enable (tap was actually found disabled) against the
    /// rolling window, and trip the breaker if the threshold is exceeded within it.
    private func recordReenableAttempt() {
        let now = Date()
        if let windowStart = reenableWindowStart, now.timeIntervalSince(windowStart) <= Self.circuitBreakerWindow {
            reenableCount += 1
        } else {
            // First re-enable, or the previous window already expired: start fresh.
            reenableWindowStart = now
            reenableCount = 1
        }
        lastReenableAt = now

        if reenableCount >= Self.circuitBreakerThreshold, !circuitBreakerTripped {
            tripCircuitBreaker()
        }
    }

    /// If the tap has gone `circuitBreakerStableResetInterval` without needing a
    /// re-enable, treat any prior flap as resolved: clear the count/window so it
    /// doesn't keep contributing toward a future trip, and un-trip the breaker so
    /// normal retry resumes after a genuinely stable period. Called at the top of
    /// every `ensureActive()` (watchdog-driven or callback-driven) so the reset is
    /// checked on the same 1Hz-or-faster cadence the breaker itself uses.
    private func maybeResetCircuitBreaker() {
        guard let last = lastReenableAt else { return }
        guard Date().timeIntervalSince(last) >= Self.circuitBreakerStableResetInterval else { return }
        reenableCount = 0
        reenableWindowStart = nil
        lastReenableAt = nil
        if circuitBreakerTripped {
            circuitBreakerTripped = false
            Log.event("InputFilter: circuit breaker reset after \(Int(Self.circuitBreakerStableResetInterval))s stable")
        }
    }

    /// Threshold exceeded: stop blind infinite retry and surface a degraded-state
    /// signal. Choice made here — stop entirely rather than a slower backoff — because
    /// a tap that needed 5 re-enables in 10s is exhibiting a persistent, repeating
    /// fault (not an isolated timeout), and continuing to hammer `CGEvent.tapEnable`
    /// against whatever is causing that adds no value and risks masking the real
    /// problem behind an appearance of "still trying." Recovery resumes automatically
    /// once `maybeResetCircuitBreaker()` observes a stable period (see above) — no
    /// separate manual "retry" action is implemented, since the same watchdog tick
    /// that would drive a manual retry already re-checks and clears the breaker for
    /// free once the underlying condition actually clears.
    private func tripCircuitBreaker() {
        circuitBreakerTripped = true
        Log.error(
            "InputFilter: event tap re-enable circuit breaker tripped — \(reenableCount) re-enables within \(Int(Self.circuitBreakerWindow))s; pausing retry until stable"
        )
        Notifier.post(
            title: "Curtain",
            body:
                "Curtain's privacy cover input blocking is degraded — the system keeps disabling it. Physical input may reach the desk. Try relaunching Curtain if this persists.",
            throttleKey: "input-tap-circuit-breaker",
            throttleSeconds: Self.circuitBreakerWindow
        )
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

    /// True while a `retryUntilTrusted` poll loop is pending. Test-only observability
    /// for `cancelRetry()` regression coverage (asserts the loop actually stops rather
    /// than just not crashing); production code has no need to read this.
    var isRetryPending: Bool { retryTimer != nil }

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
        reenableInvocationCount += 1
        ensureActive()
    }

    /// Test-injection point: reproduces the C callback's `.tapDisabledByTimeout` /
    /// `.tapDisabledByUserInput` branch (see `callback` below) without needing a real
    /// CGEventTap or CGEvent. Production code never calls this — the real callback
    /// still runs its own copy of this branch inline, since a CGEventTapCallBack is a
    /// bare C function pointer and can't call back into a non-`@convention(c)` method.
    /// Kept as a 1:1 mirror of the callback's dispatch so a regression test here is
    /// meaningful for what actually runs on the tap thread.
    func simulateTapDisabled(_ type: CGEventType) {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return }
        reenableFromCallback()
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
        return Unmanaged.passUnretained(event)  // remote / injected input: pass through
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
