import CoreGraphics
import Foundation
import os
import CurtainShared

/// Purpose: Decide whether the console session is currently being screen-captured
///          (Screen Sharing / VNC), independent of the network transport in use.
/// Inputs: none. Reads live system state via CGSession and a few short shell probes.
/// Outputs: boolean signals; `combinedCaptureActive()` is the one the monitor polls.
/// Constraints: the authoritative signal is CGSession's `CGSSessionScreenIsCaptured`
///              key, which is true only when THIS console session is being captured.
///              It is transport-independent, so it survives macOS Sequoia/26
///              High-Performance Screen Sharing (UDP, no ESTABLISHED state) and any
///              remapped port. The only other things allowed to activate the curtain
///              are network rows that REQUIRE a real foreign peer: an ESTABLISHED
///              inbound TCP connection on port 5900 (classic VNC) or a peered UDP
///              socket on 5900-5902 (the high-performance transport). Process
///              presence and LISTEN/wildcard sockets must never activate:
///              screensharingd / ScreenSharingSubscriber linger with no session, and
///              a 5900 LISTEN socket is always present whenever Screen Sharing is
///              merely enabled. Those false positives kept the curtain up overnight
///              with no session. Shell probes are cheap but block, so the monitor
///              calls these off the main thread. The netstat shell-out is bounded by
///              `shellTimeout` (`ProcessRunner`'s timeout-capable `run`, not the
///              indefinite-block variant): a hung netstat previously froze detection
///              forever (the calling `probeQueue.async` block in `SessionMonitor`
///              never returned, so its `probing` coalescing flag was never reset). On
///              timeout the process is terminated, an error is logged once per path,
///              and an empty string is returned so the caller always gets a value.
///              Polling-cost note (evaluated, not changed): `SessionMonitor` shells
///              out to netstat every ~2s even at rest. A backoff (e.g. widening the
///              interval after N consecutive all-false ticks, snapping back to 2s on
///              any positive signal) was considered but rejected here: idle-timeout
///              and disconnect debouncing (`SessionMonitor.missLimit`/`evaluateIdle`)
///              are both defined in units of fixed-cadence ticks, so a variable
///              interval would silently change idle/disconnect latency and is exactly
///              the class of behavior change this ticket's scope excludes (see
///              T-P1-E05-02 `out_of_scope`: SessionMonitor's polling/coalescing logic
///              is untouched here beyond verifying `probing` resets). `netstat -an`
///              is a cheap, sub-100ms local syscall-backed call even under load, so
///              the fixed 2s interval's steady-state cost is not a measured problem;
///              revisit only alongside a SessionMonitor-scoped ticket that can also
///              re-derive missLimit/idle timing for a variable cadence.
/// SPORT: MASTER-CAPTUREPROBE
enum CaptureProbe {

    /// How long a single shell probe (netstat, pgrep) may run before it is
    /// considered hung and force-terminated. 5s is generously above netstat's
    /// normal sub-100ms runtime on this machine (even under load) but well below
    /// the 2s poll interval's next few ticks, so a hang degrades loudly within a
    /// couple of ticks rather than blocking forever with no signal.
    static let shellTimeout: TimeInterval = 5.0

    /// Injection seam for tests: the shell-out point, defaulting to
    /// `ProcessRunner`'s bounded-timeout `run`. Production code never overrides
    /// this; tests swap it in to simulate a hang or to feed a canned netstat
    /// fixture without spawning a real process.
    static var processRunner:
        (String, [String], TimeInterval, ((Error) -> Void)?) -> (result: ProcessRunner.Result, timedOut: Bool) = {
            path, args, timeout, onLaunchFailure in
            ProcessRunner.run(path, args, timeout: timeout, onLaunchFailure: onLaunchFailure)
        }

    /// CGSession dictionary key (a CFBoolean) that is true when the console session
    /// is being screen-captured. This is the primary, transport-independent signal.
    private static let captureKey = "CGSSessionScreenIsCaptured"

