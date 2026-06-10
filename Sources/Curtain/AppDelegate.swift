import Cocoa

/// Purpose: App entry orchestration. Owns the coordinator, the optional menu bar,
///          the settings window, and the onboarding window. Keeps logic out of the
///          UI: it just wires callbacks between the pieces and drives cleanup on quit.
/// Inputs: NSApplicationDelegate lifecycle callbacks; Settings/UserDefaults state.
/// Outputs: A running agent with menu bar, settings, and (first run) onboarding wired.
/// Constraints: @MainActor — owns AppKit objects and SessionCoordinator (itself @MainActor).
///              cleanup() must be idempotent: it runs on quit, on SIGTERM, and on terminate.
/// SPORT: MASTER-APP
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SessionCoordinator()
    lazy var menuBar = MenuBarController(coordinator: coordinator)
    lazy var prefs = PreferencesWindowController(coordinator: coordinator)
    lazy var onboarding = OnboardingWindowController(coordinator: coordinator)

    func applicationDidFinishLaunching(_ n: Notification) {
        Settings.registerDefaults()
        Notifier.requestAuthorization()
        System.startupLockProbe()

        coordinator.onStateChange = { [weak self] active in self?.menuBar.reflect(active: active) }
        coordinator.onArmedChange = { [weak self] armed in self?.menuBar.reflect(armed: armed) }
        coordinator.start()

        // Reconcile the optional privileged disconnect helper with its saved setting.
        DisconnectClient.shared.syncWithSettings()

        menuBar.onOpenSettings = { [weak self] in self?.prefs.show() }
        menuBar.onOpenSetup = { [weak self] in self?.onboarding.show() }
        menuBar.onQuit = { [weak self] in self?.quit() }
        if Settings.showInMenuBar { menuBar.show() }

        prefs.onMenuBarToggle = { [weak self] on in on ? self?.menuBar.show() : self?.menuBar.hide() }
        prefs.openOnboarding = { [weak self] in self?.onboarding.show() }

        // First run drives the Accessibility grant and password setup via onboarding.
        // After onboarding, fall back to settings only if there's nothing to find the app by.
        if !Settings.hasOnboarded {
            onboarding.show()
        } else if !Settings.showInMenuBar && !Settings.hasPassword {
            prefs.show()
        }

        // Reconcile the login-item state with the saved preference.
        LoginItem.set(Settings.launchAtLogin)

        // Soft, non-prompting check once onboarding has happened — onboarding/Settings
        // surface any warning, so there's nothing to do here but note the state.
        if Settings.hasOnboarded { _ = AXIsProcessTrusted() }
    }

    /// Re-opening the app from Finder shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        prefs.show(); return true
    }

    func applicationWillTerminate(_ notification: Notification) { cleanup() }

    /// Idempotent teardown: drop the curtain and release input/display assertions.
    /// Called on user quit, on SIGTERM (launchd / `kill`), and on app termination.
    func cleanup() { coordinator.deactivateNowForQuit() }

    private func quit() { cleanup(); NSApp.terminate(nil) }
}
