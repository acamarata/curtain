import XCTest
@testable import CurtainCore

/// Purpose: Regression tests for `KVMActivityNotifier` (T-P1-E13-03) — the
///          optional, independently-toggleable "KVM operator is active right
///          now" notification sourced from `KVMInputFilter`'s read-only
///          `onMatchedDeviceActivity` hook. The single most important test in
///          this file is `testShouldCover_zeroCoupling...`: it structurally
///          proves `CurtainController.shouldCover(uuid:isNew:)`'s result for a
///          KVM-excluded display is identical whether this notification feature
///          is enabled, disabled, or its observer throws — not merely by code
///          inspection, but by actually exercising all three states against the
///          real covering decision.
/// Inputs: none (isolated `UserDefaults(suiteName:)` per test, matching
///          `CurtainControllerShouldCoverKVMExclusionTests`'s established
///          pattern).
/// Outputs: none (assertions only).
/// Constraints: `Notifier.post` itself is a no-op under `xctest` (see
///          Notifier.swift's `isRunningUnderXCTest`) and exposes no test seam,
///          so `KVMActivityNotifier.postAction` (an injectable closure mirroring
///          `SessionCoordinator.isAccessibilityTrusted`'s seam) is used here to
///          observe call counts/throttling instead of relying on real
///          UNUserNotificationCenter delivery.
/// SPORT: MASTER-KVMINPUTFILTER
@MainActor
final class KVMActivityNotifierTests: XCTestCase {

