import XCTest
@testable import CurtainCore

/// Purpose: Unit coverage for the pure decision logic pulled out of
///          `CurtainController`/`CurtainController+DisplayReconciliation` in
///          T-P1-E05-05 — `reconcileDiff` (UUID-identity topology diff) and
///          `sharingType` (cover-window sharingType decision). Both are pure
///          functions over `String`/`Set<String>`/`Bool` values with no
///          `NSScreen` dependency, extracted specifically because `NSScreen`
///          has no public initializer and its `deviceDescription` keys cannot
///          be meaningfully faked without a real display server — the rest of
///          `CurtainController` (`reconcile()`, `uuid(of:)`, `isDisplayLink()`)
///          stays untested here for that reason (see the file-level note below
///          on `verifyNoneCoverHidden`).
/// Inputs: none (pure function tests).
/// Outputs: none (assertions only).
/// Constraints: XCTest, `@testable import CurtainCore`. No AppKit window/screen
///              objects are created anywhere in this file.
/// SPORT: MASTER-CURTAIN
final class CurtainControllerTests: XCTestCase {

    // MARK: - reconcileDiff

    func testReconcileDiff_displayAdded() {
        // A brand-new UUID appears in the live set with nothing covered yet.
        let diff = CurtainController.reconcileDiff(coveredUUIDs: [], liveUUIDs: ["A"])
        XCTAssertEqual(diff.toAdd, ["A"])
        XCTAssertTrue(diff.toDrop.isEmpty)
    }

    func testReconcileDiff_displayRemoved() {
        // A previously-covered UUID is no longer in the live set (unplugged).
        let diff = CurtainController.reconcileDiff(coveredUUIDs: ["A"], liveUUIDs: [])
        XCTAssertEqual(diff.toDrop, ["A"])
        XCTAssertTrue(diff.toAdd.isEmpty)
    }

    func testReconcileDiff_reorderDoesNotDropOrAdd() {
        // The critical regression case: the same two displays present before and
        // after, but NSScreen.screens could in principle report them in a
        // different enumeration order after a hot-plug event settles (e.g. macOS
        // renumbers screens after a brief disconnect/reconnect blip). Because the
        // diff operates on Set<String> keyed by stable UUID — never by array
        // index or position — a reorder must produce empty toDrop AND empty
        // toAdd. An index-based implementation (e.g. comparing screens[0] to
        // covers[0]) would incorrectly treat this as "both displays changed."
        let covered: Set<String> = ["A", "B"]
        // Same UUIDs, constructed via a differently-ordered literal/insertion
        // sequence to simulate a reordered live enumeration. Set equality is
        // order-independent by definition, which is exactly the property under
        // test: reconcileDiff must not care about insertion/enumeration order.
        let liveReordered: Set<String> = ["B", "A"]

        let diff = CurtainController.reconcileDiff(coveredUUIDs: covered, liveUUIDs: liveReordered)
        XCTAssertTrue(diff.toDrop.isEmpty, "reorder must not drop any survivor")
        XCTAssertTrue(diff.toAdd.isEmpty, "reorder must not re-add any survivor")
    }

    func testReconcileDiff_hotSwapAddAndRemoveSimultaneously() {
        // One display unplugged (A) while a different one is plugged in (C) in
        // the same reconcile pass, with B surviving unchanged throughout.
        let covered: Set<String> = ["A", "B"]
        let live: Set<String> = ["B", "C"]

        let diff = CurtainController.reconcileDiff(coveredUUIDs: covered, liveUUIDs: live)
        XCTAssertEqual(diff.toDrop, ["A"])
        XCTAssertEqual(diff.toAdd, ["C"])
    }

    func testReconcileDiff_noChangeIsEmptyBothWays() {
        let same: Set<String> = ["A", "B", "C"]
        let diff = CurtainController.reconcileDiff(coveredUUIDs: same, liveUUIDs: same)
        XCTAssertTrue(diff.toDrop.isEmpty)
        XCTAssertTrue(diff.toAdd.isEmpty)
    }

    // MARK: - sharingType

