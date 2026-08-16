import Cocoa
import os.log

/// Purpose: The brain. Wires the session monitor, curtain, input filter, and the
///          configurable lifecycle actions together, and runs the connect / idle /
///          end / password flow as an explicit, idempotent state machine. Holds no
///          UI of its own — it owns AppKit objects and publishes state changes.
/// Inputs: none at construction; behavior is driven entirely by Settings + the
///          monitor callbacks.
/// Outputs: onStateChange (curtain active?) and onArmedChange (armed?) for the menu.
/// Constraints: @MainActor — it owns AppKit objects and the monitor callbacks
///          already hop to main. Every public transition is idempotent: a
///          double-activate, a deactivate-while-idle, or a reconnect-while-active
///          must never double-run lock/sleep or leave the tap dangling. The
///          password-unlock path disconnects the remote BEFORE revealing the
///          desktop, and never blocks the runloop with a modal (that would freeze
///          the event tap). When disarmed it stays passive and ignores the monitor.
///          `public` because the thin `Curtain` executable (AppDelegate,
///          MenuBarController, PreferencesWindow, OnboardingWindow) constructs and
///          drives this type across the CurtainCore module boundary. Security/
///          reliability-relevant refusals (Accessibility missing on activate/arm)
///          log via Log.error (always visible), not the diagnostics-gated
///          Log.event. This session's SessionMonitor-issued episode correlation ID
///          (see SessionMonitor.currentEpisodeID) is mirrored into
///          `currentEpisodeID` on connect and tagged onto this session's
///          connect/idle/end/unlock log lines; InputFilter's tap-install logs stay
///          untagged since they are process-lifetime events, not per-session ones.
///          CurtainHelper (a separate process reached only via XPC) does not
///          receive this token — see DisconnectClient.swift's callHelper() doc
///          comment for that documented limitation.
/// SPORT: MASTER-COORDINATOR
@MainActor
public final class SessionCoordinator {

    /// Curtain active? Drives the menu-bar icon.
    public var onStateChange: ((Bool) -> Void)?
    /// Armed? Drives the menu's arm/disarm item.
    public var onArmedChange: ((Bool) -> Void)?

    let curtain = CurtainController()
    let input = InputFilter()
    private let monitor = SessionMonitor()
    private lazy var runner: ActionRunning = ActionRunner(curtain: curtain, input: input)

    private var tickTimer: Timer?

    /// Always-available escape hatch — deactivates without Accessibility. See start().
    private var emergencyHotkey: EmergencyHotkey?

    /// Pending connect grace; canceled if the session drops before it elapses.
    private var connectGrace: DispatchWorkItem?
    /// Pending test-curtain teardown; canceled if a real session connects mid-test.
    private var testTeardown: DispatchWorkItem?

    /// Correlation token for the in-progress session, mirrored from
    /// `SessionMonitor.currentEpisodeID` via the `onConnect(episodeID:)` callback so
    /// the coordinator's own connect/idle/end/unlock log lines can carry it without
    /// reaching back into the monitor on every call. `nil` while idle/disarmed, or
    /// when driven by `simulateConnect()` without going through a real monitor.
    private var currentEpisodeID: String?

    /// Explicit lifecycle state. Every transition is guarded so it stays idempotent.
    private enum State { case idle, active }
    private var state: State = .idle

