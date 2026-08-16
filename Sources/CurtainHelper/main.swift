import Foundation
import Security
import CurtainShared
import CurtainHelperCore
import ObjectiveC
import os
#if canImport(Darwin)
    import Darwin
#endif

/// Purpose: The privileged LaunchDaemon. Runs as root (installed via
///          SMAppService.daemon), vends the CurtainDisconnectXPC interface over a
///          mach service, and ends the active remote Screen Sharing session by
///          signalling the connection processes that a user process cannot touch.
/// Inputs: XPC connections from the Curtain app on the well-known mach service.
/// Outputs: Replies true/false over XPC; sends SIGTERM to screensharingd and the
///          subscriber processes (launchd respawns the idle listener).
/// Constraints: Separate process with its own entry point. Daemon never returns
///              from main — it runs the run loop forever. The listener delegate is
///              nonisolated (XPC callbacks arrive off the main actor). Every
///              incoming connection is validated against a Developer-ID code
///              requirement before it is accepted.
/// SPORT: MASTER-DISCONNECT

/// Purpose: Minimal structured logging for CurtainHelper's security-relevant
///          connection-acceptance decisions. CurtainHelper is a separate SPM
///          executable target from the main `Curtain`/`CurtainCore` app (see
///          Package.swift) and cannot import CurtainCore's `Log` type across that
///          module boundary — this is a small, self-contained mirror of its shape
///          (same subsystem, unconditional `.error`-level calls for anything
///          security-relevant), not a shared dependency.
/// Inputs: a short, greppable message string.
/// Outputs: an os.Logger line under subsystem "io.acamarata.curtain", category
///          "helper" (distinct from the app's own "curtain" category so the two
///          processes are distinguishable in Console.app/`log stream`).
/// Constraints: unconditional — CurtainHelper has no Settings/diagnostics-toggle
///          type to gate on, and every call site here is a security rejection or
///          warning that must never be silent. No correlation/episode ID: this
///          daemon is reached only via XPC from the app's per-session logic (see
///          CurtainCore/DisconnectClient.swift's callHelper()), and this ticket
///          judges threading the app's episode ID through the XPC protocol too
///          invasive for its scope — documented as a known limitation there.
/// SPORT: MASTER-DISCONNECT
enum HelperLog {
    private static let logger = Logger(subsystem: "io.acamarata.curtain", category: "helper")

    static func error(_ message: String) {
        logger.error("CURTAIN-HELPER ERROR \(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("CURTAIN-HELPER WARNING \(message, privacy: .public)")
    }
}

/// Implements the XPC contract. One instance is exported per accepted connection.
///
/// SECURITY NOTE — precise process targeting (replaces argv-substring `pkill -f`):
/// `pkill -f PATTERN` matches PATTERN as a regex against the *full command line* of
/// every process on the system, run as root. Any attacker-controlled process could
/// name itself (or an argument) to match the pattern and get killed by this
/// privileged helper, or conversely name itself to *avoid* matching and dodge
/// detection. We instead enumerate every running PID via `sysctl(KERN_PROC_ALL)`,
/// resolve each candidate's real executable path via `proc_pidpath`, and only signal
/// a PID whose resolved path is one of the known, fixed system locations for the
/// screen-sharing session processes — argv content is never consulted. `screensharingd`
/// keeps `pkill -x` (exact process-*name* match, not full-argv, already precise) as
/// specified by the ticket guide.
final class DisconnectService: NSObject, CurtainDisconnectXPC, @unchecked Sendable {
    /// Known, fixed executable paths for the Screen Sharing session processes we are
    /// allowed to terminate. Sourced by inspecting the running system
    /// (RemoteManagement.framework's XPCServices + bundled agent). If a future macOS
    /// release relocates one of these binaries, `killByExactPath` simply finds no
    /// matching PID for that entry and logs zero kills for it — it never falls back
    /// to a loose match.
    private static let screenSharingSubscriberPaths: [String] = [
        "/System/Library/PrivateFrameworks/RemoteManagement.framework/XPCServices/ScreenSharingSubscriber.xpc/Contents/MacOS/ScreenSharingSubscriber"
    ]
    private static let remoteManagementScreenPaths: [String] = [
        "/System/Library/PrivateFrameworks/RemoteManagement.framework/RemoteManagementAgent",
        "/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle/Contents/MacOS/ScreensharingAgent"
    ]

