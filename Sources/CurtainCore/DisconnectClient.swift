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
/// This is the core client: the shared singleton, availability checks, the on/off
/// orchestration (`setEnabled`) that picks SMAppService vs. the sudoers fallback, state
/// reconciliation (`syncWithSettings`), and the SMAppService/XPC calling logic
/// (`callHelper`). The sudoers-fallback installer lives in
/// `DisconnectClient+SudoersInstall.swift`; the signing-check gate that decides whether
/// the sudoers fallback is even reachable lives in `DisconnectClient+SigningCheck.swift`.
/// SPORT: MASTER-DISCONNECT
@MainActor
public final class DisconnectClient {
    public static let shared = DisconnectClient()
    private init() {}

    private var daemon: SMAppService {
        SMAppService.daemon(plistName: CurtainHelperInfo.daemonPlistName)
    }

    // Fallback sudoers helper paths (ad-hoc/local installs only). Left at the default
    // `internal` access (not `private`/`fileprivate`) so the sudoers-install extension
    // in DisconnectClient+SudoersInstall.swift can reference them — Swift's `private`/
    // `fileprivate` are file-scoped, not type-scoped, so cross-file extensions of the
    // same type need at least `internal` to see same-type members.
    static let helperScriptPath = "/usr/local/bin/curtain-endsession"
    static let sudoersFilePath = "/etc/sudoers.d/curtain-endsession"

    /// True when disconnect will actually work: either the SMAppService daemon is
    /// registered, or the sudoers helper script is installed and executable. The UI
    /// reads this so it can tell the user whether enabling did anything.
    var isHelperAvailable: Bool {
        daemon.status == .enabled || isSudoersHelperInstalled
    }

