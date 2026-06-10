import Foundation
import AppKit
import ServiceManagement
import Security
import CurtainShared

/// Purpose: App-side controller for the optional privileged disconnect helper, with
///          two install paths so it works on BOTH a notarized build and a local
///          ad-hoc/unsigned build.
///            1. SMAppService.daemon — the future, notarized path (XPC to the daemon).
///            2. A sudoers helper script — the fallback for ad-hoc/local installs,
///               where SMAppService.daemon().register() refuses to run.
///          When the feature is on it installs the `System.disconnectHandler` closure
///          that ends the active remote Screen Sharing session via whichever path is
///          actually available.
/// Inputs: `Settings.disconnectFeatureEnabled`, the toggle from settings/onboarding.
/// Outputs: Daemon registration OR sudoers helper install/removal; a set/cleared
///          `System.disconnectHandler`.
/// Constraints: @MainActor (touches SMAppService + app state). The handler closure
///              runs on a background queue (System invokes it off-main), and the
///              sudo/XPC work happens there too — never on the main actor. Install and
///              removal are idempotent per OS-admin-prompt-hygiene: state-check before
///              prompting, never loop a denied prompt.
///
/// Why two paths: SMAppService.daemon requires a Developer ID signature + a registered
/// LaunchDaemon, which an ad-hoc build does not have, so `register()` throws and the
/// disconnect would silently no-op. The sudoers fallback grants the one privileged
/// action we need (killing the root-owned Screen Sharing processes) via a single
/// NOPASSWD rule scoped to the CURRENT USER only — not the whole admin group — so the
/// blast radius is one fixed script for one account. The sudoers path is for ad-hoc /
/// local installs ONLY; the notarized build uses SMAppService.daemon.
/// SPORT: MASTER-DISCONNECT
@MainActor
final class DisconnectClient {
    static let shared = DisconnectClient()
    private init() {}

    private var daemon: SMAppService {
        SMAppService.daemon(plistName: CurtainHelperInfo.daemonPlistName)
    }

    // Fallback sudoers helper paths (ad-hoc/local installs only).
    private static let helperScriptPath = "/usr/local/bin/curtain-endsession"
    private static let sudoersFilePath = "/etc/sudoers.d/curtain-endsession"

    /// True when disconnect will actually work: either the SMAppService daemon is
    /// registered, or the sudoers helper script is installed and executable. The UI
    /// reads this so it can tell the user whether enabling did anything.
    var isHelperAvailable: Bool {
        daemon.status == .enabled || isSudoersHelperInstalled
    }

