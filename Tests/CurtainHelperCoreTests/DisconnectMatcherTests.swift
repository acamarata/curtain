import XCTest
@testable import CurtainHelperCore

/// Purpose: Unit coverage for `DisconnectMatcher`'s pure path-matching and
///          any-of-N OR-reduction logic (T-P1-E05-05), extracted from
///          `CurtainHelper.DisconnectService.killByExactPath` /
///          `endScreenSharingSession`. No process enumeration, no `kill(2)` —
///          plain string/bool data only.
/// Inputs: none (pure function tests).
/// Outputs: none (assertions only).
/// Constraints: XCTest, `@testable import CurtainHelperCore`.
/// SPORT: MASTER-DISCONNECT
final class DisconnectMatcherTests: XCTestCase {

    // MARK: - pathMatches

    func testPathMatches_exactMatch() {
        XCTAssertTrue(
            DisconnectMatcher.pathMatches(
                "/System/Library/PrivateFrameworks/RemoteManagement.framework/XPCServices/ScreenSharingSubscriber.xpc/Contents/MacOS/ScreenSharingSubscriber",
                expectedPaths: [
                    "/System/Library/PrivateFrameworks/RemoteManagement.framework/XPCServices/ScreenSharingSubscriber.xpc/Contents/MacOS/ScreenSharingSubscriber"
                ]))
    }

    func testPathMatches_noMatch() {
        XCTAssertFalse(
            DisconnectMatcher.pathMatches(
                "/bin/cat",
                expectedPaths: ["/System/Library/PrivateFrameworks/RemoteManagement.framework/RemoteManagementAgent"]))
    }

    func testPathMatches_argvSpoofDoesNotMatch() {
        // A process renaming its argv[0] to look like the target does not change
        // its RESOLVED executable path — the whole point of exact-path matching
        // over the old `pkill -f` argv-substring approach. This test documents
        // that the pure matcher only ever compares resolved paths.
        XCTAssertFalse(
            DisconnectMatcher.pathMatches(
                "/bin/cat",  // real resolved executable, regardless of what argv claims
                expectedPaths: [
                    "/System/Library/PrivateFrameworks/RemoteManagement.framework/XPCServices/ScreenSharingSubscriber.xpc/Contents/MacOS/ScreenSharingSubscriber"
                ]))
    }

    func testPathMatches_matchesOneOfMultipleTargets() {
        let targets = [
            "/System/Library/PrivateFrameworks/RemoteManagement.framework/RemoteManagementAgent",
            "/System/Library/CoreServices/RemoteManagement/ScreensharingAgent.bundle/Contents/MacOS/ScreensharingAgent"
        ]
        XCTAssertTrue(DisconnectMatcher.pathMatches(targets[1], expectedPaths: targets))
    }

    // MARK: - anyMatched

    func testAnyMatched_allFalse() {
        XCTAssertFalse(DisconnectMatcher.anyMatched([false, false, false]))
    }

    func testAnyMatched_oneOfThreeTrue() {
        // Mirrors endScreenSharingSession's three independent kill strategies —
        // any-of-three semantics, not all-of-three.
        XCTAssertTrue(DisconnectMatcher.anyMatched([false, true, false]))
    }

    func testAnyMatched_allTrue() {
        XCTAssertTrue(DisconnectMatcher.anyMatched([true, true, true]))
    }

    func testAnyMatched_emptyIsFalse() {
        XCTAssertFalse(DisconnectMatcher.anyMatched([]))
    }
}
