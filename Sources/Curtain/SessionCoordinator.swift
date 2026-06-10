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
/// SPORT: MASTER-COORDINATOR
@MainActor
final class SessionCoordinator {

    /// Curtain active? Drives the menu-bar icon.
    var onStateChange: ((Bool) -> Void)?
    /// Armed? Drives the menu's arm/disarm item.
    var onArmedChange: ((Bool) -> Void)?

    let curtain = CurtainController()
    let input = InputFilter()
    private let monitor = SessionMonitor()
    private lazy var runner = ActionRunner(curtain: curtain, input: input)

    private var tickTimer: Timer?

    /// Always-available escape hatch — deactivates without Accessibility. See start().
    private var emergencyHotkey: EmergencyHotkey?

    /// Pending connect grace; canceled if the session drops before it elapses.
    private var connectGrace: DispatchWorkItem?
    /// Pending test-curtain teardown; canceled if a real session connects mid-test.
    private var testTeardown: DispatchWorkItem?

    /// Explicit lifecycle state. Every transition is guarded so it stays idempotent.
    private enum State { case idle, active }
    private var state: State = .idle

    // MARK: - Setup

    func start() {
        input.onPhysicalKey = { [weak self] kc, chars, flags in self?.curtain.physicalKey(kc, chars, flags) }
        curtain.onUnlock = { [weak self] in self?.handlePasswordUnlock() }

        monitor.onConnect = { [weak self] in self?.sessionConnected() }
        monitor.onIdleTimeout = { [weak self] in self?.sessionIdled() }
        monitor.onDisconnect = { [weak self] in self?.sessionEnded() }
        monitor.start()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.curtain.tick() }
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
            body: "Grant Accessibility to Curtain to use the privacy cover. System Settings > Privacy & Security > Accessibility.",
            throttleKey: "accessibility-needed",
            throttleSeconds: 60
        )
    }

    private func postNotification(title: String, body: String) {
        Notifier.post(title: title, body: body)
    }

    // MARK: - Monitor events (gated by armed)

    private func sessionConnected() {
        guard Settings.armed else { return }
        // A real session wins over any in-flight test: keep whatever is on screen.
        testTeardown?.cancel(); testTeardown = nil
        guard Settings.onStartActivate else { return }

        // Grace window: a brief, flaky connection shouldn't flash the cover up.
        connectGrace?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connectGrace = nil
            // Re-check armed: the user may have disarmed while the work item was
            // already executing (past the point where cancel() could stop it).
            guard Settings.armed else { return }
            self?.enterActive(notify: true)
        }
        connectGrace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(Settings.connectGraceSeconds), execute: work)
    }

    private func sessionIdled() {
        guard Settings.armed, state == .active else { return }
        Log.event("running idle actions")
        applySet(Settings.onIdle)
    }

    private func sessionEnded() {
        guard Settings.armed else { return }
        // If the session never made it past grace, just drop the pending activate.
        connectGrace?.cancel(); connectGrace = nil
        guard state == .active else { return }
        Log.event("running end actions")
        applySet(Settings.onEnd)
    }

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
        Log.event("activate requested")
        if requireAX, !AXIsProcessTrusted() {
            Log.event("activation refused: Accessibility not granted")
            NSLog("Curtain: refusing to cover — Accessibility not granted (would trap the desk)")
            notifyAccessibilityNeeded()
            return
        }
        state = .active
        runner.activateCover()
        Log.event("cover activated")
        onStateChange?(true)
        if notify { announceActivation() }
    }

    /// Take the cover down and move to .idle. No-op if already idle.
    private func enterIdle() {
        guard state == .active else { return }
        state = .idle
        runner.deactivateCover()
        onStateChange?(false)
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
        Log.event("password accepted; unlockDisconnect=\(Settings.unlockDisconnect)")
        if Settings.unlockDisconnect {
            System.endScreenShareSession()
        }
        enterIdle()
    }

    // MARK: - Manual controls

    func activateNow() {
        connectGrace?.cancel(); connectGrace = nil
        enterActive(notify: false)
    }

    /// Force the cover down with no password gate. Used internally and on quit.
    func deactivateNow() {
        connectGrace?.cancel(); connectGrace = nil
        testTeardown?.cancel(); testTeardown = nil
        enterIdle()
    }

    /// Menu-driven deactivate. If the setting requires a password and the cover is
    /// up, refuse to deactivate, surface the on-curtain password box, and report
    /// false. Otherwise deactivate and report true.
    @discardableResult
    func requestDeactivateFromMenu() -> Bool {
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

    var isActive: Bool { state == .active }
    var isArmed: Bool { Settings.armed }

    /// Persist the armed flag. Disarming forces the cover down immediately so the
    /// Mac is never left covered by a system the user just turned off. When the
    /// user chose "Refuse to arm" for missing Accessibility, arming is rejected
    /// outright (with a notification) rather than arming a system that could only
    /// warn at connect time — the cover would refuse to rise anyway.
    func setArmed(_ on: Bool) {
        if on, Settings.accessibilityRefuseToArm, !AXIsProcessTrusted() {
            Log.event("arming refused: Accessibility not granted (refuseToArm)")
            Notifier.post(title: "Curtain",
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
    func testCurtain(seconds: TimeInterval) {
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
    func enableDisconnectHelper(_ on: Bool) {
        // Settings exposes this flag read-only; persist via the shared defaults key.
        UserDefaults.standard.set(on, forKey: Settings.Key.disconnectFeatureEnabled)
        DisconnectClient.shared.setEnabled(on)
        DisconnectClient.shared.syncWithSettings()
    }

    /// Cleanup path for app termination: drop the cover and release the assertion.
    /// runner.deactivateCover() already releases the IOKit display-sleep assertion,
    /// so a second direct call to System.allowDisplaySleep() here is redundant and
    /// was removed to keep the release path in exactly one place.
    func deactivateNowForQuit() {
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