    /// Test-injection point: gates `enterActive(requireAX:)` and `setArmed`'s
    /// accessibilityRefuseToArm check, and (T-P1-E10-02) the mid-session re-check
    /// below. Defaults to the real API so production behavior is unchanged;
    /// SessionCoordinatorTests overrides it to drive the AX-trust branches
    /// deterministically without touching real Accessibility state.
    var isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }

    /// Edge-trigger latch for the mid-session Accessibility re-check (T-P1-E10-02):
    /// `setInputBlocked`/`Log.event` must fire only on an actual true<->false
    /// transition, not on every tick — mirrors SessionMonitor's `lastSignals`
    /// change-detection pattern. `nil` while idle (no re-check has run yet this
    /// session); set to the current trust state on the first re-check after
    /// entering `.active`, then compared against on every subsequent tick.
    private var lastKnownAXTrusted: Bool?

    public init() {}

    /// Test-only designated init: lets SessionCoordinatorTests inject a spy
    /// `ActionRunning` in place of the real `ActionRunner`, so idempotency tests can
    /// assert action-invocation counts instead of only end state. Never called from
    /// production code (AppDelegate.swift uses the zero-arg `init()` above, which this
    /// keeps working unchanged).
    init(runner: ActionRunning) {
        self.runner = runner
    }

    // MARK: - Setup

    public func start() {
        input.onPhysicalKey = { [weak self] kc, chars, flags in self?.curtain.physicalKey(kc, chars, flags) }
        curtain.onUnlock = { [weak self] in self?.handlePasswordUnlock() }

        monitor.onConnect = { [weak self] episodeID in self?.sessionConnected(episodeID: episodeID) }
        monitor.onIdleTimeout = { [weak self] in self?.sessionIdled() }
        monitor.onDisconnect = { [weak self] in self?.sessionEnded() }
        monitor.start()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.curtain.tick()
                self?.recheckAccessibilityIfActive()
            }
        }

        // Reflect the persisted disconnect-helper setting into the System handler hook.
        enableDisconnectHelper(Settings.disconnectFeatureEnabled)

        // Always-on emergency escape. Carbon RegisterEventHotKey needs no Accessibility,
        // so Control+Option+Command+U force-deactivates even if the tap never installed.
        let hotkey = EmergencyHotkey()
        hotkey.register { [weak self] in
            Log.event("emergency hotkey: force deactivate")
            self?.deactivateNow()
            self?.postNotification(title: "Curtain", body: "Curtain deactivated (emergency hotkey).")
        }
        emergencyHotkey = hotkey
    }

    // MARK: - User notifications

    /// Throttled (~60s) prompt shown when an activation is refused because Accessibility
    /// isn't granted. Without the tap the cover can't be unlocked at the desk.
    private func notifyAccessibilityNeeded() {
        Notifier.post(
            title: "Curtain",
            body:
                "Grant Accessibility to Curtain to use the privacy cover. System Settings > Privacy & Security > Accessibility.",
            throttleKey: "accessibility-needed",
            throttleSeconds: 60
        )
    }

    private func postNotification(title: String, body: String) {
        Notifier.post(title: title, body: body)
    }

    // MARK: - Monitor events (gated by armed)

    /// `episodeID` is the correlation token SessionMonitor generated for this
    /// connect (nil when driven via `simulateConnect()` with no token supplied).
    /// Stored on `self` so the rest of this session's lifecycle (idle/end/unlock)
    /// logs under the same token even though those callbacks carry no parameter.
    private func sessionConnected(episodeID: String? = nil) {
        currentEpisodeID = episodeID
        guard Settings.armed else { return }
        // A real session wins over any in-flight test: keep whatever is on screen.
        testTeardown?.cancel(); testTeardown = nil
        guard Settings.onStartActivate else { return }

        // Grace window: a brief, flaky connection shouldn't flash the cover up.
        connectGrace?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connectGrace = nil
            // Re-check armed and onStartActivate: the user may have disarmed or
            // flipped the setting off while the work item was already executing
            // (past the point where cancel() could stop it).
            guard Settings.armed, Settings.onStartActivate else { return }
            self?.enterActive(notify: true)
        }
        connectGrace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(Settings.connectGraceSeconds), execute: work)
    }

    private func sessionIdled() {
        guard Settings.armed, state == .active else { return }
        Log.event("running idle actions", episode: currentEpisodeID)
        applySet(Settings.onIdle)
    }

    private func sessionEnded() {
        guard Settings.armed else { return }
        // If the session never made it past grace, just drop the pending activate.
        connectGrace?.cancel(); connectGrace = nil
        guard state == .active else {
            currentEpisodeID = nil
            return
        }
        Log.event("running end actions", episode: currentEpisodeID)
        applySet(Settings.onEnd)
        currentEpisodeID = nil
    }

    // MARK: - Test-injection entry points
    //
    // SessionMonitor is `final` and polls real CoreGraphics/shell signals, so it can't
    // be faked in-process. These thin wrappers call the exact same private handlers
    // `start()` wires to `monitor.onConnect`/`onIdleTimeout`/`onDisconnect`, letting
    // SessionCoordinatorTests drive the state machine deterministically without a real
    // SessionMonitor or CaptureProbe. Production code never calls these — `start()`'s
    // monitor callbacks call the private handlers directly.

    /// Drives the same path as a real `monitor.onConnect` firing. No real
    /// SessionMonitor is involved, so there is no real episode ID to pass —
    /// `currentEpisodeID` stays nil for simulated sessions, which is fine since
    /// tests assert on action invocation counts/state, not log output.
    func simulateConnect() { sessionConnected() }

    /// Drives the same path as a real `monitor.onIdleTimeout` firing.
    func simulateIdle() { sessionIdled() }

    /// Drives the same path as a real `monitor.onDisconnect` firing.
    func simulateDisconnect() { sessionEnded() }

    /// Drives the same path as a real `curtain.onUnlock` firing (correct password
    /// typed at the desk). Exercises the real `handlePasswordUnlock()`, including its
    /// load-bearing ordering (disconnect before reveal) — see that method's doc
    /// comment. `System.endScreenShareSession()` is safe to call in tests: with no
    /// `System.disconnectHandler` registered (the test-process default) it only logs
    /// and returns, so no real screen-share teardown happens.
    func simulatePasswordUnlock() { handlePasswordUnlock() }

    /// Drives the same path as one `tickTimer` firing's AX re-check half (T-P1-E10-02),
    /// without needing a real Timer or waiting a full second in tests.
    /// `SessionCoordinatorTests` uses this to simulate the true->false->true
    /// transition deterministically via the existing `isAccessibilityTrusted`
    /// injection seam.
    func simulateAXRecheckTick() { recheckAccessibilityIfActive() }

    // MARK: - State machine

    /// Raise the cover and move to .active. No-op if already active.
    ///
    /// `requireAX` gates indefinite activations (real session + "Activate Now") on
    /// Accessibility: without the event tap the cover both fails to block desk input
    /// AND can't be unlocked at the desk, so it must never be shown. The bounded
    /// `testCurtain(seconds:)` path passes `requireAX: false` — it auto-deactivates
    /// after its timeout, so it's a safe visual test even without AX.
    private func enterActive(notify: Bool, requireAX: Bool = true) {
        guard state == .idle else { return }
        Log.event("activate requested", episode: currentEpisodeID)
        if requireAX, !isAccessibilityTrusted() {
            // Always-visible: a refused activation means the desk is NOT covered
            // when the user/policy expected it to be — a security-relevant refusal,
            // not routine diagnostics. Log.error is unconditional, so the redundant
            // direct NSLog that used to duplicate this line has been removed.
            Log.error("activation refused: Accessibility not granted", episode: currentEpisodeID)
            notifyAccessibilityNeeded()
            return
        }
        state = .active
        runner.activateCover()
        Log.event("cover activated", episode: currentEpisodeID)
        onStateChange?(true)
        if notify { announceActivation() }
    }

    /// Take the cover down and move to .idle. No-op if already idle.
    private func enterIdle() {
        guard state == .active else { return }
        state = .idle
        runner.deactivateCover()
        onStateChange?(false)
        // Reset the mid-session re-check latch so the next activation starts with
        // a clean edge-trigger baseline rather than comparing against a stale
        // reading from a previous session.
        lastKnownAXTrusted = nil
    }

    /// Mid-session Accessibility re-verification (T-P1-E10-02). Piggybacks on the
    /// existing 1s `tickTimer` rather than starting a second competing Timer —
    /// `AXIsProcessTrusted()` is a fast TCC lookup, not expensive, so the same
    /// cadence used for the password-box auto-hide tick is fine here too. Gated to
    /// `state == .active`: the activation-time (`enterActive`) and arm-time
    /// (`setArmed`) gates already cover the not-yet-active cases, so there is
    /// nothing to re-verify while idle.
    ///
    /// Edge-triggered exactly like SessionMonitor's `signals != lastSignals` check:
    /// `curtain.setInputBlocked(_:)` (and the Log.event below) fire only on an
    /// actual transition, never on every tick, so a sustained revocation doesn't
    /// spam the log or repeatedly re-post the VoiceOver announcement in
    /// CoverContentView.setWarningVisible(true).
    private func recheckAccessibilityIfActive() {
        guard state == .active else { return }
        let trusted = isAccessibilityTrusted()
        defer { lastKnownAXTrusted = trusted }

        guard let previous = lastKnownAXTrusted, previous != trusted else { return }

        if !trusted {
            // Always-visible: matches enterActive()/setArmed()'s existing severity
            // discipline for Accessibility refusals — a live session losing its
            // input block is a security-relevant, not routine, event.
            Log.error("accessibility revoked mid-session: input blocking has stopped", episode: currentEpisodeID)
        } else {
            Log.event("accessibility re-granted mid-session: input blocking resumed", episode: currentEpisodeID)
        }
        // setInputBlocked(_:) already drives every active cover's warning banner
        // (CoverContentView.setWarningVisible) and its own "input-not-blocked
        // banner shown" log line — reuse it rather than reaching into
        // CurtainController's covers dictionary directly.
        curtain.setInputBlocked(trusted)
    }

    /// Run a configured set, then resync our state to whatever the cover ended at.
    /// This keeps idle/end actions (which may or may not deactivate) idempotent: if
    /// the set tears the cover down we land in .idle; if it leaves it up we stay
    /// .active so a later disconnect re-arms cleanly without double-running actions.
    private func applySet(_ set: ActionSet) {
        runner.run(set)
        state = curtain.isShown ? .active : .idle
        onStateChange?(curtain.isShown)
    }

    // MARK: - Password unlock (desk reveal)

    /// Host typed the correct password at the desk. Order is load-bearing: if the
    /// remote should be cut, sever it FIRST so the operator never sees the desktop,
    /// and only then drop the cover. No modal — that would freeze the runloop the
    /// event tap rides on.
    private func handlePasswordUnlock() {
        Log.event("password accepted; unlockDisconnect=\(Settings.unlockDisconnect)", episode: currentEpisodeID)
        if Settings.unlockDisconnect {
            System.endScreenShareSession()
        }
        enterIdle()
    }

    // MARK: - Manual controls

    public func activateNow() {
        connectGrace?.cancel(); connectGrace = nil
        enterActive(notify: false)
    }

    /// Force the cover down with no password gate. Used internally and on quit.
    public func deactivateNow() {
        connectGrace?.cancel(); connectGrace = nil
        testTeardown?.cancel(); testTeardown = nil
        enterIdle()
    }

    /// Menu-driven deactivate. If the setting requires a password and the cover is
    /// up, refuse to deactivate, surface the on-curtain password box, and report
    /// false. Otherwise deactivate and report true.
    @discardableResult
    public func requestDeactivateFromMenu() -> Bool {
        if Settings.requirePasswordToDeactivateFromMenu, state == .active, input.isTapInstalled {
            // Keep the cover up: the tap is live, so a physical keypress raises the
            // on-curtain password box — that is the intended unlock path. If the tap
            // is NOT installed (transient tap-create failure after the AX check), the
            // box can never receive keys, so refusing the menu here would strand the
            // desk with only the emergency hotkey; fall through and deactivate instead.
            return false
        }
        deactivateNow()
        return true
    }

    public var isActive: Bool { state == .active }
    public var isArmed: Bool { Settings.armed }

    /// Persist the armed flag. Disarming forces the cover down immediately so the
    /// Mac is never left covered by a system the user just turned off. When the
    /// user chose "Refuse to arm" for missing Accessibility, arming is rejected
    /// outright (with a notification) rather than arming a system that could only
    /// warn at connect time — the cover would refuse to rise anyway.
    public func setArmed(_ on: Bool) {
        if on, Settings.accessibilityRefuseToArm, !isAccessibilityTrusted() {
            // Always-visible: refusing to arm means the system will silently never
            // protect the desk, matching the enterActive() Accessibility-refusal
            // reclassification above — this is not part of an active session's
            // lifecycle, so no episode ID applies (arming is a standing config
            // action, not a per-connect event).
            Log.error("arming refused: Accessibility not granted (refuseToArm)")
            Notifier.post(
                title: "Curtain",
                body: "Not armed: grant Accessibility first (Settings > Security).")
            onArmedChange?(false)
            return
        }
        Log.event("armed=\(on)")
        Settings.armed = on
        onArmedChange?(on)
        if !on { deactivateNow() }
    }

    /// Briefly show the cover for a visual check. Cancelable, and a real connect
    /// during the window cancels the teardown so we don't tear down a live session.
    public func testCurtain(seconds: TimeInterval) {
        // Refuse to schedule a bounded test teardown while a REAL session has the
        // cover up — that would drop a live session's cover after the test delay.
        guard state == .idle else { return }
        testTeardown?.cancel()
        // Bounded + auto-deactivating, so it's safe to show even without Accessibility.
        enterActive(notify: false, requireAX: false)
        let work = DispatchWorkItem { [weak self] in
            self?.testTeardown = nil
            self?.enterIdle()
        }
        testTeardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Persist the disconnect-helper toggle and reconcile the privileged daemon.
    /// Registering/unregistering the LaunchDaemon and (re)installing the disconnect
    /// handler is delegated to DisconnectClient, which is idempotent and logs errors.
    public func enableDisconnectHelper(_ on: Bool) {
        // Settings exposes this flag read-only; persist via the shared defaults key.
        UserDefaults.standard.set(on, forKey: Settings.Key.disconnectFeatureEnabled)
        DisconnectClient.shared.setEnabled(on)
        DisconnectClient.shared.syncWithSettings()
    }

    /// Cleanup path for app termination: drop the cover and release the assertion.
    /// runner.deactivateCover() already releases the IOKit display-sleep assertion,
    /// so a second direct call to System.allowDisplaySleep() here is redundant and
    /// was removed to keep the release path in exactly one place.
    public func deactivateNowForQuit() {
        connectGrace?.cancel(); connectGrace = nil
        testTeardown?.cancel(); testTeardown = nil
        runner.deactivateCover()
        state = .idle
    }

    // MARK: - Activation feedback

    private func announceActivation() {
        if Settings.notifyOnActivate {
            os_log("Curtain active: desk covered, physical input blocked")
            // Surface a real banner via UNUserNotificationCenter so the user
            // (or a test harness) can observe the activation event in Notification
            // Center, not just the system log.
            Notifier.post(title: "Curtain", body: "Privacy curtain activated.")
        }
        if Settings.playSoundOnActivate {
            NSSound.beep()
        }
    }
}
