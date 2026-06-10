import XCTest
@testable import CurtainShared

final class RevealComboTests: XCTestCase {
    // Documented CGEventFlags raw masks.
    private let cmd: UInt64 = 0x100000
    private let shift: UInt64 = 0x20000
    private let control: UInt64 = 0x40000
    private let option: UInt64 = 0x80000
    private let capsLock: UInt64 = 0x10000
    private let fn: UInt64 = 0x800000

    // The "L" key: keycode 37, char "l".
    private let lKeycode = 37

    func testMatchesCmdShiftL() {
        XCTAssertTrue(RevealCombo.matches(
            combo: "cmd+shift+l", keycode: lKeycode, chars: "l", flagsRawValue: cmd | shift))
    }

    func testRejectsWrongKey() {
        XCTAssertFalse(RevealCombo.matches(
            combo: "cmd+shift+l", keycode: 0, chars: "a", flagsRawValue: cmd | shift))
    }

    func testRejectsMissingModifier() {
        // Only cmd held, shift required too.
        XCTAssertFalse(RevealCombo.matches(
            combo: "cmd+shift+l", keycode: lKeycode, chars: "l", flagsRawValue: cmd))
    }

    func testRejectsExtraModifier() {
        // control is held but not part of the combo: exact-match rejects it.
        XCTAssertFalse(RevealCombo.matches(
            combo: "cmd+shift+l", keycode: lKeycode, chars: "l", flagsRawValue: cmd | shift | control))
    }

    func testNamedKeySpace() {
        XCTAssertTrue(RevealCombo.matches(
            combo: "cmd+space", keycode: 49, chars: " ", flagsRawValue: cmd))
        XCTAssertFalse(RevealCombo.matches(
            combo: "cmd+space", keycode: 36, chars: nil, flagsRawValue: cmd))
    }

    func testNamedKeysReturnEscDelete() {
        XCTAssertTrue(RevealCombo.matches(
            combo: "ctrl+return", keycode: 36, chars: nil, flagsRawValue: control))
        XCTAssertTrue(RevealCombo.matches(
            combo: "cmd+esc", keycode: 53, chars: nil, flagsRawValue: cmd))
        XCTAssertTrue(RevealCombo.matches(
            combo: "cmd+delete", keycode: 51, chars: nil, flagsRawValue: cmd))
    }

    func testIgnoresCapsLockAndFnBits() {
        XCTAssertTrue(RevealCombo.matches(
            combo: "cmd+shift+l", keycode: lKeycode, chars: "l",
            flagsRawValue: cmd | shift | capsLock | fn))
    }

    func testCaseInsensitiveChar() {
        XCTAssertTrue(RevealCombo.matches(
            combo: "cmd+shift+l", keycode: lKeycode, chars: "L", flagsRawValue: cmd | shift))
        XCTAssertTrue(RevealCombo.matches(
            combo: "CMD+SHIFT+L", keycode: lKeycode, chars: "l", flagsRawValue: cmd | shift))
    }

    func testOptionAndControlNames() {
        XCTAssertTrue(RevealCombo.matches(
            combo: "opt+a", keycode: 0, chars: "a", flagsRawValue: option))
        XCTAssertTrue(RevealCombo.matches(
            combo: "alt+a", keycode: 0, chars: "a", flagsRawValue: option))
    }

    func testEmptyComboIsFalse() {
        XCTAssertFalse(RevealCombo.matches(
            combo: "", keycode: 0, chars: "a", flagsRawValue: 0))
    }

    func testModifierOnlyComboIsFalse() {
        // No final key part, so nothing to match.
        XCTAssertFalse(RevealCombo.matches(
            combo: "cmd+shift", keycode: 0, chars: "a", flagsRawValue: cmd | shift))
    }
}