    func testSharingType_nativeDisplayDefaultsToNone() {
        let result = CurtainController.sharingType(
            isDisplayLink: false, forceNewDisplay: false, newDisplayPolicy: "cover")
        XCTAssertEqual(result, .none)
    }

    func testSharingType_displayLinkIsAlwaysReadOnly() {
        // A DisplayLink display only exists via capture, so it must stay
        // .readOnly regardless of forceNewDisplay/policy.
        let result = CurtainController.sharingType(
            isDisplayLink: true, forceNewDisplay: false, newDisplayPolicy: "cover")
        XCTAssertEqual(result, .readOnly)
    }

    func testSharingType_newDisplayTreatedAsDisplayLinkPolicy() {
        // A brand-new, unrecognized display under the "treatAsDisplayLink" policy
        // is forced .readOnly even though isDisplayLink itself is false — the
        // policy assumes an unfamiliar panel might be hardware-private until the
        // user classifies it.
        let result = CurtainController.sharingType(
            isDisplayLink: false, forceNewDisplay: true, newDisplayPolicy: "treatAsDisplayLink")
        XCTAssertEqual(result, .readOnly)
    }

    func testSharingType_newDisplayUnderOtherPolicyStaysNone() {
        // Any other new-display policy value ("cover", "leaveUncovered", or
        // anything unrecognized) does not force .readOnly on its own.
        XCTAssertEqual(
            CurtainController.sharingType(isDisplayLink: false, forceNewDisplay: true, newDisplayPolicy: "cover"), .none
        )
        XCTAssertEqual(
            CurtainController.sharingType(
                isDisplayLink: false, forceNewDisplay: true, newDisplayPolicy: "leaveUncovered"), .none)
        XCTAssertEqual(
            CurtainController.sharingType(
                isDisplayLink: false, forceNewDisplay: true, newDisplayPolicy: "unknown-value"), .none)
    }

    func testSharingType_forceNewDisplayFalseIgnoresPolicy() {
        // Survivor-update path (reconcile()'s per-live-screen loop) always calls
        // this with forceNewDisplay defaulted to false — confirm the policy
        // string is irrelevant in that case, matching pre-extraction behavior
        // where the survivor path never consulted newDisplayPolicy at all.
        let result = CurtainController.sharingType(isDisplayLink: false, newDisplayPolicy: "treatAsDisplayLink")
        XCTAssertEqual(result, .none)
    }

    // MARK: - CoverWindow.allowsKeyForAccessibility (T-P1-E07-01)
    //
    // Unlike NSScreen, NSWindow has a public, headless-safe initializer, so this
    // narrow trust-boundary exception (PasswordBox's AccessibleField path) is
    // directly unit testable without a live display. These tests confirm the
    // default-safe state (never key, matching the original hardcoded `false`
    // this ticket replaced) and that the flag genuinely gates both
    // canBecomeKey and canBecomeMain together, since PasswordBox toggles only
    // `allowsKeyForAccessibility` and relies on both derived properties moving
    // with it.

    @MainActor
    func testCoverWindow_defaultsToNeverKey_matchingPreTicketBehavior() {
        let w = CoverWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        XCTAssertFalse(w.canBecomeKey)
        XCTAssertFalse(w.canBecomeMain)
    }

    @MainActor
    func testCoverWindow_allowsKeyForAccessibility_grantsKeyAndMainTogether() {
        let w = CoverWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        w.allowsKeyForAccessibility = true
        XCTAssertTrue(w.canBecomeKey)
        XCTAssertTrue(w.canBecomeMain)
    }

    @MainActor
    func testCoverWindow_allowsKeyForAccessibility_revokesBackToDefaultSafeState() {
        // Mirrors PasswordBox.refreshAccessibleFieldVisibility()'s detach branch:
        // the flag must be a live toggle, not a one-way grant, so a window is
        // never left key after the accessible field is removed.
        let w = CoverWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        w.allowsKeyForAccessibility = true
        w.allowsKeyForAccessibility = false
        XCTAssertFalse(w.canBecomeKey)
        XCTAssertFalse(w.canBecomeMain)
    }
}

