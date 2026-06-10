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
///              calls these off the main thread.
/// SPORT: MASTER-CAPTUREPROBE
enum CaptureProbe {

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
    /// returned "", and every netstat-based signal read false forever).
    private static func netstatOutput() -> String {
        shell("/usr/sbin/netstat", ["-an"])
    }

    /// Paths we have already complained about, so a permanently-broken tool logs
    /// once per launch instead of every 2-second tick.
    private static let warnedPaths = OSAllocatedUnfairLock(initialState: Set<String>())

    private static func shell(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            let firstTime = warnedPaths.withLock { warned in
                warned.insert(path).inserted
            }
            if firstTime {
                Log.error("probe helper failed to launch: \(path) — \(error.localizedDescription)")
            }
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