    var isSudoersHelperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.helperScriptPath)
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
                NSLog(
                    "Curtain: SMAppService daemon register failed (%@) — using sudoers fallback",
                    String(describing: error))
            }
            if !daemonOK {
                // Sudoers fallback is dev-only: reachable solely on an ad-hoc/unsigned
                // build. A properly-signed build that still couldn't register the daemon
                // must NOT touch sudoers — report instead.
                if Self.isProperlySigned() {
                    NSLog(
                        "Curtain: SMAppService daemon unavailable on a signed build — not installing sudoers fallback")
                    Notifier.post(
                        title: "Curtain",
                        body:
                            "The disconnect helper could not be installed. Try reinstalling Curtain or check System Settings > Login Items.",
                        throttleKey: "disconnect-helper",
                        throttleSeconds: 60)
                } else {
                    installSudoersHelper()
                }
            }
            // Persist the identity that just successfully registered (daemon OR
            // sudoers fallback — installSudoersHelper() above already ran and
            // isHelperAvailable reflects either path) so a future launch under a
            // DIFFERENT code identity (T-P1-E02-02: ad-hoc → Developer-ID upgrade)
            // can detect the mismatch via checkForStaleRegistration(). Skipped when
            // neither path actually succeeded, so a failed enable never records a
            // fingerprint for a registration that doesn't exist.
            if isHelperAvailable, let fingerprint = Self.currentSigningFingerprint() {
                Settings.disconnectHelperSigningFingerprint = fingerprint
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

    /// Detect a stale daemon/sudoers registration left behind by a code-identity
    /// change (T-P1-E02-02) — most notably the ad-hoc → Developer-ID upgrade once
    /// T-P1-E02-01's notarized signing ships. Call once at app launch, alongside
    /// `syncWithSettings()`.
    ///
    /// Only acts when ALL of these hold:
    ///   1. A fingerprint was persisted by a prior successful registration (nil/empty
    ///      means fresh install — never touch anything).
    ///   2. It differs from the current binary's fingerprint (identity actually
    ///      changed; an unreadable current fingerprint is treated as "cannot compare,
    ///      do nothing" rather than a false mismatch).
    ///   3. There is an existing registration to migrate (`isHelperAvailable`) — a
    ///      mismatched fingerprint with nothing currently registered has nothing to
    ///      clean up, so it just clears the stale value silently.
    ///
    /// On a genuine mismatch with a live registration: tear down the old
    /// registration via the same `setEnabled(false)` path used everywhere else,
    /// clear the stale fingerprint, and notify the user to re-enable via
    /// Settings > Disconnect — re-registration is never fired automatically here,
    /// since both the daemon path (fresh SMAppService approval) and the sudoers path
    /// (fresh admin prompt) need to be user-initiated through PrefDisconnectTab.
    /// `Settings.disconnectFeatureEnabled` (the user's own last preference) is left
    /// untouched so the UI still reflects "the user wants this on" even though it's
    /// currently non-functional until they re-enable it.
    public func checkForStaleRegistration() {
        guard let stored = Settings.disconnectHelperSigningFingerprint, !stored.isEmpty else {
            return  // fresh install — nothing was ever registered under any identity
        }
        guard let current = Self.currentSigningFingerprint() else {
            NSLog("Curtain: could not read current signing identity — skipping stale-registration check")
            return
        }
        guard stored != current else {
            return  // identity unchanged since last successful registration — normal relaunch
        }
        guard isHelperAvailable else {
            // Identity changed but nothing is actually registered under the old one
            // (e.g. the user disabled it since). Nothing to migrate — just drop the
            // now-meaningless stale value.
            Settings.disconnectHelperSigningFingerprint = nil
            return
        }

        NSLog("Curtain: disconnect helper signing identity changed since last registration — migrating")
        setEnabled(false)
        Settings.disconnectHelperSigningFingerprint = nil
        Notifier.post(
            title: "Curtain",
            body: "Curtain was updated and the disconnect helper needs to be re-enabled in Settings > Disconnect.",
            throttleKey: "disconnect-helper-migration",
            throttleSeconds: 60)
    }

    /// Reconcile the live `System.disconnectHandler` with the persisted setting and the
    /// path that is actually available: privileged XPC if the daemon is enabled, else
    /// the sudoers helper if installed, else nothing.
    public func syncWithSettings() {
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
    ///
    /// Always-visible: a disconnect request that silently did nothing is a
    /// reliability-relevant refusal, matching SessionCoordinator's Accessibility-
    /// refusal reclassification. No episode ID is threaded in here — this is a
    /// `static func` with no session context (System.disconnectHandler is a global
    /// closure, not scoped to a particular SessionCoordinator instance), and the
    /// event it represents is a configuration state ("helper not enabled"), not a
    /// per-session occurrence, so omitting the token is intentional rather than an
    /// oversight.
    static func notifyHelperNeeded() {
        Log.error("disconnect requested but helper not enabled")
        let body = "To disconnect the remote session, turn on the disconnect helper in Settings > Disconnect."
        Notifier.post(
            title: "Curtain",
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
    ///
    /// KNOWN LIMITATION — cross-process episode correlation (T-P1-E08-01): the app's
    /// per-session correlation token (SessionMonitor.currentEpisodeID, threaded
    /// through SessionCoordinator's Log.event/Log.error calls) is NOT passed across
    /// this XPC call, so CurtainHelper's own log lines (HelperLog, main.swift) are
    /// never tagged with it. Threading the token through would mean widening the
    /// `CurtainDisconnectXPC` protocol (DisconnectXPC.swift) with an extra parameter
    /// on every call, versioned alongside `protocolVersion`/`endScreenSharingSession`
    /// — judged too invasive for this ticket's scope given the daemon and app update
    /// independently (SMAppService lag) and a protocol change here needs the same
    /// skew-handling care as `protocolVersion` already required. Accepted as-is: a
    /// helper-side rejection/kill log can only be correlated to a specific app-side
    /// session by timestamp proximity, not by a shared token. Revisit if a future
    /// XPC protocol version bump is already in flight for another reason.
    private static func callHelper() {
        Log.event("disconnect via XPC daemon")
        let conn = NSXPCConnection(
            machServiceName: CurtainHelperInfo.machServiceName,
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
        let proxyObject = conn.remoteObjectProxyWithErrorHandler({ error in
            NSLog("Curtain: disconnect XPC error: %@", String(describing: error))
            signalOnce()
        })
        guard let proxy = proxyObject as? CurtainDisconnectXPC else {
            NSLog("Curtain: disconnect XPC proxy cast failed — invalidating")
            conn.invalidate()
            return
        }

        // Version-check before trusting the proxy: the app and the privileged
        // helper daemon are installed/updated independently (SMAppService may lag
        // an app update after a release), so a stale helper must fail with a clear
        // "needs update" message instead of silently burning the 5 s timeout.
        // respondsToSelector is the practical gate here — an old helper built
        // before protocolVersion existed cannot answer an async-reply RPC for a
        // selector it doesn't implement, so the round-trip itself isn't reachable.
        guard (proxyObject as AnyObject).responds(to: #selector(CurtainDisconnectXPC.protocolVersion(reply:))) else {
            NSLog("Curtain: disconnect helper is running an outdated protocol version — reinstall/update Curtain")
            Notifier.post(
                title: "Curtain",
                body: "The disconnect helper needs an update. Try reinstalling Curtain.",
                throttleKey: "disconnect-helper-outdated",
                throttleSeconds: 60)
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
}
