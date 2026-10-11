import XCTest

@testable import CurtainCore

final class AccessibilityPermissionTests: XCTestCase {

    func testSettingsLinksAreValidAndAvoidTheLinkThatOpenedNothing() {
        XCTAssertFalse(AccessibilityPermission.settingsURLStrings.isEmpty)
        for s in AccessibilityPermission.settingsURLStrings {
            XCTAssertNotNil(URL(string: s), s)
            XCTAssertTrue(s.hasSuffix("Privacy_Accessibility"), s)
            XCTAssertFalse(s.contains("com.apple.Privacy-Accessibility-Settings"), "dead link on macOS 27")
        }
    }

    func testOpenSettingsUsesFirstLinkThatOpens() {
        var tried: [String] = []
        let ok = AccessibilityPermission.openSettings { url in
            tried.append(url.absoluteString)
            return true
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(tried, [AccessibilityPermission.settingsURLStrings[0]])
    }

    func testOpenSettingsFallsBackThroughLinksThenToSettingsApp() {
        var tried: [String] = []
        let ok = AccessibilityPermission.openSettings { url in
            tried.append(url.absoluteString)
            return url.isFileURL  // every deep link fails, the app itself opens
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(tried.count, AccessibilityPermission.settingsURLStrings.count + 1)
        XCTAssertEqual(tried.last?.contains("System%20Settings.app"), true)
    }

    func testResetArguments() {
        XCTAssertEqual(
            AccessibilityPermission.resetArguments(bundleID: "io.acamarata.curtain"),
            ["reset", "Accessibility", "io.acamarata.curtain"])
    }

    func testRequestPromptShowsNoUIUnderXCTest() {
        // Returns the plain trust state; reaching here without a dialog is the assertion.
        XCTAssertEqual(AccessibilityPermission.requestPrompt(), AccessibilityPermission.isGranted)
    }

    func testPaneNameHintNamesBothTitles() {
        XCTAssertTrue(AccessibilityPermission.paneNameHint.contains("Accessibility"))
        XCTAssertTrue(AccessibilityPermission.paneNameHint.contains("Device Control and Data Access"))
    }
}
