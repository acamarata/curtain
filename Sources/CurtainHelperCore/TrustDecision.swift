import Foundation

/// Purpose: Pure Team-ID trust pre-check logic pulled out of
///          `CurtainHelper.ListenerDelegate.isTrustedCaller`, so the
///          accept/reject BRANCH STRUCTURE is unit testable without a live XPC
///          connection, a real audit token, or a call into
///          `SecCodeCopyGuestWithAttributes`/`SecCodeCheckValidity`. This models
///          only the decision of what happens BEFORE the real SecCode validity
///          check runs — it never replaces that check. The actual
///          `SecCodeCheckValidity` call (the cryptographic code-signature
///          verification) always still runs afterward in
///          `CurtainHelper/main.swift`, using the exact requirement string this
///          type builds.
/// Inputs: `ourTeamID: String?` (this helper's own Team ID, nil for an
///         ad-hoc/unsigned build) and `callerTeamID: String?` (the connecting
///         guest code's Team ID, nil if it carries none).
/// Outputs: `TrustPreCheck` — `.reject(reason:)`, `.acceptWithTeamIDPinning
///          (teamID:requirementString:)`, or `.acceptRelaxedAdHoc
///          (requirementString:)`.
/// Constraints: zero dependencies beyond Foundation. No Security.framework
///              calls here — this is pure string/optional logic only.
/// SPORT: MASTER-DISCONNECT
public enum TrustDecision {

    /// Base code-signing requirement string every accept path uses, with an
    /// optional Team-ID-pinning clause appended when a Team ID is available on
    /// both sides. Exposed so tests (and the real caller) can confirm the exact
    /// format matches `isTrustedCaller`'s original inline string construction.
    public static let baseRequirement = "identifier \"io.acamarata.curtain\" and anchor apple generic"

    /// Outcome of the Team-ID trust pre-check, run before the real
    /// `SecCodeCheckValidity` call. Only `.acceptWithTeamIDPinning` and
    /// `.acceptRelaxedAdHoc` proceed to that real check; `.reject` short-circuits
    /// the connection immediately, matching `isTrustedCaller`'s early `return false`.
    public enum TrustPreCheck: Equatable {
        /// Caller failed the Team-ID pre-check; the connection must be rejected
        /// without ever reaching `SecCodeCheckValidity`. `reason` is for logging.
        case reject(reason: String)
        /// This helper has a Team ID and the caller's matches it. `requirementString`
        /// includes the `certificate leaf[subject.OU]` pinning clause.
        case acceptWithTeamIDPinning(teamID: String, requirementString: String)
        /// Neither side has a Team ID (ad-hoc/local dev). Accept the relaxed,
        /// identifier+anchor-only check; the caller must log this loudly.
        case acceptRelaxedAdHoc(requirementString: String)
    }

    /// Evaluate the Team-ID trust pre-check, mirroring `isTrustedCaller`'s branch
    /// structure exactly:
    /// - `ourTeamID` non-nil/non-empty + `callerTeamID` nil or mismatched -> reject
    ///   (this happens BEFORE the SecCode validity check in the original code).
    /// - `ourTeamID` non-nil/non-empty + `callerTeamID` matches -> accept, pinning
    ///   the requirement string to that Team ID's certificate OU.
    /// - `ourTeamID` nil/empty (ad-hoc/unsigned helper build) -> accept relaxed,
    ///   regardless of `callerTeamID` (an ad-hoc helper cannot pin anything).
    public static func evaluate(ourTeamID: String?, callerTeamID: String?) -> TrustPreCheck {
        guard let ourTeamID, !ourTeamID.isEmpty else {
            return .acceptRelaxedAdHoc(requirementString: baseRequirement)
        }
        guard let callerTeamID, callerTeamID == ourTeamID else {
            return .reject(reason: "caller Team ID mismatch (ours=\(ourTeamID), caller=\(callerTeamID ?? "<none>"))")
        }
        let pinned = baseRequirement + " and certificate leaf[subject.OU] = \"\(ourTeamID)\""
        return .acceptWithTeamIDPinning(teamID: ourTeamID, requirementString: pinned)
    }
}
