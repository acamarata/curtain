import XCTest
@testable import CurtainHelperCore

/// Purpose: Unit coverage for `TrustDecision.evaluate`'s Team-ID trust
///          pre-check branch logic (T-P1-E05-05), extracted from
///          `CurtainHelper.ListenerDelegate.isTrustedCaller`. Confirms the
///          accept/reject decision and the exact `SecRequirement` string format
///          for each branch — NOT the real `SecCodeCheckValidity` call, which
///          always still runs for real in `CurtainHelper/main.swift` after this
///          pre-check passes and is out of reach of a unit test (requires a
///          live XPC connection + real code signature).
/// Inputs: none (pure function tests).
/// Outputs: none (assertions only).
/// Constraints: XCTest, `@testable import CurtainHelperCore`.
/// SPORT: MASTER-DISCONNECT
final class TrustDecisionTests: XCTestCase {

    func testEvaluate_bothTeamIDsNil_acceptsRelaxedAdHoc() {
        let result = TrustDecision.evaluate(ourTeamID: nil, callerTeamID: nil)
        guard case .acceptRelaxedAdHoc(let reqString) = result else {
            return XCTFail("expected .acceptRelaxedAdHoc, got \(result)")
        }
        XCTAssertEqual(reqString, TrustDecision.baseRequirement)
        XCTAssertFalse(reqString.contains("certificate leaf"))
    }

    func testEvaluate_ourTeamIDEmptyString_treatedAsAdHoc() {
        // Matches the original `!ourTeamID.isEmpty` guard: an empty string, not
        // just nil, is also treated as "no Team ID."
        let result = TrustDecision.evaluate(ourTeamID: "", callerTeamID: "ANYCALLER")
        guard case .acceptRelaxedAdHoc = result else {
            return XCTFail("expected .acceptRelaxedAdHoc, got \(result)")
        }
    }

    func testEvaluate_oursSetCallerNil_rejects() {
        let result = TrustDecision.evaluate(ourTeamID: "TEAM123", callerTeamID: nil)
        guard case .reject(let reason) = result else {
            return XCTFail("expected .reject, got \(result)")
        }
        XCTAssertTrue(reason.contains("TEAM123"))
        XCTAssertTrue(reason.contains("<none>"))
    }

    func testEvaluate_oursSetCallerMismatched_rejects() {
        let result = TrustDecision.evaluate(ourTeamID: "TEAM123", callerTeamID: "TEAM456")
        guard case .reject(let reason) = result else {
            return XCTFail("expected .reject, got \(result)")
        }
        XCTAssertTrue(reason.contains("TEAM123"))
        XCTAssertTrue(reason.contains("TEAM456"))
    }

    func testEvaluate_oursSetCallerMatches_acceptsWithPinning() {
        let result = TrustDecision.evaluate(ourTeamID: "TEAM123", callerTeamID: "TEAM123")
        guard case .acceptWithTeamIDPinning(let teamID, let reqString) = result else {
            return XCTFail("expected .acceptWithTeamIDPinning, got \(result)")
        }
        XCTAssertEqual(teamID, "TEAM123")
        // Confirm the exact requirement string format matches the original
        // inline construction in isTrustedCaller: base + OU-pinning clause.
        let expected =
            "identifier \"io.acamarata.curtain\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAM123\""
        XCTAssertEqual(reqString, expected)
    }

    func testBaseRequirement_matchesOriginalInlineFormat() {
        XCTAssertEqual(TrustDecision.baseRequirement, "identifier \"io.acamarata.curtain\" and anchor apple generic")
    }
}
