import Cocoa
import CurtainCore

/// Purpose: App entry orchestration. Owns the coordinator, the optional menu bar,
///          the settings window, and the onboarding window. Keeps logic out of the
///          UI: it just wires callbacks between the pieces and drives cleanup on quit.
/// Inputs: NSApplicationDelegate lifecycle callbacks; Settings/UserDefaults state.
/// Outputs: A running agent with menu bar, settings, and (first run) onboarding wired.
/// Constraints: @MainActor — owns AppKit objects and SessionCoordinator (itself @MainActor).
///              cleanup() must be idempotent: it runs on menu-driven quit (quit() ->
///              cleanup() -> NSApp.terminate), on AppKit's applicationWillTerminate
///              notification, and — as of T-P1-E08-03 — on a real SIGTERM (launchd
///              stop / `kill`, not `kill -9`): main.swift installs `signal(SIGTERM,
///              SIG_IGN)` plus a DispatchSource signal handler on the main queue that
///              calls cleanup() then exit(0) directly, rather than relying on AppKit
///              routing an external signal through applicationWillTerminate on its
///              own (it does not). SIGKILL and a hard crash bypass cleanup() entirely
///              — uncatchable/unrecoverable by definition, the same boundary already
///              documented for crash telemetry below.
///              Registers crash telemetry at launch (T-P1-E08-02): NSSetUncaughtExceptionHandler
///              (Layer 1, catches uncaught NSException) plus a minimal async-signal-safe
///              SIGILL/SIGTRAP/SIGABRT handler (Layer 2, catches Swift traps). Neither
///              catches SIGKILL — see CrashSignalHandler.swift for the exact coverage
///              boundary. Registers process-level crash-relaunch supervision at launch
///              (T-P1-E08-03): AppSupervisor.register() gives launchd its own
///              KeepAlive(SuccessfulExit: false) reason to relaunch Curtain after an
///              abnormal exit, and CrashRelaunchMarker.disarmAndCheckPriorCrash() is
///              read FIRST, before any other startup work, to detect whether this
///              launch follows exactly such a relaunch (see AppSupervisor.swift and
///              CrashRelaunchMarker.swift for the full mechanism and ordering
///              constraints).
/// SPORT: MASTER-APP
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = SessionCoordinator()
    lazy var menuBar = MenuBarController(coordinator: coordinator)
    lazy var prefs = PreferencesWindowController(coordinator: coordinator)
    lazy var onboarding = OnboardingWindowController(coordinator: coordinator)
    lazy var kvmBridgeSetup = KVMBridgeSetupWindowController()
    /// Opt-in, off-by-default local MCP server (T-P1-E14-01) — see MCPServer.swift
    /// for the full transport rationale and the HARD SECURITY BOUNDARY this surface
    /// is built under. `start()` re-checks `Settings.mcpServerEnabled` itself, so
    /// this call is safe unconditionally on every launch (same posture as
    /// `AppSupervisor.register()` below).
    lazy var mcpServer = MCPServer(coordinator: coordinator)

    func applicationDidFinishLaunching(_ n: Notification) {
        // Clean-shutdown marker check (T-P1-E08-03) — read and disarm FIRST, before
        // any other startup work (including installing the crash handlers below), so
        // this launch's own marker state starts fresh and a crash later in THIS
        // session is correctly detected as unclean on the *next* launch rather than
        // reading a stale value. `true` here means the previous run did NOT exit
        // cleanly (crash, kill -9, force-quit, power loss) — including, most likely,
        // exactly the abnormal-exit case AppSupervisor's launchd KeepAlive registration
        // (below) exists to relaunch from.
        let wasUncleanPriorExit = CrashRelaunchMarker.disarmAndCheckPriorCrash()

        // Main-app crash-relaunch supervision (T-P1-E08-03). Idempotent, best-effort:
        // see AppSupervisor.swift for the SMAppService.agent-vs-companion-supervisor
        // decision and why this is safe to call unconditionally on every launch.
        AppSupervisor.register()

        // Crash telemetry (T-P1-E08-02). Layer 1 catches uncaught Objective-C/Cocoa
        // NSException throws (e.g. an invalid AppKit call, KVO misuse, an invalid-
        // argument exception raised by a Cocoa API) — a real, non-trivial share of
        // macOS app crashes, since AppKit itself raises NSException internally for
        // programmer errors. It does NOT catch Swift-level fatal errors (fatalError(),
        // force-unwrap of nil, array-index-out-of-bounds, integer overflow traps),
        // because those go through the Swift runtime's trap machinery and raise
        // SIGILL/SIGTRAP/SIGABRT rather than throwing an NSException. Layer 2
        // (registered in CrashSignalHandler.installSignalHandlers(), see that file
        // for the full safety writeup) catches exactly those three signals — it does
        // NOT register SIGSEGV (bad memory access), SIGBUS (misaligned/unmapped
        // access), or SIGFPE (integer divide-by-zero): those are real, distinct
        // native-crash signals left uncovered by this ticket, not the same gap under
        // another name. SIGKILL is always uncatchable by any process — an OS
        // guarantee, not a gap either layer can close.
        NSSetUncaughtExceptionHandler { exception in
            Log.error(
                "uncaught NSException: \(exception.name.rawValue) — \(exception.reason ?? "no reason")\n\(exception.callStackSymbols.joined(separator: "\n"))"
            )
        }
        CrashSignalHandler.installSignalHandlers()

        Settings.registerDefaults()
        Notifier.requestAuthorization()
        System.startupLockProbe()

        coordinator.onStateChange = { [weak self] active in self?.menuBar.reflect(active: active) }
        coordinator.onArmedChange = { [weak self] armed in self?.menuBar.reflect(armed: armed) }
        coordinator.start()

        // Off by default — see MCPServer.start()'s own Settings.mcpServerEnabled
        // re-check, which is the actual enforcement point of the gate.
        mcpServer.start()

        // Post-crash-relaunch notification (T-P1-E08-03). Gated on `hasOnboarded`
        // because a brand-new install's very first launch also reads
        // `wasUncleanPriorExit == true` (no marker has ever been written yet) — that
        // is not a crash, it's "never ran before," and must not be reported as one.
        // Every launch after onboarding has a real prior marker state to compare
        // against, so the gate only ever suppresses this one unavoidable first-launch
        // false positive, not any genuine post-onboarding crash.
        if wasUncleanPriorExit && Settings.hasOnboarded {
            Log.error(
                "Curtain: detected unclean prior exit — relaunched via AppSupervisor (or manually) after a crash/kill")
            Notifier.postPublic(
                title: "Curtain restarted",
                body:
                    "Curtain exited unexpectedly and has been restarted automatically. If a remote session was active during the crash, the privacy cover was NOT enforced from the moment it exited until now — verify your desk manually.",
                throttleKey: "post-crash-relaunch",
                throttleSeconds: 60
            )
            // Re-arm/re-cover-after-crash coordination gap (ST3): if a remote session
            // was STILL active at the moment Curtain died, the correct behavior here
            // would be to detect that and immediately re-cover/re-arm rather than
            // leaving the desk exposed until the next SessionMonitor tick or manual
            // arm. That requires durable "was a session active" state written BEFORE
            // the crash, which this ticket deliberately does not invent ad hoc — it
            // depends on E-10's heartbeat/session-state persistence (T-P1-E10-01,
            // "Crash-recovery heartbeat: SessionMonitor writes a liveness+status file
            // every tick" — spec exists under .claude/phases/current/p1/epics/E-10/,
            // NOT YET IMPLEMENTED as of this ticket). Once that heartbeat file exists,
            // wire this branch to read it and call coordinator.activateNow() when it
            // shows a session was active at last-known-tick time. Until then, a
            // post-crash relaunch starts idle/unarmed-per-Settings.armed like any
            // other launch — visible via this notification, not silently gapped.
        }

        // Detect a stale daemon/sudoers registration left by a signing-identity change
        // (e.g. ad-hoc → Developer-ID upgrade, T-P1-E02-02) BEFORE reconciling, so a
        // migration this launch cleans up the old registration first rather than
        // syncWithSettings() wiring a handler against an identity that no longer matches.
        DisconnectClient.shared.checkForStaleRegistration()
        // Reconcile the optional privileged disconnect helper with its saved setting.
        DisconnectClient.shared.syncWithSettings()

        menuBar.onOpenSettings = { [weak self] in self?.prefs.show() }
        menuBar.onOpenSetup = { [weak self] in self?.onboarding.show() }
        menuBar.onQuit = { [weak self] in self?.quit() }
        if Settings.showInMenuBar { menuBar.show() }

        prefs.onMenuBarToggle = { [weak self] on in on ? self?.menuBar.show() : self?.menuBar.hide() }
        prefs.openOnboarding = { [weak self] in self?.onboarding.show() }
        prefs.openKVMBridgeSetup = { [weak self] in self?.kvmBridgeSetup.show() }

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

        // Retroactive crash-cause reporting (T-P1-E12-04). Fire-and-forget on
        // a background Task — directory listing + .ips parsing is disk I/O
        // that must never block this launch sequence. check() is itself
        // fully guarded (new report AND recovery-launch detection both
        // required) so this is a safe unconditional call on every launch,
        // matching AppSupervisor.register()'s "safe to call every time"
        // posture above.
        Task.detached(priority: .utility) {
            await CrashReportMonitor.check()
        }
    }

    /// Re-opening the app from Finder shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        prefs.show(); return true
    }

    func applicationWillTerminate(_ notification: Notification) { cleanup() }

    /// Idempotent teardown: drop the curtain and release input/display assertions.
    /// Called from three sites: `quit()` below (menu-driven), `applicationWillTerminate(_:)`
    /// above (AppKit's termination notification), and main.swift's SIGTERM
    /// DispatchSource handler (launchd stop / `kill`, calls this directly then
    /// `exit(0)` — see main.swift for that handler and why it exists rather than
    /// relying on AppKit alone). SIGKILL (`kill -9`) and a hard crash bypass this
    /// entirely — always uncatchable, not a gap this method can close.
    /// Arms the clean-shutdown marker (T-P1-E08-03) LAST, after teardown has actually
    /// completed — see CrashRelaunchMarker's doc comment for why this ordering (not
    /// "arm first, teardown after") is load-bearing: arming any earlier would mark a
    /// session "clean" that could still fail partway through teardown. SIGTERM
    /// (launchd asking Curtain to stop, e.g. at logout/shutdown) intentionally counts
    /// as clean here too — it reaches this same cleanup() path and is a graceful,
    /// non-crash exit, not the abnormal-exit case AppSupervisor's KeepAlive targets.
    func cleanup() {
        mcpServer.stop()
        coordinator.deactivateNowForQuit()
        CrashRelaunchMarker.armClean()
    }

    private func quit() { cleanup(); NSApp.terminate(nil) }
}