// MARK: - shouldCover(uuid:isNew:) — KVM-exclusion category (T-P1-E13-01)
//
// `shouldCover` reads `Settings` directly (coverScope, newDisplayPolicy,
// perDisplayCoverDisabled, kvmExcludedDisplayUUIDs), so — unlike the pure
// `reconcileDiff`/`sharingType` helpers above — these tests redirect
// `Settings.d` to an isolated `UserDefaults(suiteName:)` instance (the same
// T-P1-E05-03 seam `SessionCoordinatorTests` uses) rather than faking
// arguments. `CurtainController` itself has a plain, headless-safe `init()`
// (no `NSScreen`/window construction happens until `show()`/`makeCover()`
// are called), so it can be instantiated directly here.
@MainActor
final class CurtainControllerShouldCoverKVMExclusionTests: XCTestCase {

    private var suiteName: String!
    private var originalDefaults: UserDefaults!
    private var sut: CurtainController!

    override func setUp() {
        super.setUp()
        suiteName = "CurtainControllerShouldCoverKVMExclusionTests.\(UUID().uuidString)"
        originalDefaults = Settings.d
        let isolated = UserDefaults(suiteName: suiteName)!
        isolated.removePersistentDomain(forName: suiteName)
        Settings.d = isolated
        sut = CurtainController()
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        Settings.d = originalDefaults
        sut = nil
        super.tearDown()
    }

    private let excludedUUID = "KVM-EXCLUDED-UUID"
    private let otherUUID = "OTHER-UUID"

    /// Every (coverScope, newDisplayPolicy, isNew) combination must return
    /// false for an excluded UUID — the KVM-exclusion gate is unconditional,
    /// checked before any of that other logic runs.
    func testShouldCover_excludedUUID_falseUnderEveryCoverScopeAndPolicyCombo() {
        Settings.kvmExcludedDisplayUUIDs = [excludedUUID]

        let coverScopes = ["all", "perDisplay", "onlyMarked", "allExceptMarked", "unknown"]
        let newDisplayPolicies = ["cover", "leaveUncovered", "treatAsDisplayLink", "unknown"]

        for scope in coverScopes {
            Settings.d.set(scope, forKey: Settings.Key.coverScope)
            for policy in newDisplayPolicies {
                Settings.d.set(policy, forKey: Settings.Key.newDisplayPolicy)
                XCTAssertFalse(
                    sut.shouldCover(uuid: excludedUUID, isNew: true),
                    "isNew=true should be false for excluded UUID (scope=\(scope), policy=\(policy))")
                XCTAssertFalse(
                    sut.shouldCover(uuid: excludedUUID, isNew: false),
                    "isNew=false should be false for excluded UUID (scope=\(scope), policy=\(policy))")
            }
        }
    }

    /// Even if a display is ALSO on the legacy per-display-disabled list (which
    /// alone would just mean "uncovered under perDisplay scope"), the KVM
    /// exclusion is the same, permanent "never build a cover" outcome — no
    /// interaction/priority ambiguity between the two lists.
    func testShouldCover_excludedUUID_alsoOnPerDisplayDisabledList_stillFalse() {
        Settings.kvmExcludedDisplayUUIDs = [excludedUUID]
        Settings.perDisplayCoverDisabled = [excludedUUID]
        Settings.d.set("all", forKey: Settings.Key.coverScope)

        XCTAssertFalse(sut.shouldCover(uuid: excludedUUID, isNew: false))
    }

    /// A non-excluded UUID is completely unaffected by another display being
    /// on the KVM-exclusion list — the check is purely identity (UUID) driven.
    func testShouldCover_nonExcludedUUID_unaffectedByOtherDisplaysExclusion() {
        Settings.kvmExcludedDisplayUUIDs = [excludedUUID]
        Settings.d.set("all", forKey: Settings.Key.coverScope)

        XCTAssertTrue(sut.shouldCover(uuid: otherUUID, isNew: false))
        XCTAssertTrue(sut.shouldCover(uuid: otherUUID, isNew: true))
    }

    // MARK: - Regression guard: native (.none) and DisplayLink (.readOnly)
    // categories are unchanged by adding the KVM-exclusion gate.

