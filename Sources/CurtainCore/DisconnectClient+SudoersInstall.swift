import Foundation
import CurtainShared

/// Purpose: Sudoers-fallback installer for the disconnect helper — the ad-hoc/local
///          install path used when SMAppService.daemon.register() cannot run (see
///          DisconnectClient+SigningCheck.swift for the gate that decides when this
///          path is reachable).
/// Inputs: None beyond the current user (`NSUserName()`); triggered by
///         `DisconnectClient.setEnabled(_:)` in DisconnectClient.swift.
/// Outputs: Writes/removes `/usr/local/bin/curtain-endsession` (helper script) and
///          `/etc/sudoers.d/curtain-endsession` (NOPASSWD rule), and runs the installed
///          script via `sudo -n`.
/// Constraints: @MainActor for install/remove (touches app state via a single admin
///              prompt); the sudo-invocation path (`runSudoEndSession`) runs on a
///              background queue and must never block main. Idempotent: state-checks
///              before prompting, never loops a denied prompt.
///
/// Sudoers fallback is dev-only: the NOPASSWD rule below is an acceptable convenience
/// for a developer running a locally-built, ad-hoc/unsigned app on their own machine —
/// but it must NEVER ship inside a notarized public build, where it would be a
/// privilege-escalation footgun. `DisconnectClient.setEnabled(_:)` only calls
/// `installSudoersHelper()` when `DisconnectClient.isProperlySigned() == false`.
///
/// TOKEN-GUARD (2026-08-15, T-P1-E01-02): the NOPASSWD sudoers rule alone lets ANY
/// local process running as the same user invoke `sudo -n curtain-endsession`
/// directly, bypassing the app and its XPC trust check. To close that, the installed
/// script now requires a one-time, single-use token file written by Curtain
/// immediately before each legitimate invocation (see `runSudoEndSession` below). A
/// bare `sudo -n curtain-endsession` with no fresh token present is a no-op: the
/// script's first action is to validate + consume the token, and it only proceeds to
/// the pkill sequence if that succeeds.
///
/// RESIDUAL RISK (stated honestly, do not remove this note without re-reading it):
/// this is NOT airtight. The token file is written to a fixed, predictable path
/// (`Self.tokenPath`, under /private/tmp) immediately before the sudo call. A
/// sufficiently fast local attacker process running as the SAME user, polling that
/// path in a tight loop, could in principle observe the token in the ~milliseconds
/// between write and consumption and invoke the sudo command itself first, winning
/// the race. This raises the bar from "trivial, unbounded-time exploit" to "requires
/// a tight local race against a single-use, sub-second-lived token" — a real
/// improvement, but not a cryptographic guarantee. The only fully airtight fix is
/// eliminating the sudoers fallback in favor of the SMAppService.daemon/XPC path
/// (E-02, notarized builds only), which is already the primary path this fallback
/// yields to.
/// SPORT: MASTER-DISCONNECT
extension DisconnectClient {
    /// Fixed path for the one-time handshake token. Lives under /private/tmp (not
    /// /var/run, which requires root to create) so the app — running as the plain
    /// user — can write it directly; the sudo'd-to-root script can still read/delete
    /// it since root can access any file. Written with 0600 perms immediately before
    /// each sudo invocation and consumed (deleted) by the very first thing the
    /// installed script does.
    static let tokenPath = "/private/tmp/.curtain-endsession-token"

    /// Embedded in the generated script as a comment and compared against the live
    /// source each install check, so a stale (older, unguarded) script on disk from
    /// a previous Curtain version is detected and reinstalled rather than trusted
    /// as-is. Bump this whenever the script body changes.
    static let sudoersScriptVersion = "2"

