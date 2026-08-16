import Foundation
import ServiceManagement
import CurtainCore

/// Purpose: Crash-relaunch supervision for the main Curtain.app process (T-P1-E08-03).
///          Distinct from `LoginItem` (`SMAppService.mainApp`), which only controls
///          whether Curtain starts at the NEXT login — it has no KeepAlive semantics
///          and does nothing if the running process dies mid-session. This file
///          registers a SEPARATE `SMAppService.agent` so launchd itself relaunches
///          Curtain after an abnormal exit while a session was (or could have been)
///          active.
///
/// Decision (SMAppService.agent vs. a companion supervisor process), per the ticket's
/// required research-then-decide: `SMAppService.agent(plistName:)` was chosen over a
/// companion-supervisor process/daemon. Reasoning:
///   1. Apple's SMAppService family explicitly supports `.agent(plistName:)` as a
///      "run this same app bundle as a LaunchAgent" registration, loaded from
///      Contents/Library/LaunchAgents/<plist> — this is a first-class, in-bundle,
///      no-extra-binary mechanism, unlike `.daemon`, which requires a root helper.
///      A LaunchAgent runs in the user's GUI session (Aqua bootstrap context), so a
///      menu-bar-only NSApplication (LSUIElement, no Dock icon) launches and runs
///      exactly as it does today when double-clicked — no windowing/session
///      restriction applies to LaunchAgents the way it would to LaunchDaemons.
///   2. A companion-supervisor process (a second lightweight binary watching
///      Curtain's PID) would duplicate the exact mechanism SMAppService.daemon
///      already proves out for CurtainHelper (see DisconnectClient.swift), but for
///      zero additional benefit here: Curtain doesn't need an XPC-reachable
///      always-on helper, it only needs "relaunch me if I die unexpectedly," which
///      launchd's own KeepAlive semantics already do natively. Building a second
///      supervisor binary would be the invasive restructure the ticket explicitly
///      asks to avoid, for a problem launchd already solves.
///   3. `KeepAlive.SuccessfulExit = false` in the LaunchAgent plist (see
///      Scripts/release.sh) gives launchd the exact clean-quit-vs-crash distinction
///      this ticket requires: launchd relaunches ONLY when the process's last exit
///      was NOT a clean (status 0) termination. `RunAtLoad` is deliberately omitted
///      from the plist so registering/loading this agent never itself launches
///      Curtain — that responsibility stays solely with LoginItem/SMAppService.mainApp,
///      preventing a double-launch-at-login regression.
///   4. This mechanism is a pure launchd-level safety net layered UNDER LoginItem: it
///      does not change what LoginItem does, does not touch its UserDefaults-backed
///      preference, and registering/unregistering it has zero effect on whether
///      Curtain shows up in System Settings > Login Items (that surface remains
///      driven entirely by `SMAppService.mainApp`).
/// Inputs: none (register()/unregister() take no arguments).
/// Outputs: an `SMAppService.agent` registration in launchd's user-session domain.
/// Constraints: registration is idempotent (checks `.status` before acting, mirroring
///          LoginItem.set and DisconnectClient.setEnabled) and best-effort — a failed
///          registration is logged, never fatal, since a menu-bar privacy tool must
///          never fail to launch over a supervision registration problem.
/// SPORT: MASTER-APP
enum AppSupervisor {
    /// Label baked into the LaunchAgent plist at `Contents/Library/LaunchAgents/`
    /// by Scripts/release.sh — must match exactly, since SMAppService resolves the
    /// registration by this plist filename inside the running app's own bundle.
    private static let plistName = "io.acamarata.curtain.supervisor.plist"

    private static var agent: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    /// True once launchd has this agent's KeepAlive registration active.
    static var isRegistered: Bool { agent.status == .enabled }

    /// Register the crash-relaunch agent. Safe to call every launch — idempotent,
    /// best-effort, and silent on the common "already registered" case.
    static func register() {
        guard agent.status != .enabled else { return }
        do {
            try agent.register()
        } catch {
            // Best-effort: a loose (non-installed, e.g. `swift run`) build has no
            // Contents/Library/LaunchAgents plist to find, so this throws in dev —
            // expected and harmless, matching LoginItem's own dev-mode no-op.
            NSLog("Curtain: crash-supervision agent registration failed: \(error.localizedDescription)")
        }
    }

    /// Unregister the crash-relaunch agent. Called from Scripts/uninstall.sh's
    /// in-app path is not applicable (the app is being deleted), but exposed for
    /// symmetry/testability and for a future "disable crash relaunch" preference.
    static func unregister() {
        guard agent.status == .enabled else { return }
        do {
            try agent.unregister()
        } catch {
            NSLog("Curtain: crash-supervision agent unregistration failed: \(error.localizedDescription)")
        }
    }
}
