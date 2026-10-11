import XCTest

@testable import CurtainCore

/// Pure decision tests for PasswordBox key handling (v2.0.4 fixes): the revealing
/// key must not pollute the password, a bare Return must not count as a failed
/// attempt, and spaces must be typable.
final class PasswordBoxKeyTests: XCTestCase {
    private typealias D = PasswordBox.KeyDisposition

    func testVisibleBoxAlwaysProcesses() {
        for kc in [0, 36, 53, 51] {
            XCTAssertEqual(PasswordBox.disposition(wasHidden: false, revealOnAnyKey: true, keycode: kc), D.process)
            XCTAssertEqual(PasswordBox.disposition(wasHidden: false, revealOnAnyKey: false, keycode: kc), D.process)
        }
    }

    func testAnyKeyModeTypesThroughOnCharacter() {
        XCTAssertEqual(PasswordBox.disposition(wasHidden: true, revealOnAnyKey: true, keycode: 0), D.process)
    }

    func testComboModeNeverTypesTheRevealingKey() {
        XCTAssertEqual(PasswordBox.disposition(wasHidden: true, revealOnAnyKey: false, keycode: 37), D.revealOnly)
    }

    func testReturnOnHiddenBoxOnlyReveals() {
        XCTAssertEqual(PasswordBox.disposition(wasHidden: true, revealOnAnyKey: true, keycode: 36), D.revealOnly)
        XCTAssertEqual(PasswordBox.disposition(wasHidden: true, revealOnAnyKey: true, keycode: 76), D.revealOnly)
        XCTAssertEqual(PasswordBox.disposition(wasHidden: true, revealOnAnyKey: true, keycode: 51), D.revealOnly)
    }

    func testEscOnHiddenBoxIsIgnored() {
        XCTAssertEqual(PasswordBox.disposition(wasHidden: true, revealOnAnyKey: true, keycode: 53), D.ignore)
    }

    func testSpaceIsTypable() {
        XCTAssertTrue(PasswordBox.isTypable(" "))
        XCTAssertTrue(PasswordBox.isTypable("a"))
        XCTAssertTrue(PasswordBox.isTypable("7"))
        XCTAssertTrue(PasswordBox.isTypable("!"))
        XCTAssertFalse(PasswordBox.isTypable("\t"))
        XCTAssertFalse(PasswordBox.isTypable("\n"))
        XCTAssertFalse(PasswordBox.isTypable(nil))
        XCTAssertFalse(PasswordBox.isTypable(""))
    }
}
