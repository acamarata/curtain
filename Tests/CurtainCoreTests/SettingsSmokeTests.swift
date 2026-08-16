import XCTest
@testable import CurtainCore

/// Purpose: First smoke test for the CurtainCoreTests target (T-P1-E05-01
///          scaffold) — confirms the target builds and runs end-to-end via
///          `swift test`, and that a real CurtainCore type (Settings) is
///          reachable and behaves correctly. Full coverage of Settings is
///          tickets T-P1-E05-02 through T-P1-E05-05's scope, not this one.
/// SPORT: MASTER-SETTINGS
final class SettingsSmokeTests: XCTestCase {
    func testConnectGraceSecondsClampsToUpperBound() {
        // Settings.connectGraceSeconds clamps its stored value to 0...30
        // (Settings.swift `clamp` helper). A value beyond the range read back
        // clamped confirms the pure accessor logic works when imported from
        // outside the Curtain executable target.
        let key = Settings.Key.connectGraceSeconds
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.set(999, forKey: key)
        XCTAssertEqual(Settings.connectGraceSeconds, 30)
    }
}