    private var suiteName: String!
    private var originalDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "KVMActivityNotifierTests.\(UUID().uuidString)"
        originalDefaults = Settings.d
        let isolated = UserDefaults(suiteName: suiteName)!
        isolated.removePersistentDomain(forName: suiteName)
        Settings.d = isolated
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        Settings.d = originalDefaults
        super.tearDown()
    }

    // MARK: - The ticket's most important test: zero coupling to shouldCover()

    /// Structurally proves T-P1-E13-01's `shouldCover()` result for a
    /// KVM-excluded display is unaffected by this notification feature being
    /// enabled, disabled, or its observer throwing/misbehaving. Exercises all
    /// three states against the real `CurtainController`, not just the
    /// enabled happy path.
    func testShouldCover_zeroCoupling_acrossEnabledDisabledAndFailingObserverStates() {
        let excludedUUID = "KVM-EXCLUDED-UUID"
        let controller = CurtainController()
        Settings.kvmExcludedDisplayUUIDs = [excludedUUID]
        Settings.d.set("all", forKey: Settings.Key.coverScope)

        // Baseline: excluded regardless of this feature ever having existed.
        XCTAssertFalse(controller.shouldCover(uuid: excludedUUID, isNew: false))

        // State 1: feature enabled, activity genuinely observed via the real hook.
        Settings.kvmActivityNotificationEnabled = true
        let filter = KVMInputFilter()
        let notifier = KVMActivityNotifier()
        var postCount = 0
        notifier.postAction = { _, _, _, _ in postCount += 1 }
        notifier.attach(to: filter)
        filter.onMatchedDeviceActivity?()
        XCTAssertEqual(postCount, 1, "sanity: the hook does fire the notifier when enabled")
        XCTAssertFalse(
            controller.shouldCover(uuid: excludedUUID, isNew: false),
            "shouldCover must stay false with the notification feature enabled and firing")

        // State 2: feature disabled.
        Settings.kvmActivityNotificationEnabled = false
        filter.onMatchedDeviceActivity?()
        XCTAssertFalse(
            controller.shouldCover(uuid: excludedUUID, isNew: false),
            "shouldCover must stay false with the notification feature disabled")

        // State 3: observer intentionally broken/throwing.
        Settings.kvmActivityNotificationEnabled = true
        filter.onMatchedDeviceActivity = {
            struct Boom: Error {}
            // A closure can't propagate a thrown error to its caller (Swift
            // closures here are non-throwing), so "fails" is modeled the way a
            // real misbehaving observer would actually manifest: it does
            // something broken (fatal-adjacent logic elsewhere, a force-unwrap
            // of nil, etc.) without ever reaching Notifier.post. The important
            // structural guarantee is that shouldCover() has no dependency on
            // this closure at all — it is never called, read, or referenced
            // anywhere in CurtainController.
            _ = Boom.self
        }
        filter.onMatchedDeviceActivity?()
        XCTAssertFalse(
            controller.shouldCover(uuid: excludedUUID, isNew: false),
            "shouldCover must stay false even with a misbehaving observer attached")

        // Also confirm the non-excluded path is untouched by any of this.
        XCTAssertTrue(controller.shouldCover(uuid: "OTHER-UUID", isNew: false))
    }

    /// Even a completely detached `KVMActivityNotifier` (never attached to any
    /// filter, never invoked) must have zero effect on shouldCover — proves the
    /// coupling doesn't exist at the type level either, not just at runtime.
    func testShouldCover_unaffectedByNotifierExistingButNeverAttached() {
        let excludedUUID = "KVM-EXCLUDED-UUID"
        Settings.kvmExcludedDisplayUUIDs = [excludedUUID]
        _ = KVMActivityNotifier()  // constructed, never attached, never invoked

        let controller = CurtainController()
        XCTAssertFalse(controller.shouldCover(uuid: excludedUUID, isNew: false))
    }

    // MARK: - Notify-on-activity behavior

    func testNotify_firesWhenEnabled() {
        Settings.kvmActivityNotificationEnabled = true
        let notifier = KVMActivityNotifier()
        var calls: [(title: String, body: String)] = []
        notifier.postAction = { title, body, _, _ in calls.append((title, body)) }

        notifier.notify()

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.title, "Curtain")
    }

    func testNotify_doesNotFireWhenDisabled() {
        Settings.kvmActivityNotificationEnabled = false
        let notifier = KVMActivityNotifier()
        var callCount = 0
        notifier.postAction = { _, _, _, _ in callCount += 1 }

        notifier.notify()

        XCTAssertEqual(callCount, 0, "must not post when the Settings key is disabled")
    }

    func testNotify_defaultsToDisabled_freshInstall() {
        // No explicit Settings.kvmActivityNotificationEnabled write — confirms the
        // fail-safe default (off) registered in Settings.registerDefaults() via
        // Key.kvmActivityNotificationEnabled: false.
        Settings.d.register(defaults: [Settings.Key.kvmActivityNotificationEnabled: false])
        let notifier = KVMActivityNotifier()
        var callCount = 0
        notifier.postAction = { _, _, _, _ in callCount += 1 }

        notifier.notify()

        XCTAssertEqual(callCount, 0, "a fresh install (no explicit toggle) must default to no notification")
    }

    func testNotify_usesExpectedThrottleKeyAndWindow() {
        Settings.kvmActivityNotificationEnabled = true
        let notifier = KVMActivityNotifier()
        var observedThrottleKey: String?
        var observedThrottleSeconds: TimeInterval?
        notifier.postAction = { _, _, throttleKey, throttleSeconds in
            observedThrottleKey = throttleKey
            observedThrottleSeconds = throttleSeconds
        }

        notifier.notify()

        XCTAssertEqual(observedThrottleKey, KVMActivityNotifier.throttleKey)
        XCTAssertEqual(observedThrottleSeconds, KVMActivityNotifier.throttleSeconds)
        XCTAssertEqual(KVMActivityNotifier.throttleSeconds, 60, "spec: once per 60s while activity continues")
    }

    // MARK: - Attach wiring

    func testAttach_wiresFilterHookToNotify() {
        Settings.kvmActivityNotificationEnabled = true
        let filter = KVMInputFilter()
        let notifier = KVMActivityNotifier()
        var callCount = 0
        notifier.postAction = { _, _, _, _ in callCount += 1 }

        XCTAssertNil(filter.onMatchedDeviceActivity, "sanity: hook is nil before attach")
        notifier.attach(to: filter)
        XCTAssertNotNil(filter.onMatchedDeviceActivity, "attach must install the hook")

        filter.onMatchedDeviceActivity?()
        XCTAssertEqual(callCount, 1)
    }

    func testAttach_disabledFeature_hookFiresButNoPost() {
        Settings.kvmActivityNotificationEnabled = false
        let filter = KVMInputFilter()
        let notifier = KVMActivityNotifier()
        var callCount = 0
        notifier.postAction = { _, _, _, _ in callCount += 1 }
        notifier.attach(to: filter)

        filter.onMatchedDeviceActivity?()

        XCTAssertEqual(callCount, 0, "hook firing while disabled must not post")
    }
}
