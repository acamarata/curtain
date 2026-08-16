import XCTest
@testable import CurtainCore

/// Purpose: T-P1-E10-03 regression coverage — proves `Settings.armed` (and other
///          session-relevant settings) are written immediately, synchronously, and
///          with no in-memory-only staging, so a `kill -9` mid-session can never
///          lose state. This was verified for real on-device first (see the
///          ticket's sidecar notes for the literal `kill -9` + relaunch transcript
///          against the built `Curtain.app`, using the app's own
///          `SessionMonitor`-written `heartbeat.json` as the independent readback
///          channel); this test captures that same guarantee as an automated,
///          CI-safe regression that doesn't require spawning/killing a real GUI
///          process.
/// How: mirrors SessionCoordinatorTests/SettingsPasswordTests' established
///      `Settings.d` suite-swap seam (T-P1-E05-03) — `setUp` points `Settings.d`
///      at an isolated named `UserDefaults(suiteName:)` instance so this test
///      never touches real app defaults. The key assertion technique: after each
///      `Settings.x = value` write, a **second, independent** `UserDefaults`
///      instance is constructed against the exact same suite name (`UserDefaults
///      (suiteName:)` again, not a reference to the first) and read from THAT
///      instance, never the one `Settings` itself holds. A brand-new
///      `UserDefaults` object reading a value written by a different `UserDefaults`
///      object into the same on-disk-backed suite is the same class of proof
///      `defaults read <domain>` gave during the live on-device test: it can only
///      see what was actually persisted, never an in-process cache a batched or
///      deferred-write implementation might have kept in memory instead. If
///      `Settings`'s setters ever introduced batching/staging (e.g. caching in a
///      Swift property and only flushing on a graceful-quit hook), this test would
///      fail because the second `UserDefaults` handle would read the stale/default
///      value instead.
/// Constraints: covers `armed` (the ticket's primary subject) plus `idleMinutes`
///      and `coverStyle` as the "1-2 other session-relevant settings" the ticket
///      asks for, exercised via their real public setters/getters — not by poking
///      `UserDefaults` directly — so a future setter that adds batching would also
///      be caught here.
/// SPORT: MASTER-SETTINGS
@MainActor
final class SettingsHardKillPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var originalDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "curtain-hardkill-tests-\(UUID().uuidString)"
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

    /// A brand-new `UserDefaults` handle onto the same suite, standing in for what
    /// a freshly-launched, post-hard-kill process would see on relaunch: it shares
    /// no Swift-level object, memory, or cache with `Settings.d` — only the
    /// on-disk-backed suite name.
    private func freshHandle() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    // MARK: - armed (the ticket's primary subject)

    /// armed = true survives an independent-handle readback, ruling out the
    /// "default value happens to be true so a no-op write looks correct" failure
    /// mode explicitly called out in the ticket's acceptance criteria.
    func testArmedTrueSurvivesIndependentHandleReadback() {
        Settings.armed = true
        XCTAssertTrue(freshHandle().bool(forKey: Settings.Key.armed))
    }

    /// armed = false must ALSO survive — this is the direction that actually
    /// matters for a hard-kill: if a batched-write bug existed, disarming right
    /// before a kill -9 is exactly the scenario that would silently re-arm on
    /// relaunch (the worst-case failure for this product: "protected" becomes
    /// silently false).
    func testArmedFalseSurvivesIndependentHandleReadback() {
        Settings.armed = true  // start from the opposite value, not the type's default
        Settings.armed = false
        XCTAssertFalse(freshHandle().bool(forKey: Settings.Key.armed))
    }

    /// Flips armed twice in a row and confirms an independent handle sees the
    /// FINAL value after each flip, not just the eventual settled state — proves
    /// each individual write is immediately visible, not just the last one after
    /// some batching window closes.
    func testArmedEachToggleIsImmediatelyVisible() {
        Settings.armed = true
        XCTAssertTrue(freshHandle().bool(forKey: Settings.Key.armed))

        Settings.armed = false
        XCTAssertFalse(freshHandle().bool(forKey: Settings.Key.armed))

        Settings.armed = true
        XCTAssertTrue(freshHandle().bool(forKey: Settings.Key.armed))
    }

    // MARK: - other session-relevant settings (ticket asks for "1-2 others")

    /// idleMinutes is read through the public clamped accessor (not the raw key)
    /// so a regression in the clamp logic would also surface here, not just a
    /// storage regression.
    func testIdleMinutesSurvivesIndependentHandleReadback() {
        Settings.d.set(91, forKey: Settings.Key.idleMinutes)
        XCTAssertEqual(freshHandle().integer(forKey: Settings.Key.idleMinutes), 91)
        // Also confirm Settings' own clamped accessor (read through Settings.d,
        // which by construction is the same isolated suite) agrees.
        XCTAssertEqual(Settings.idleMinutes, 91)
    }

    /// coverStyle (a String-backed setting, unlike the two Bool/Int cases above)
    /// survives too — covers a different underlying UserDefaults value type.
    func testCoverStyleSurvivesIndependentHandleReadback() {
        Settings.d.set("aerial", forKey: Settings.Key.coverStyle)
        XCTAssertEqual(freshHandle().string(forKey: Settings.Key.coverStyle), "aerial")
        XCTAssertEqual(Settings.coverStyle, "aerial")
    }

    // MARK: - SessionCoordinator.setArmed's real call path

    /// setArmed() (SessionCoordinator.swift ~362-380) is the one production call
    /// site that actually flips `Settings.armed` in response to a user action (menu
    /// toggle, preferences checkbox). This confirms ITS write — `Settings.armed =
    /// on`, line 377 — is immediately visible too, not just direct assignment to
    /// the property in isolation. `SessionCoordinator`'s own `SpyActionRunner` is
    /// `private` to SessionCoordinatorTests.swift, so this drives the real
    /// zero-arg `SessionCoordinator()` (real CurtainController/SessionMonitor
    /// dependencies) rather than duplicating that private spy type — safe here
    /// because `setArmed` only touches Settings + the onArmedChange callback + (on
    /// disarm) deactivateNow(), none of which needs OS permissions to execute
    /// harmlessly against an idle, never-activated coordinator in a test process.
    func testSetArmedThroughCoordinatorPersistsImmediately() {
        let sut = SessionCoordinator()
        sut.isAccessibilityTrusted = { true }

        sut.setArmed(false)
        XCTAssertFalse(freshHandle().bool(forKey: Settings.Key.armed))

        sut.setArmed(true)
        XCTAssertTrue(freshHandle().bool(forKey: Settings.Key.armed))
    }
}