    /// Primary signal. True when the current console session is being captured.
    /// A different-user virtual session reports this as false in the console
    /// session, which is exactly the stand-down behavior we want.
    static func isConsoleScreenCaptured() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        guard let captured = dict[captureKey] as? Bool else { return false }
        return captured
    }

    /// Diagnostics only. Whether a screen-sharing helper process is running. This is
    /// NOT an activation signal: ScreenSharingSubscriber / screensharingd linger long
    /// after a session ends (and while Screen Sharing is merely enabled), so treating
    /// process presence as "active" produced overnight false positives. Kept for the
    /// probe script and troubleshooting; never call it from combinedCaptureActive.
    static func screenShareProcessesPresent() -> Bool {
        let out = shell("/usr/bin/pgrep", ["-fl", "ScreenSharingAgent|ScreenSharingSubscriber|screensharingd"])
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A genuinely ESTABLISHED inbound TCP connection on local port 5900 (a real
    /// classic VNC session). A LISTEN socket is always present when Screen Sharing
    /// is enabled, so it must never count — we require state ESTABLISHED AND a real
    /// foreign peer (not `*.*`). We match the LOCAL address column so an outbound
    /// VNC client connection (this Mac controlling another) never reads as a session.
    static func establishedVNC() -> Bool {
        NetstatParse.hasEstablishedVNC(netstatOutput())
    }

    /// A UDP socket on local port 5900-5902 connected to a real foreign peer — the
    /// High-Performance Screen Sharing transport (macOS 14+, Apple silicon, UDP).
    /// Wildcard listeners never count, so this cannot fire at rest. This is the
    /// network corroborator for high-performance sessions, where there is no
    /// ESTABLISHED TCP row at all.
    static func peeredUDPVNC() -> Bool {
        NetstatParse.hasPeeredUDPVNC(netstatOutput())
    }

    /// One snapshot of every activation signal, so the monitor can log exactly
    /// which signal saw the session. Equatable so transitions are cheap to detect.
    struct CaptureSignals: Equatable, Sendable {
        let captured: Bool
        let tcpEstablished: Bool
        let udpPeered: Bool
        var any: Bool { captured || tcpEstablished || udpPeered }
    }

    /// Read all signals from one netstat snapshot (netstat is the expensive probe;
    /// never run it twice per tick).
    static func signals() -> CaptureSignals {
        let netstat = netstatOutput()
        return CaptureSignals(
            captured: isConsoleScreenCaptured(),
            tcpEstablished: NetstatParse.hasEstablishedVNC(netstat),
            udpPeered: NetstatParse.hasPeeredUDPVNC(netstat)
        )
    }

    /// The signal the monitor consumes. The capture key is authoritative; a real
    /// ESTABLISHED inbound TCP session on 5900 (classic) or a peered UDP socket on
    /// 5900-5902 (high-performance) are the only other things that may activate the
    /// curtain. Process presence and LISTEN sockets are ignored.
    static func combinedCaptureActive() -> Bool {
        signals().any
    }

    // MARK: - Shell

    /// netstat lives in /usr/sbin on macOS (NOT /usr/bin — a wrong path here once
    /// silently killed the entire network corroborator: Process.run() threw, shell()
    /// returned "", and every netstat-based signal read false forever). Internal
    /// (not private) so CaptureProbeTests can assert the invoked path directly via
    /// the `processRunner` seam — a regression test for that exact incident.
    static func netstatOutput() -> String {
        shell("/usr/sbin/netstat", ["-an"])
    }

    /// Paths we have already complained about, so a permanently-broken tool logs
    /// once per launch instead of every 2-second tick. Also dedups the timeout
    /// warning so a tool that hangs on every tick logs once, not every 2 seconds.
    private static let warnedPaths = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Delegates to the shared `ProcessRunner` (CurtainShared) so this probe uses
    /// the same process-launch seam as every other Process call site in the app,
    /// bounded by `shellTimeout` so a hung binary cannot block detection forever.
    /// Preserves the exact prior behavior on the happy path: empty string + a
    /// once-per-path warning log on launch failure, captured stdout otherwise. On
    /// timeout: the process is terminated by `ProcessRunner`, an error is logged
    /// once per path, and this still returns (empty string) so the caller's
    /// coalescing flag (e.g. `SessionMonitor.probing`) is guaranteed to reset.
    private static func shell(_ path: String, _ args: [String]) -> String {
        let (result, timedOut) = processRunner(
            path, args, shellTimeout,
            { error in
                let firstTime = warnedPaths.withLock { warned in
                    warned.insert(path).inserted
                }
                if firstTime {
                    Log.error("probe helper failed to launch: \(path) — \(error.localizedDescription)")
                }
            })
        if timedOut {
            let firstTime = warnedPaths.withLock { warned in
                warned.insert("\(path) [timeout]").inserted
            }
            if firstTime {
                Log.error("probe helper timed out after \(shellTimeout)s and was terminated: \(path)")
            }
        }
        return result.output
    }
}
