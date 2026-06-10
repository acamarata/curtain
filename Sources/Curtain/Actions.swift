import Foundation

/// Purpose: A composable set of lifecycle actions. Each phase (start / idle / end)
///          maps to an ActionSet built from Settings; the runner performs only the
///          enabled actions. Keeping actions independent and data-driven means a new
///          behavior is a field here, not a branch scattered across the app.
/// Inputs: five booleans, all defaulting off so an empty set is a safe no-op.
/// Outputs: none (the runner mutates live curtain + system state).
/// Constraints: stored property names (disconnect, lock, screenOff,
///          deactivateCurtain, activateCurtain) are part of the contract with
///          Settings.onIdle / Settings.onEnd — do not rename them.
/// SPORT: MASTER-ACTIONS
struct ActionSet {
    var activateCurtain = false
    var disconnect = false
    var lock = false
    var screenOff = false
    var deactivateCurtain = false
}

/// Purpose: Perform an ActionSet against the live curtain + system. Ownership of
///          the cover lifecycle (show/hide, input tap, display-sleep assertion)
///          lives here so the coordinator stays a pure state machine.
/// Inputs: a CurtainController and an InputFilter, both owned by the coordinator.
/// Outputs: none.
/// Constraints: ordering matters for privacy. The remote must never see a bare
///          desktop frame, so when a set both reveals and disconnects, the
///          disconnect/lock run BEFORE the cover comes down. The screen-off step is
///          a cancelable work item: any new activate/deactivate/run cancels a
///          pending sleep so a stale timer can't black out a screen we just brought
///          back. Contradictory sets (activate + deactivate together) are rejected.
/// SPORT: MASTER-ACTIONS
@MainActor
final class ActionRunner {
    let curtain: CurtainController
    let input: InputFilter

    /// Pending displays-off work, held so it can be canceled if state changes first.
    private var pendingScreenOff: DispatchWorkItem?

    init(curtain: CurtainController, input: InputFilter) {
        self.curtain = curtain
        self.input = input
    }

    // MARK: - Cover lifecycle

    /// Bring the cover up: windows, display-sleep assertion, and the input tap.
    /// If the tap can't install yet (Accessibility not granted), the cover still
    /// hides the desktop visually; we leave input unblocked and retry the tap in the
    /// background, flipping the cover's input-blocked state once the grant lands.
    func activateCover() {
        cancelPendingScreenOff()
        guard !curtain.isShown else { return }
        curtain.show()
        System.preventDisplaySleep()
        if input.start() {
            curtain.setInputBlocked(true)
        } else {
            curtain.setInputBlocked(false)
            input.retryUntilTrusted { [weak curtain] in curtain?.setInputBlocked(true) }
        }
    }

    /// Take the cover down: stop any pending tap retry, tear down the tap, hide the
    /// windows, and release the display-sleep assertion.
    func deactivateCover() {
        cancelPendingScreenOff()
        input.cancelRetry()
        input.stop()
        curtain.hide()
        System.allowDisplaySleep()
    }

    // MARK: - Set execution

    func run(_ set: ActionSet) {
        cancelPendingScreenOff()

        // A set can't both reveal and conceal; honoring deactivate here would race
        // the cover we were just asked to raise. Keep the cover, drop the reveal.
        var set = set
        if set.activateCurtain && set.deactivateCurtain {
            NSLog("Curtain: contradictory ActionSet (activate + deactivate) — skipping deactivate")
            set.deactivateCurtain = false
        }

        // Privacy ordering: raise the cover first if asked, then sever the remote
        // and lock while still covered, and only then reveal the desktop. The
        // remote never sees an uncovered frame.
        if set.activateCurtain { activateCover() }
        if set.disconnect { System.endScreenShareSession() }
        if set.lock { System.lockScreen() }
        if set.deactivateCurtain { deactivateCover() }
        if set.screenOff { scheduleScreenOff() }
    }

    // MARK: - Cancelable screen-off

    /// Sleep the displays after a short beat so a lock has time to take hold first.
    /// Held as a work item so a later state change can cancel it.
    private func scheduleScreenOff() {
        let work = DispatchWorkItem { System.sleepDisplays() }
        pendingScreenOff = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func cancelPendingScreenOff() {
        pendingScreenOff?.cancel()
        pendingScreenOff = nil
    }
}