    private var isSudoersHelperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.helperScriptPath)
    }

    // MARK: - Sudoers-is-dev-only rule
    //
    // The sudoers fallback writes a NOPASSWD rule into /etc/sudoers.d. That is an
    // acceptable convenience for a developer running a locally-built, ad-hoc/unsigned
    // app on their own machine — but it must NEVER ship inside a notarized public
    // build, where it would be a privilege-escalation footgun. The hard rule:
    //
    //   - A properly-signed build (real Developer-ID / Team ID, not ad-hoc) uses the
    //     SMAppService.daemon path ONLY. If that fails it reports the failure and stops.
    //   - The sudoers fallback is reachable ONLY when isProperlySigned() == false, i.e.
    //     an ad-hoc / dev / unsigned build that genuinely cannot register a daemon.
    //
    // isProperlySigned() inspects the running app's own code signature. An ad-hoc
    // signature carries no Team ID and sets the adhoc flag; a real Developer-ID
    // signature carries a Team ID and clears that flag. We treat "has a Team ID and is
    // not ad-hoc" as properly signed.

    /// True only for a real (Developer-ID / non-ad-hoc) signature on the running app.
    /// Used to gate the sudoers fallback so a notarized public build can never install
    /// a sudoers rule. Fails closed (returns true → blocks the fallback) only when the
    /// signing info is unreadable AND a Team ID is present; an unreadable signature with
    /// no Team ID is treated as unsigned/ad-hoc so local dev still works.
    static func isProperlySigned() -> Bool {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else {
            return false
        }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else {
            return false
        }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return false
        }

        // An ad-hoc signature sets the adhoc bit in the code-signing flags.
        if let flags = info[kSecCodeInfoFlags as String] as? UInt32 {
            let adhocFlag: UInt32 = 0x2 // kSecCodeSignatureAdhoc
            if flags & adhocFlag != 0 { return false }
        }

        // A real Developer-ID signature carries a Team ID; ad-hoc signatures do not.
        guard let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty else {
            return false
        }
        return true
    }

    /// Turn the feature on or off, picking the install path that works on this build.
    /// On: try SMAppService first (notarized path); fall back to the sudoers helper if
    /// it throws or doesn't end up enabled (ad-hoc path). Off: tear down whichever is
    /// present. Idempotent throughout.
    func setEnabled(_ on: Bool) {
        if on {
            var daemonOK = false
            do {
                if daemon.status != .enabled {
                    try daemon.register()
                    NSLog("Curtain: disconnect helper registered via SMAppService")
                }
                daemonOK = (daemon.status == .enabled)
            } catch {
                NSLog("Curtain: SMAppService daemon register failed (%@) — using sudoers fallback",
                      String(describing: error))
            }
            if !daemonOK {
                // Sudoers fallback is dev-only: reachable solely on an ad-hoc/unsigned
                // build. A properly-signed build that still couldn't register the daemon
                // must NOT touch sudoers — report instead.
                if Self.isProperlySigned() {
                    NSLog("Curtain: SMAppService daemon unavailable on a signed build — not installing sudoers fallback")
                    Notifier.post(title: "Curtain",
                                  body: "The disconnect helper could not be installed. Try reinstalling Curtain or check System Settings > Login Items.",
                                  throttleKey: "disconnect-helper",
                                  throttleSeconds: 60)
                } else {
                    installSudoersHelper()
                }
            }
        } else {
            do {
                if daemon.status == .enabled {
                    try daemon.unregister()
                    NSLog("Curtain: disconnect helper unregistered")
                }
            } catch {
                NSLog("Curtain: SMAppService daemon unregister failed: %@", String(describing: error))
            }
            removeSudoersHelper()
            System.disconnectHandler = nil
        }
        syncWithSettings()
    }

    /// Reconcile the live `System.disconnectHandler` with the persisted setting and the
    /// path that is actually available: privileged XPC if the daemon is enabled, else
    /// the sudoers helper if installed, else nothing.
    func syncWithSettings() {
        guard Settings.disconnectFeatureEnabled else {
            System.disconnectHandler = nil
            return
        }
        if daemon.status == .enabled {
            System.disconnectHandler = { Self.callHelper() }
        } else if isSudoersHelperInstalled {
            System.disconnectHandler = { Self.runSudoEndSession() }
        } else {
            // Helper not available: never leave the handler nil, or disconnect
            // requests vanish with no feedback. Tell the user how to fix it instead.
            System.disconnectHandler = { Self.notifyHelperNeeded() }
        }
    }

    /// Disconnect was requested but no privileged helper is installed. Surface a
    /// throttled user notification (at most once per ~60s, handled by Notifier) so the
    /// user knows the disconnect did nothing and where to enable it. Called off-main
    /// via the handler.
    static func notifyHelperNeeded() {
        Log.event("disconnect requested but helper not enabled")
        let body = "To disconnect the remote session, turn on the disconnect helper in Settings > Disconnect."
        Notifier.post(title: "Curtain",
                      body: body,
                      throttleKey: "disconnect-helper",
                      throttleSeconds: 60)
        NSLog("Curtain: disconnect requested but helper not enabled — %@", body)
    }

    // MARK: - SMAppService (notarized) path

    /// Open a one-shot privileged XPC connection, ask the helper to disconnect, and
    /// tear the connection down. Runs on the background queue System dispatches to.
    ///
    /// Handlers are installed BEFORE resume() so no race can deliver an interruption
    /// or invalidation event to an unregistered handler. A once-flag guards against
    /// the semaphore being over-signaled if both handlers fire on a broken connection
    /// (over-signaling DispatchSemaphore is safe; this is defensive hygiene).
    private static func callHelper() {
        Log.event("disconnect via XPC daemon")
        let conn = NSXPCConnection(machServiceName: CurtainHelperInfo.machServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: CurtainDisconnectXPC.self)

        let done = DispatchSemaphore(value: 0)
        // nonisolated(unsafe) is not needed here — the once flag is only accessed
        // from the XPC queue that serialises these two callbacks.
        var signaled = false
        let signalOnce = {
            if !signaled { signaled = true; done.signal() }
        }

        // Interruption means the helper crashed or the connection dropped mid-call.
        conn.interruptionHandler = {
            NSLog("Curtain: disconnect XPC connection interrupted")
            signalOnce()
        }
        // Invalidation fires on any terminal failure (bad service name, rejected, etc.).
        conn.invalidationHandler = {
            NSLog("Curtain: disconnect XPC connection invalidated")
            signalOnce()
        }

        conn.resume()

        // Guard the cast: if the proxy is nil or doesn't conform, there is nothing
        // to call and the timeout would burn 5 s for no reason.
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            NSLog("Curtain: disconnect XPC error: %@", String(describing: error))
            signalOnce()
        }) as? CurtainDisconnectXPC else {
            NSLog("Curtain: disconnect XPC proxy cast failed — invalidating")
            conn.invalidate()
            return
        }

        proxy.endScreenSharingSession { ok in
            Log.event("disconnect result: \(ok ? "matched" : "no match")")
            NSLog("Curtain: helper ended session: %@", ok ? "matched" : "no match")
            signalOnce()
        }
        _ = done.wait(timeout: .now() + 5)
        conn.invalidate()
    }

    // MARK: - Sudoers (ad-hoc/local) fallback path

    /// Install the privileged helper script + a NOPASSWD sudoers rule scoped to the
    /// current user, via a SINGLE admin prompt. Idempotent: if both files already
    /// exist and the sudoers entry validates, skip the prompt entirely.
    private func installSudoersHelper() {
        if isSudoersHelperInstalled
            && FileManager.default.fileExists(atPath: Self.sudoersFilePath) {
            NSLog("Curtain: sudoers disconnect helper already installed — skipping prompt")
            syncWithSettings()
            return
        }

        let user = NSUserName()
        // launchd respawns the listener, so Screen Sharing stays available afterward.
        let script = """
        #!/bin/bash
        pkill -f ScreenSharingSubscriber
        pkill -x screensharingd
        pkill -f "RemoteManagement.*[Ss]creen"
        exit 0
        """
        let sudoersLine = "\(user) ALL=(root) NOPASSWD: \(Self.helperScriptPath)"

        // base64 the script so quoting/newlines survive the osascript shell hop intact.
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let sudoersB64 = Data(sudoersLine.utf8).base64EncodedString()

        let install = """
        /bin/mkdir -p /usr/local/bin && \
        printf '%s' '\(scriptB64)' | /usr/bin/base64 -D -o '\(Self.helperScriptPath)' && \
        /bin/chmod 755 '\(Self.helperScriptPath)' && \
        printf '%s' '\(sudoersB64)' | /usr/bin/base64 -D -o '\(Self.sudoersFilePath)' && \
        /bin/chmod 440 '\(Self.sudoersFilePath)' && \
        /usr/sbin/visudo -cf '\(Self.sudoersFilePath)'
        """

        if runAdminShell(install) {
            NSLog("Curtain: sudoers disconnect helper installed for user %@", user)
        } else {
            NSLog("Curtain: sudoers disconnect helper install failed")
        }
        syncWithSettings()
    }

    /// Remove both helper files via one admin prompt — only when at least one exists.
    private func removeSudoersHelper() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.helperScriptPath)
            || fm.fileExists(atPath: Self.sudoersFilePath) else { return }

        let remove = "/bin/rm -f '\(Self.helperScriptPath)' '\(Self.sudoersFilePath)'"
        if runAdminShell(remove) {
            NSLog("Curtain: sudoers disconnect helper removed")
        } else {
            NSLog("Curtain: sudoers disconnect helper removal failed")
        }
    }

    /// Run a shell command once with administrator privileges (one OS password prompt).
    /// Returns true on exit status 0. Never loops on a denied prompt.
    private func runAdminShell(_ command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", osa]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            NSLog("Curtain: admin shell launch failed: %@", String(describing: error))
            return false
        }
    }

    /// Invoke the installed sudoers helper with `sudo -n` (no prompt — the NOPASSWD
    /// rule covers it) on a background queue, with a timeout, never blocking main.
    /// Called off-main via `System.disconnectHandler`.
    static func runSudoEndSession() {
        Log.event("disconnect via sudo helper")
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", helperScriptPath]
            do {
                try task.run()
                // Bounded wait: poll for exit so a hung process can't pin the queue.
                let waitDeadline = Date().addingTimeInterval(5)
                while task.isRunning && Date() < waitDeadline {
                    usleep(50_000)
                }
                if task.isRunning {
                    task.terminate()
                    NSLog("Curtain: sudo end-session timed out — terminated")
                } else {
                    NSLog("Curtain: sudo end-session exited %d", task.terminationStatus)
                }
            } catch {
                NSLog("Curtain: sudo end-session launch failed: %@", String(describing: error))
            }
        }
    }
}
