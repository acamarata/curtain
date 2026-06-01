import Foundation

/// Purpose: A composable set of lifecycle actions. Each phase (start / idle / end)
///          maps to an ActionSet; the runner performs only the enabled actions.
///          Keeping actions independent and data-driven means new behaviors are a
///          field here, not a branch scattered across the app.
/// SPORT: MASTER-ACTIONS
struct ActionSet {
    var activateCurtain = false
    var disconnect = false
    var lock = false
    var screenOff = false
    var deactivateCurtain = false
}

/// Performs an ActionSet against the live curtain + system. Ordering is deliberate:
/// disconnect the operator first, deactivate/cover the screen, then lock, then sleep
/// displays last (so the lock is in place before the panels go dark).
struct ActionRunner {
    let curtain: CurtainController
    let input: InputFilter

    func run(_ set: ActionSet) {
        if set.activateCurtain { activateCover() }
        if set.disconnect { System.endScreenShareSession() }
        if set.deactivateCurtain { deactivateCover() }
        if set.lock { System.lockScreen() }
        if set.screenOff {
            // Give the lock a beat to take hold before the displays sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { System.sleepDisplays() }
        }
    }

    func activateCover() {
        guard !curtain.isShown else { return }
        curtain.show()
        System.preventDisplaySleep()
        _ = input.start()           // no-op result: cover still hides even without Accessibility
    }

    func deactivateCover() {
        input.stop()
        curtain.hide()
        System.allowDisplaySleep()
    }
}