    func endScreenSharingSession(reply: @escaping (Bool) -> Void) {
        // launchd owns the screensharingd listener and respawns it, so terminating
        // these processes drops the live session without killing the service itself.
        // The three independent outcomes are OR-reduced via DisconnectMatcher
        // .anyMatched (CurtainHelperCore) — any one target found is sufficient.
        let outcomes = [
            killByExactPath(Self.screenSharingSubscriberPaths, label: "ScreenSharingSubscriber"),
            runMatched(["pkill", "-x", "screensharingd"]),
            killByExactPath(Self.remoteManagementScreenPaths, label: "RemoteManagementScreen")
        ]
        reply(DisconnectMatcher.anyMatched(outcomes))
    }

    /// Report this daemon build's XPC protocol version. The client (DisconnectClient
    /// .callHelper()) checks `responds(to:)` for this selector before trusting the
    /// connection — a daemon that predates this method (SMAppService lagging an app
    /// update) simply never answers, which the client treats as "helper needs
    /// update" rather than a silent 5s timeout.
    func protocolVersion(reply: @escaping (Int) -> Void) {
        reply(CurtainHelperInfo.currentProtocolVersion)
    }

    /// Enumerate all running PIDs, resolve each one's real executable path via
    /// `proc_pidpath`, and send SIGTERM directly (via `kill(2)`, not `pkill`) to any
    /// PID whose resolved path exactly matches one of `expectedPaths`. No argv
    /// content is ever inspected, so a process cannot spoof its way into (or out of)
    /// a match by crafting its command-line arguments. Returns true if at least one
    /// PID was matched and signalled. Every match is logged with its PID and
    /// resolved path for auditability.
    private func killByExactPath(_ expectedPaths: [String], label: String) -> Bool {
        var matchedAny = false
        for pid in Self.allRunningPIDs() {
            guard let path = Self.executablePath(ofPID: pid),
                DisconnectMatcher.pathMatches(path, expectedPaths: expectedPaths)
            else { continue }
            if kill(pid, SIGTERM) == 0 {
                matchedAny = true
                NSLog("CurtainHelper: killed PID %d (%@) for target %@", pid, path, label)
            } else {
                NSLog(
                    "CurtainHelper: kill(2) failed for PID %d (%@) target %@: errno %d",
                    pid, path, label, errno)
            }
        }
        return matchedAny
    }

    /// Every running PID on the system, via `sysctl(KERN_PROC_ALL)`. Foundation/Darwin
    /// only — no new dependency, per project policy of zero third-party deps.
    private static func allRunningPIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        var actualSize = size
        let result = procs.withUnsafeMutableBytes { buf -> Int32 in
            sysctl(&mib, u_int(mib.count), buf.baseAddress, &actualSize, nil, 0)
        }
        guard result == 0 else { return [] }

