import Cocoa

/// Purpose: App entry orchestration. Owns the coordinator, the optional menu bar,
///          and the settings window. Keeps logic out of the UI: it just wires
///          callbacks between the pieces.
/// SPORT: MASTER-APP
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = SessionCoordinator()
    private lazy var menuBar = MenuBarController(coordinator: coordinator)
    private lazy var prefs = PreferencesWindowController(coordinator: coordinator)

    func applicationDidFinishLaunching(_ n: Notification) {
        Settings.registerDefaults()

        coordinator.onStateChange = { [weak self] active in self?.menuBar.reflect(active: active) }
        coordinator.start()

        menuBar.onOpenSettings = { [weak self] in self?.prefs.show() }
        menuBar.onQuit = { [weak self] in self?.quit() }
        if Settings.showInMenuBar { menuBar.show() }

        prefs.onMenuBarToggle = { [weak self] on in on ? self?.menuBar.show() : self?.menuBar.hide() }

        // First run: no password and no menu bar would be confusing — open settings.
        if !Settings.hasPassword && !Settings.showInMenuBar { prefs.show() }
        if !AXIsProcessTrusted() { requestAccessibility() }

        // Reconcile the login-item state with the saved preference.
        LoginItem.set(Settings.launchAtLogin)
    }

    /// Re-opening the app from Finder shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        prefs.show(); return true
    }

    private func quit() { coordinator.deactivateNow(); NSApp.terminate(nil) }

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}
