import XCTest
@testable import CurtainCore

/// Purpose: Real unit coverage for `SettingsImportValidation` — the pure
///          type/enum/range validation core pulled out of PreferencesWindow's
///          private SwiftUI struct in T-P1-E06-02 (following the T-P1-E05-05
///          extraction pattern) precisely so this logic is testable outside a
///          throwaway harness. Mirrors the exact cases the CR-C ticket cited.
/// SPORT: MASTER-PREFS
final class SettingsImportValidationTests: XCTestCase {

    // MARK: - 1:1 coverage against the exportable key set

    /// The exportable key set is the ground truth PreferencesWindow imports/exports.
    /// Every one must map to exactly one validation bucket — no gap, no overlap.
    private static let exportableKeys: [String] = [
        Settings.Key.armed, Settings.Key.launchAtLogin, Settings.Key.showInMenuBar,
        Settings.Key.onStartActivate, Settings.Key.connectGraceSeconds, Settings.Key.notifyOnActivate,
        Settings.Key.playSoundOnActivate,
        Settings.Key.coverStyle, Settings.Key.coverColor, Settings.Key.coverMessage, Settings.Key.coverShowClock,
        Settings.Key.revealTrigger, Settings.Key.revealKeyCombo,
        Settings.Key.idleEnabled, Settings.Key.idleMinutes, Settings.Key.idleSource,
        Settings.Key.onIdleDisconnect, Settings.Key.onIdleLock, Settings.Key.onIdleScreenOff,
        Settings.Key.onIdleDeactivate,
        Settings.Key.onEndLock, Settings.Key.onEndScreenOff, Settings.Key.onEndDeactivate,
        Settings.Key.onUnlockAction, Settings.Key.passwordBoxTimeoutSeconds,
        Settings.Key.requirePasswordToDeactivateFromMenu, Settings.Key.accessibilityMissingBehavior,
        Settings.Key.disconnectFeatureEnabled,
        Settings.Key.displayLinkUUIDs, Settings.Key.perDisplayCoverDisabled,
        Settings.Key.coverScope, Settings.Key.passwordBoxPlacement, Settings.Key.passwordBoxSpecificUUID,
        Settings.Key.newDisplayPolicy,
        Settings.Key.diagnosticsLoggingEnabled
    ]

    func testEveryExportableKeyHasExactlyOneRule() {
        XCTAssertEqual(Self.exportableKeys.count, 35, "expected 35 exportable keys")
        let gaps = SettingsImportValidation.coverageGaps(for: Self.exportableKeys)
        XCTAssertTrue(gaps.uncovered.isEmpty, "keys with no validation rule: \(gaps.uncovered)")
        XCTAssertTrue(gaps.overlapping.isEmpty, "keys matching multiple buckets: \(gaps.overlapping)")
    }

    func testUnknownKeyFailsClosed() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: "totally.unknown.key", value: true))
    }

    // MARK: - Enum keys

    func testEnumValidAccepted() {
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.onUnlockAction, value: "disconnect"))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.onUnlockAction, value: "keepSession"))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.coverStyle, value: "aerial"))
    }

    /// The exact bug the ticket cited: onUnlockAction="garbage" must be rejected,
    /// not silently coerced to a false Settings.unlockDisconnect.
    func testEnumGarbageRejected() {
        let reason = SettingsImportValidation.validate(key: Settings.Key.onUnlockAction, value: "garbage")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("garbage"))
        XCTAssertTrue(reason!.contains("disconnect"), "message should list allowed values")
    }

    /// Legacy value not offered by any current UI control must not sneak back in.
    func testEnumLegacyValueRejected() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.coverStyle, value: "screensaver"))
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.coverScope, value: "onlyMarked"))
    }

    func testEnumWrongTypeRejected() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.coverStyle, value: 42))
    }

    // MARK: - Range keys

    func testRangeInBoundsAccepted() {
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.connectGraceSeconds, value: 15))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.idleMinutes, value: 120))
    }

    func testRangeBoundaryValuesAccepted() {
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.connectGraceSeconds, value: 0))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.connectGraceSeconds, value: 30))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.passwordBoxTimeoutSeconds, value: 5))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.passwordBoxTimeoutSeconds, value: 60))
    }

    func testRangeOutOfBoundsRejected() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.connectGraceSeconds, value: -1))
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.connectGraceSeconds, value: 31))
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.idleMinutes, value: 0))
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.idleMinutes, value: 241))
    }

    func testRangeWrongTypeRejected() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.idleMinutes, value: "120"))
    }

    // MARK: - Bool keys

    func testBoolAccepted() {
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.armed, value: true))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.armed, value: false))
    }

    func testBoolWrongTypeRejected() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.armed, value: "yes"))
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.armed, value: 1))
    }

    // MARK: - Free-string keys

    func testFreeStringAcceptsAnyString() {
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.coverMessage, value: "anything"))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.coverMessage, value: ""))
    }

    func testFreeStringWrongTypeRejected() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.coverMessage, value: 42))
    }

    // MARK: - String-array keys

    func testStringArrayAccepted() {
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.displayLinkUUIDs, value: ["A", "B"]))
        XCTAssertNil(SettingsImportValidation.validate(key: Settings.Key.displayLinkUUIDs, value: [String]()))
    }

    /// AnyCodable's decode falls back to "" for anything it can't parse; an empty
    /// element inside an array is that masquerade and must be rejected.
    func testStringArrayWithEmptyFallbackElementRejected() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.displayLinkUUIDs, value: ["A", ""]))
    }

    func testStringArrayWrongTypeRejected() {
        XCTAssertNotNil(SettingsImportValidation.validate(key: Settings.Key.displayLinkUUIDs, value: "not-a-list"))
    }
}
