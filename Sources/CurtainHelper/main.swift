import Foundation
import Security
import CurtainShared

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

/// Implements the XPC contract. One instance is exported per accepted connection.
final class DisconnectService: NSObject, CurtainDisconnectXPC, @unchecked Sendable {
    func endScreenSharingSession(reply: @escaping (Bool) -> Void) {
        // launchd owns the screensharingd listener and respawns it, so terminating
        // these processes drops the live session without killing the service itself.
        let targets: [[String]] = [
            ["pkill", "-f", "ScreenSharingSubscriber"],
            ["pkill", "-x", "screensharingd"],
            ["pkill", "-f", "RemoteManagement.*[Ss]creen"],
        ]
        var matched = false
        for argv in targets where runMatched(argv) { matched = true }
        reply(matched)
    }

    /// Run a pkill-style command. Returns true when pkill exits 0 (a process matched).
    private func runMatched(_ argv: [String]) -> Bool {
        guard let tool = argv.first else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/" + tool)
        p.arguments = Array(argv.dropFirst())
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            NSLog("CurtainHelper: failed to run %@: %@", tool, String(describing: error))
            return false
        }
    }
}

/// Accepts XPC connections only from a copy of the Curtain app signed by the same
/// Developer-ID identity. Rejects everything else.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    nonisolated func listener(_ listener: NSXPCListener,
                              shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard isTrustedCaller(conn) else {
            NSLog("CurtainHelper: rejected connection — caller failed code-signature check")
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: CurtainDisconnectXPC.self)
        conn.exportedObject = DisconnectService()
        conn.resume()
        return true
    }

    /// Validate the connecting client by PID: the caller must be a valid code signed
    /// with our bundle identifier and an Apple-issued anchor, AND — when both sides
    /// expose a Team ID — the Team IDs must match. This means only a properly-signed
    /// copy of Curtain (our identity) can drive the privileged helper. (NSXPCConnection
    /// does not surface its audit token to Swift, so we resolve the guest code from the
    /// connecting PID, which the kernel reports for the live XPC peer.)
    ///
    /// SECURITY NOTE — PID-reuse TOCTOU race: SecCodeCopyGuestWithAttributes keyed on
    /// a PID is inherently subject to a time-of-check/time-of-use race. Between the
    /// moment the kernel delivers the PID to our listener and the moment we call
    /// SecCodeCopyGuestWithAttributes, the original process could exit and a different
    /// (potentially hostile) process could occupy the same PID. The gold-standard fix is
    /// to key on the XPC audit token instead, but NSXPCConnection does not expose its
    /// audit token via a public Swift API in the current SDK. Migrating to an
    /// audit-token-keyed check (via a private/ObjC bridging shim or a future SDK
    /// addition) is queued for the notarized public build — at that point the Helper will
    /// also carry a Developer-ID signature, making the Team-ID pinning the primary
    /// guard and the audit token the defense-in-depth layer. Until then, the PID check
    /// is the best available option and the risk is accepted under the assumption that
    /// only trusted admins install the daemon.
    ///
    /// Relaxation path for local dev ONLY: an ad-hoc / unsigned build has no Team ID.
    /// When neither this helper nor the caller has a Team ID, we fall back to the
    /// identifier+anchor check alone so a locally-built ad-hoc app can still be tested.
    /// That relaxation is LOGGED loudly. In the signed case (this helper has a Team ID)
    /// a Team-ID mismatch or a missing caller Team ID is always rejected.
    private func isTrustedCaller(_ conn: NSXPCConnection) -> Bool {
        let attrs: [String: Any] = [
            kSecGuestAttributePid as String: NSNumber(value: conn.processIdentifier)
        ]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code) == errSecSuccess,
              let guestCode = code else {
            return false
        }

        let ourTeamID = Self.ownTeamID()
        let callerTeamID = Self.teamID(of: guestCode)

        // Build the code-signing requirement. When a Team ID is available on both
        // sides, pin it so only our signed identity is accepted.
        var reqString = "identifier \"io.acamarata.curtain\" and anchor apple generic"
        if let ourTeamID, !ourTeamID.isEmpty {
            // Signed helper: require the caller to carry a matching Team ID.
            guard let callerTeamID, callerTeamID == ourTeamID else {
                NSLog("CurtainHelper: rejected connection — caller Team ID mismatch (ours=%@, caller=%@)",
                      ourTeamID, callerTeamID ?? "<none>")
                return false
            }
            reqString += " and certificate leaf[subject.OU] = \"\(ourTeamID)\""
        } else {
            // Ad-hoc / unsigned local dev: no Team ID on this helper. Accept the
            // identifier+anchor check alone, and log the relaxation loudly.
            NSLog("CurtainHelper: WARNING — accepting caller without Team-ID pinning (ad-hoc/local dev build)")
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            return false
        }
        return SecCodeCheckValidity(guestCode, [], req) == errSecSuccess
    }

    /// Team ID of this running helper, or nil for an ad-hoc/unsigned build.
    private static func ownTeamID() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return nil }
        return teamID(ofStatic: staticCode)
    }

    /// Team ID of a connecting guest code, or nil if it carries none (ad-hoc/unsigned).
    private static func teamID(of code: SecCode) -> String? {
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return nil }
        return teamID(ofStatic: staticCode)
    }

    private static func teamID(ofStatic staticCode: SecStaticCode) -> String? {
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty else {
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
