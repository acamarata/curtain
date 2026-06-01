import Cocoa

/// Purpose: The brain. Wires the session monitor, curtain, input filter, and the
///          configurable lifecycle actions together. Owns the connect / idle / end
///          flow described in the README. Holds no UI.
/// SPORT: MASTER-COORDINATOR
final class SessionCoordinator {
    let curtain = CurtainController()
    let input = InputFilter()
    private let monitor = SessionMonitor()
    private lazy var runner = ActionRunner(curtain: curtain, input: input)
    private var tickTimer: Timer?

    /// Called when the curtain's active state changes (for the menu-bar icon).
    var onStateChange: ((Bool) -> Void)?

    func start() {
        input.onPhysicalKey = { [weak self] kc, chars in self?.curtain.physicalKey(kc, chars) }
        curtain.onUnlock = { [weak self] in self?.handlePasswordUnlock() }

        monitor.onConnect = { [weak self] in self?.sessionStarted() }
        monitor.onIdleTimeout = { [weak self] in self?.sessionIdled() }
        monitor.onDisconnect = { [weak self] in self?.sessionEnded() }
        monitor.start()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.curtain.tick()
        }
    }

    // MARK: - Lifecycle

    private func sessionStarted() {
        guard Settings.onStartActivate else { return }
        runner.activateCover()
        onStateChange?(true)
    }

    private func sessionIdled() {
        runner.run(Settings.onIdle)
        onStateChange?(curtain.isShown)
    }

    private func sessionEnded() {
        runner.run(Settings.onEnd)
        onStateChange?(curtain.isShown)
    }

    /// Host typed the correct password at the desk.
    private func handlePasswordUnlock() {
        runner.deactivateCover()
        onStateChange?(false)
        if Settings.onPasswordDisconnect {
            let alert = NSAlert()
            alert.messageText = "Unlocked at this Mac"
            alert.informativeText = "Disconnect the active remote session?"
            alert.addButton(withTitle: "Disconnect Remote")
            alert.addButton(withTitle: "Keep Connected")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { System.endScreenShareSession() }
        }
    }

    // MARK: - Manual controls (menu bar / settings)

    func activateNow() { runner.activateCover(); onStateChange?(true) }
    func deactivateNow() { runner.deactivateCover(); onStateChange?(false) }
    var isActive: Bool { curtain.isShown }

    func testCurtain(seconds: TimeInterval = 10) {
        runner.activateCover(); onStateChange?(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.runner.deactivateCover(); self?.onStateChange?(false)
        }
    }
}