        let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actualCount).map { $0.kp_proc.p_pid }
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` (`4 * MAXPATHLEN`, from `<sys/proc_info.h>`). The C
    /// macro itself is not importable into Swift on this SDK ("structure not
    /// supported"), so the fixed constant is inlined here.
    private static let maxPathInfoSize = 4 * 1024

    /// Resolve a PID's real executable path via `proc_pidpath`, or nil if the process
    /// has already exited or the lookup otherwise fails (e.g. permission, zombie).
    private static func executablePath(ofPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: maxPathInfoSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Run a pkill-style command. Returns true when pkill exits 0 (a process matched).
    /// Used only for the already-precise `pkill -x screensharingd` exact-name match.
    /// Delegates to the shared ProcessRunner (CurtainShared), matching the exact
    /// prior behavior: blocking run, exit-status-0-means-matched.
    private func runMatched(_ argv: [String]) -> Bool {
        guard let tool = argv.first else { return false }
        return ProcessRunner.run(
            "/usr/bin/" + tool, Array(argv.dropFirst()),
            onLaunchFailure: { error in
                NSLog("CurtainHelper: failed to run %@: %@", tool, String(describing: error))
            }
        ).succeeded
    }
}

/// Accepts XPC connections only from a copy of the Curtain app signed by the same
/// Developer-ID identity. Rejects everything else.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    nonisolated func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection conn: NSXPCConnection
    ) -> Bool {
        guard isTrustedCaller(conn) else {
            HelperLog.error("rejected connection — caller failed code-signature check")
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: CurtainDisconnectXPC.self)
        conn.exportedObject = DisconnectService()
        conn.resume()
        return true
    }

    /// Validate the connecting client by its XPC audit token: the caller must be a
    /// valid code signed with our bundle identifier and an Apple-issued anchor, AND —
    /// when both sides expose a Team ID — the Team IDs must match. This means only a
    /// properly-signed copy of Curtain (our identity) can drive the privileged helper.
    ///
    /// SECURITY NOTE — audit-token-keyed resolution (closes the PID-reuse TOCTOU race):
    /// `NSXPCConnection` does not publish an audit-token accessor in its public header,
    /// but the underlying object DOES implement one (`-[NSXPCConnection auditToken]`,
    /// confirmed present via Objective-C runtime introspection on the current SDK) —
    /// Foundation itself uses it internally for exactly this kind of caller check. We
    /// call it through `objc_msgSend`-style IMP invocation rather than
    /// `kSecGuestAttributePid`. The audit token is a kernel-issued, immutable snapshot
    /// of the connecting process's identity captured at connection-establishment time,
    /// not a reusable integer — unlike a PID, it cannot be raced by a process exiting
    /// and a new (potentially hostile) process reusing the same PID between the kernel
    /// reporting it and our lookup. `SecCodeCopyGuestWithAttributes` is called with
    /// `kSecGuestAttributeAudit` (a public, documented Security.framework attribute
    /// key) keyed on that token, so the resulting SecCode is bound to the exact peer
    /// process that opened this specific connection. If the audit token cannot be
    /// obtained (selector missing/failed, e.g. on a future SDK that changes Foundation's
    /// private internals), we fail closed — the connection is rejected rather than
    /// silently falling back to the weaker PID check. Since CurtainHelper is a
    /// non-sandboxed LaunchDaemon (not an App Store target), calling this private-but-
    /// runtime-verified selector is acceptable; it is not linked against any private
    /// framework and does not touch App Store review surfaces.
    ///
    /// Relaxation path for local dev ONLY: an ad-hoc / unsigned build has no Team ID.
    /// When neither this helper nor the caller has a Team ID, we fall back to the
    /// identifier+anchor check alone so a locally-built ad-hoc app can still be tested.
    /// That relaxation is LOGGED loudly. In the signed case (this helper has a Team ID)
    /// a Team-ID mismatch or a missing caller Team ID is always rejected.
    ///
    /// ACCEPTED RISK: the ad-hoc-build relaxation path (identifier+anchor only, no
    /// Team-ID pinning) remains a soft/forgeable binding until Developer-ID signing
    /// lands (E-02) — there is no Team ID to pin against on an ad-hoc build by
    /// construction. Closing the audit-token TOCTOU race does not remove this separate,
    /// structural gap; it is superseded (not fixed) by this ticket and stays an
    /// explicitly accepted risk for local/ad-hoc builds only.
    private func isTrustedCaller(_ conn: NSXPCConnection) -> Bool {
        guard let token = Self.auditToken(of: conn) else {
            HelperLog.error("rejected connection — could not obtain audit token")
            return false
        }
        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        let attrs: [String: Any] = [
            kSecGuestAttributeAudit as String: tokenData
        ]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code) == errSecSuccess,
            let guestCode = code
        else {
            return false
        }

        let ourTeamID = Self.ownTeamID()
        let callerTeamID = Self.teamID(of: guestCode)

        // Team-ID trust pre-check branch logic is extracted to CurtainHelperCore's
        // TrustDecision.evaluate (pure, unit tested) — this call site only maps
        // its result onto the same log lines and control flow as before, then
        // always runs the REAL SecCodeCheckValidity check below on the accept
        // paths, exactly as pre-extraction. The pre-check itself never replaces
        // or bypasses that cryptographic verification.
        let reqString: String
        switch TrustDecision.evaluate(ourTeamID: ourTeamID, callerTeamID: callerTeamID) {
        case .reject:
            HelperLog.error(
                "rejected connection — caller Team ID mismatch (ours=\(ourTeamID ?? "<none>"), caller=\(callerTeamID ?? "<none>"))"
            )
            return false
        case .acceptWithTeamIDPinning(_, let requirementString):
            reqString = requirementString
        case .acceptRelaxedAdHoc(let requirementString):
            // Ad-hoc / unsigned local dev: no Team ID on this helper. Accept the
            // identifier+anchor check alone, and log the relaxation loudly.
            HelperLog.warning("accepting caller without Team-ID pinning (ad-hoc/local dev build)")
            reqString = requirementString
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &requirement) == errSecSuccess,
            let req = requirement
        else {
            return false
        }
        return SecCodeCheckValidity(guestCode, [], req) == errSecSuccess
    }

    /// C function-pointer signature matching `-[NSXPCConnection auditToken]`, which
    /// returns the connection's kernel-issued `audit_token_t` by value (an 8-word
    /// struct, ABI-compatible with a plain `objc_msgSend` struct-return on arm64/x86_64
    /// since it fits in registers). We reach it via the Objective-C runtime rather than
    /// a compile-time declaration because Foundation's public `NSXPCConnection` header
    /// does not expose this accessor.
    private typealias AuditTokenIMP = @convention(c) (AnyObject, Selector) -> audit_token_t

    /// Resolve the connecting peer's audit token from a live `NSXPCConnection`, or
    /// `nil` if the runtime does not implement the accessor (fail-closed caller in
    /// `isTrustedCaller` treats `nil` as "reject").
    private static func auditToken(of conn: NSXPCConnection) -> audit_token_t? {
        let selector = NSSelectorFromString("auditToken")
        guard conn.responds(to: selector) else { return nil }
        let imp = conn.method(for: selector)
        let fn = unsafeBitCast(imp, to: AuditTokenIMP.self)
        return fn(conn, selector)
    }

    /// Team ID of this running helper, or nil for an ad-hoc/unsigned build.
    private static func ownTeamID() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
            let staticCode = staticRef
        else { return nil }
        return teamID(ofStatic: staticCode)
    }

    /// Team ID of a connecting guest code, or nil if it carries none (ad-hoc/unsigned).
    private static func teamID(of code: SecCode) -> String? {
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
            let staticCode = staticRef
        else { return nil }
        return teamID(ofStatic: staticCode)
    }

    private static func teamID(ofStatic staticCode: SecStaticCode) -> String? {
        var infoRef: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &infoRef) == errSecSuccess,
            let info = infoRef as? [String: Any],
            let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
            !teamID.isEmpty
        else {
            return nil
        }
        return teamID
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: CurtainHelperInfo.machServiceName)
listener.delegate = delegate
listener.resume()
NSLog("CurtainHelper: listening on %@", CurtainHelperInfo.machServiceName)

// Daemons never return from main; park on the run loop forever.
RunLoop.current.run()
