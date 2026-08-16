import Foundation
import Security

/// Purpose: Signing-check gate for the disconnect helper's sudoers fallback — decides
///          whether the running app is a properly-signed (Developer-ID) build, which
///          must NEVER use the sudoers fallback in DisconnectClient+SudoersInstall.swift.
/// Inputs: The running app's own code signature (via Security.framework SecCode APIs).
/// Outputs: `Bool` — true only for a real, non-ad-hoc signature with a Team ID.
/// Constraints: @MainActor (matches DisconnectClient; the check itself does no UI work
///              but stays on the same actor as its caller, `setEnabled(_:)`). Pure,
///              synchronous, no I/O beyond reading the app's own signature.
///
/// MARK: - Sudoers-is-dev-only rule
///
/// The sudoers fallback writes a NOPASSWD rule into /etc/sudoers.d. That is an
/// acceptable convenience for a developer running a locally-built, ad-hoc/unsigned
/// app on their own machine — but it must NEVER ship inside a notarized public
/// build, where it would be a privilege-escalation footgun. The hard rule:
///
///   - A properly-signed build (real Developer-ID / Team ID, not ad-hoc) uses the
///     SMAppService.daemon path ONLY. If that fails it reports the failure and stops.
///   - The sudoers fallback is reachable ONLY when isProperlySigned() == false, i.e.
///     an ad-hoc / dev / unsigned build that genuinely cannot register a daemon.
///
/// isProperlySigned() inspects the running app's own code signature. An ad-hoc
/// signature carries no Team ID and sets the adhoc flag; a real Developer-ID
/// signature carries a Team ID and clears that flag. We treat "has a Team ID and is
/// not ad-hoc" as properly signed.
///
/// MARK: - Signing-identity fingerprint (T-P1-E02-02)
///
/// `currentSigningFingerprint()` reuses the exact same SecCode/SecStaticCode
/// inspection as `isProperlySigned()` (via the shared `signingInfo()` helper) to build
/// a persistable string identifying "which code identity registered the disconnect
/// helper." DisconnectClient persists this at successful registration time and
/// compares it again at next launch so an ad-hoc-to-Developer-ID upgrade (or any
/// future Team ID change) is detected instead of silently leaving a daemon/sudoers
/// registration keyed to a code identity that no longer matches the running binary.
/// SPORT: MASTER-DISCONNECT
extension DisconnectClient {
    /// Shared signature inspection: `SecCodeCopySelf` → `SecCodeCopyStaticCode` →
    /// `SecCodeCopySigningInformation`, once. Both `isProperlySigned()` and
    /// `currentSigningFingerprint()` call this rather than each independently driving
    /// the SecCode APIs, so there is exactly one place that reads the running binary's
    /// signature. Returns nil if any step fails (unsigned, unreadable, etc.).
    private static func signingInfo() -> [String: Any]? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else {
            return nil
        }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
            let staticCode = staticRef
        else {
            return nil
        }
        var infoRef: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &infoRef) == errSecSuccess,
            let info = infoRef as? [String: Any]
        else {
            return nil
        }
        return info
    }

    /// True only for a real (Developer-ID / non-ad-hoc) signature on the running app.
    /// Used to gate the sudoers fallback so a notarized public build can never install
    /// a sudoers rule. Fails closed (returns true → blocks the fallback) only when the
    /// signing info is unreadable AND a Team ID is present; an unreadable signature with
    /// no Team ID is treated as unsigned/ad-hoc so local dev still works.
    static func isProperlySigned() -> Bool {
        guard let info = signingInfo() else { return false }

        // An ad-hoc signature sets the adhoc bit in the code-signing flags.
        if let flags = info[kSecCodeInfoFlags as String] as? UInt32 {
            let adhocFlag: UInt32 = 0x2  // kSecCodeSignatureAdhoc
            if flags & adhocFlag != 0 { return false }
        }

        // A real Developer-ID signature carries a Team ID; ad-hoc signatures do not.
        guard let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
            !teamID.isEmpty
        else {
            return false
        }
        return true
    }

    /// Build a stable string fingerprint of the running binary's code identity: Team ID
    /// (empty when absent) plus the ad-hoc flag, so an ad-hoc build and a Developer-ID
    /// build always produce different fingerprints even if a Team ID were somehow
    /// blank in both (defensive — in practice ad-hoc never carries a Team ID). Reuses
    /// `signingInfo()` rather than re-driving the SecCode APIs. Returns nil only when
    /// the running binary's own signature cannot be read at all, which should not
    /// happen for a running process but is handled defensively — callers must treat
    /// nil as "cannot determine, do not persist / do not compare."
    static func currentSigningFingerprint() -> String? {
        guard let info = signingInfo() else { return nil }
        let teamID = (info[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""
        var isAdhoc = false
        if let flags = info[kSecCodeInfoFlags as String] as? UInt32 {
            let adhocFlag: UInt32 = 0x2  // kSecCodeSignatureAdhoc
            isAdhoc = (flags & adhocFlag != 0)
        }
        return "\(teamID)|adhoc=\(isAdhoc)"
    }
}