    func testShouldCover_regression_perDisplayScope_nativeDisplayToggleUnchanged() {
        Settings.d.set("perDisplay", forKey: Settings.Key.coverScope)
        Settings.perDisplayCoverDisabled = []
        XCTAssertTrue(sut.shouldCover(uuid: otherUUID, isNew: false), "not disabled -> covered")

        Settings.perDisplayCoverDisabled = [otherUUID]
        XCTAssertFalse(sut.shouldCover(uuid: otherUUID, isNew: false), "disabled -> uncovered")
    }

    func testShouldCover_regression_allScope_alwaysCoveredRegardlessOfToggle() {
        Settings.d.set("all", forKey: Settings.Key.coverScope)
        Settings.perDisplayCoverDisabled = [otherUUID]
        XCTAssertTrue(
            sut.shouldCover(uuid: otherUUID, isNew: false),
            "'all' scope covers every non-excluded display regardless of the per-display toggle")
    }

    func testShouldCover_regression_newDisplayPolicy_leaveUncovered() {
        Settings.d.set("leaveUncovered", forKey: Settings.Key.newDisplayPolicy)
        XCTAssertFalse(sut.shouldCover(uuid: otherUUID, isNew: true))
    }

    func testShouldCover_regression_newDisplayPolicy_treatAsDisplayLinkStillCovers() {
        // shouldCover() only decides whether a cover is built at all; whether it
        // ends up .readOnly is sharingType's job (see sharingType tests above).
        Settings.d.set("treatAsDisplayLink", forKey: Settings.Key.newDisplayPolicy)
        XCTAssertTrue(sut.shouldCover(uuid: otherUUID, isNew: true))
    }

    func testShouldCover_regression_newDisplayPolicy_defaultCoversNewDisplay() {
        Settings.d.set("cover", forKey: Settings.Key.newDisplayPolicy)
        XCTAssertTrue(sut.shouldCover(uuid: otherUUID, isNew: true))
    }

    // MARK: - Toggling exclusion ON mid-session tears down an existing cover
    //
    // reconcile()'s survivor loop (CurtainController+DisplayReconciliation.swift)
    // is not unit-testable directly — it iterates live `NSScreen.screens`, which
    // has no fakeable/headless construction path (see this file's header comment
    // and the `verifyNoneCoverHidden` note at EOF for the project's established
    // precedent on this exact limitation). This test instead verifies the
    // decision surface reconcile() depends on: once a UUID is added to the
    // KVM-exclusion list mid-session, shouldCover() immediately flips to false
    // for that identity — the same predicate reconcile()'s teardown branch
    // gates on (`Settings.kvmExcludedDisplayUUIDs.contains(uuid)`), confirming
    // the setting change alone (no other state) drives the teardown decision.
    func testShouldCover_togglingExclusionOnMidSession_flipsToFalseForThatUUID() {
        Settings.d.set("all", forKey: Settings.Key.coverScope)
        XCTAssertTrue(sut.shouldCover(uuid: otherUUID, isNew: false), "covered before exclusion is toggled on")

        Settings.kvmExcludedDisplayUUIDs = [otherUUID]

        XCTAssertFalse(sut.shouldCover(uuid: otherUUID, isNew: false), "excluded immediately after toggling on")
    }
}

// MARK: - verifyNoneCoverHidden — NOT unit tested (documented gap)
//
// `CurtainController.verifyNoneCoverHidden(completion:)` is not covered by any
// test in this file. It calls the real `SCShareableContent.getWithCompletionHandler`
// (ScreenCaptureKit), which requires a live Screen Recording-authorized process
// and actual on-screen window content to enumerate — there is no in-process fake
// for SCShareableContent, and constructing one would mean not testing the real
// method at all. Its only branch that doesn't need SCK is the
// `#available(macOS 12.3, *)` == false fallback (`completion(true)`), which is
// unreachable in this codebase since Package.swift already pins the deployment
// target to macOS 13 — every build target is >= 12.3, so that branch can never
// execute in a real Curtain build and testing it would only be exercising dead
// code. This is a genuine, accepted gap: verifyNoneCoverHidden's actual
// SCK-based regression check is manually/integration-verified only (see
// CHANGELOG's "Verified end-to-end" notes for the disconnect helper as the
// project's existing precedent for that verification style), not by `swift test`.