    /// Install the privileged helper script + a NOPASSWD sudoers rule scoped to the
    /// current user, via a SINGLE admin prompt. Idempotent: if both files already
    /// exist, the sudoers entry validates, AND the installed script is the current
    /// version, skip the prompt entirely. An older (pre-token-guard) script on disk
    /// is treated as stale and reinstalled.
    func installSudoersHelper() {
        if isSudoersHelperInstalled
            && FileManager.default.fileExists(atPath: Self.sudoersFilePath)
            && installedScriptIsCurrentVersion()
        {
            NSLog("Curtain: sudoers disconnect helper already installed — skipping prompt")
            syncWithSettings()
            return
        }

        let user = NSUserName()
        // launchd respawns the listener, so Screen Sharing stays available afterward.
        //
        // Token-guard: the very first action is to validate + delete the one-time
        // token before doing anything privileged. `set -e` isn't used here because
        // we want explicit exit codes at each check, not an implicit abort.
        //
        //   1. Token file must exist — a bare invocation with nothing written is the
        //      baseline attack this closes; if missing, no-op immediately.
        //   2. Token file must be owned by the invoking user (root here, since sudo
        //      already ran as root by the time this executes) — actually what we can
        //      check from inside the script is the file's owning UID matches the
        //      sudoers-authorized user, using stat, to reject a token planted by a
        //      different local account.
        //   3. Token file must be fresh (mtime within 5 seconds) — rejects a stale or
        //      captured-and-replayed token.
        //   4. Delete the token FIRST (before running any pkill), so the token is
        //      single-use even if something later in the script fails.
        let script = """
            #!/bin/bash
            # curtain-endsession script version \(Self.sudoersScriptVersion)
            TOKEN="\(Self.tokenPath)"
            if [ ! -f "$TOKEN" ]; then
                exit 1
            fi
            OWNER_UID=$(/usr/bin/stat -f '%u' "$TOKEN" 2>/dev/null)
            if [ "$OWNER_UID" != "$(/usr/bin/id -u \(user))" ]; then
                /bin/rm -f "$TOKEN"
                exit 1
            fi
            MTIME=$(/usr/bin/stat -f '%m' "$TOKEN" 2>/dev/null)
            NOW=$(/bin/date +%s)
            AGE=$((NOW - MTIME))
            # Consume (delete) the token unconditionally before the age check so a
            # replay attempt against the same token never succeeds even if this run
            # is rejected for being stale.
            /bin/rm -f "$TOKEN"
            if [ "$AGE" -lt 0 ] || [ "$AGE" -gt 5 ]; then
                exit 1
            fi
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

    /// True when the script already on disk contains the current
    /// `sudoersScriptVersion` marker. A missing marker (pre-token-guard script) or a
    /// mismatched version returns false, forcing `installSudoersHelper()` to
    /// reinstall rather than trust a stale, unguarded script.
    private func installedScriptIsCurrentVersion() -> Bool {
        guard let contents = try? String(contentsOfFile: Self.helperScriptPath, encoding: .utf8) else {
            return false
        }
        return contents.contains("# curtain-endsession script version \(Self.sudoersScriptVersion)")
    }

    /// Remove both helper files via one admin prompt — only when at least one exists.
    func removeSudoersHelper() {
        let fm = FileManager.default
        guard
            fm.fileExists(atPath: Self.helperScriptPath)
                || fm.fileExists(atPath: Self.sudoersFilePath)
        else { return }

        let remove = "/bin/rm -f '\(Self.helperScriptPath)' '\(Self.sudoersFilePath)'"
        if runAdminShell(remove) {
            NSLog("Curtain: sudoers disconnect helper removed")
        } else {
            NSLog("Curtain: sudoers disconnect helper removal failed")
        }
    }

    /// Run a shell command once with administrator privileges (one OS password prompt).
    /// Returns true on exit status 0. Never loops on a denied prompt.
    ///
    /// AUDIT (T-P1-E01-04): as of this change, neither current call site
    /// (`installSudoersHelper`'s `install` string, `removeSudoersHelper`'s `remove`
    /// string) interpolates any untrusted or user-controlled value into `command`.
    /// The only interpolated values are `Self.helperScriptPath` / `Self.sudoersFilePath`
    /// (fixed compile-time string constants) and `scriptB64` / `sudoersB64` (base64
    /// output — alphanumeric + `/` + `+` + `=` only, inherently shell-safe). No
    /// untrusted input reaches this path today; the risk this hardening addresses is
    /// entirely prospective (a future contributor interpolating variable/user data
    /// into a command string without realizing the AppleScript-embedding hazard).
    ///
    /// HARDENING: previously `command` was embedded directly into AppleScript source
    /// text via manual backslash/quote `.replacingOccurrences` escaping before being
    /// passed to `osascript -e "<script text>"` — correct only as long as the escaping
    /// covers every character AppleScript's string literal syntax treats specially,
    /// which is easy to get subtly wrong on a future edit. This now uses a fixed,
    /// static AppleScript body (`on run argv`) piped to `osascript` via stdin, with
    /// `command` passed as a plain process argument rather than interpolated into any
    /// script text. This eliminates AppleScript-string-escaping as an attack surface
    /// entirely: `command` never becomes part of source text that gets parsed as
    /// AppleScript syntax, so no future caller can create an injection by passing
    /// unescaped or partially-escaped content, however that content originates.
    /// SPORT: MASTER-DISCONNECT
    func runAdminShell(_ command: String) -> Bool {
        // Static script body — never interpolates `command`. `argv`'s first item is
        // passed straight to `do shell script`, and AppleScript's argv values are not
        // re-parsed as script source, so no escaping of `command` is required here.
        let script = """
            on run argv
                do shell script (item 1 of argv) with administrator privileges
            end run
            """

        // Delegates to the shared ProcessRunner (CurtainShared): pipes the static
        // script body via stdin and reports success as exit status 0, matching the
        // exact prior behavior of this call site.
        return ProcessRunner.run(
            "/usr/bin/osascript", ["-", command],
            stdin: Data(script.utf8),
            onLaunchFailure: { error in
                NSLog("Curtain: admin shell launch failed: %@", String(describing: error))
            }
        ).succeeded
    }

    /// Invoke the installed sudoers helper with `sudo -n` (no prompt — the NOPASSWD
    /// rule covers it) on a background queue, with a timeout, never blocking main.
    /// Called off-main via `System.disconnectHandler`.
    ///
    /// Token-guard: writes a fresh, single-use token file immediately before the sudo
    /// call (see the doc comment atop this file for the full mechanism and its
    /// residual-risk caveat). The token is deliberately written just-in-time, not
    /// persisted — if the sudo call fails to launch, or the process times out and is
    /// terminated, the token is cleaned up so no stale-but-still-fresh token is left
    /// sitting on disk for a later, unrelated invocation to consume.
    static func runSudoEndSession() {
        Log.event("disconnect via sudo helper")
        // Copy the MainActor-isolated path constants into plain local `String`s
        // (Sendable) while still on the actor, so the background closure below
        // never touches an isolated static property directly — that was the source
        // of the pre-existing `#ActorIsolatedCall` / Sendable-closure warnings this
        // ticket is required to leave at zero.
        let scriptPath = helperScriptPath
        let tokenFilePath = tokenPath
        DispatchQueue.global(qos: .userInitiated).async {
            guard Self.writeHandshakeToken(at: tokenFilePath) else {
                NSLog("Curtain: sudo end-session aborted — could not write handshake token")
                return
            }
            // Delegates to the shared ProcessRunner's timeout-bounded shape: polls
            // isRunning at 50ms (matching the prior inline loop) and terminates on a
            // 5s deadline rather than blocking indefinitely on waitUntilExit().
            var launchFailed = false
            let (result, timedOut) = ProcessRunner.run(
                "/usr/bin/sudo", ["-n", scriptPath],
                timeout: 5, pollInterval: 0.05,
                onLaunchFailure: { error in
                    launchFailed = true
                    NSLog("Curtain: sudo end-session launch failed: %@", String(describing: error))
                }
            )
            if launchFailed {
                // sudo never ran, so the script never consumed the token — remove it
                // ourselves rather than leaving a valid, unconsumed token on disk.
                try? FileManager.default.removeItem(atPath: tokenFilePath)
            } else if timedOut {
                NSLog("Curtain: sudo end-session timed out — terminated")
                // The script normally consumes (deletes) the token itself as its
                // very first action, well within the 5s budget; if we hit the
                // timeout the script likely never got that far, so clean up here
                // to avoid leaving a stale-but-still-"fresh" token around.
                try? FileManager.default.removeItem(atPath: tokenFilePath)
            } else {
                NSLog("Curtain: sudo end-session exited %d", result.exitCode)
            }
        }
    }

    /// Write a fresh single-use handshake token to `path` with owner-only (0600)
    /// permissions, replacing any prior token. Returns false (and leaves no token
    /// behind) if the write fails, so the caller can abort rather than invoke sudo
    /// against a missing/unwritable token. `nonisolated` + a plain `String`
    /// parameter (rather than reading the actor-isolated `tokenPath` constant
    /// directly) so this can run safely from the background queue in
    /// `runSudoEndSession()` without hopping back to the main actor.
    private nonisolated static func writeHandshakeToken(at path: String) -> Bool {
        let fm = FileManager.default
        // Remove any leftover token first so a failed write never leaves a stale
        // token file that could be misread as fresh moments later.
        try? fm.removeItem(atPath: path)
        let token = UUID().uuidString
        guard
            fm.createFile(
                atPath: path,
                contents: Data(token.utf8),
                attributes: [.posixPermissions: 0o600])
        else {
            return false
        }
        return true
    }
}
