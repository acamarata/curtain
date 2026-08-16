import XCTest
@testable import Curtain
@testable import CurtainCore

/// Purpose: T-P1-E14-03 coverage for the KVM Settings section's hidden-by-default
///          sidebar gating — `PreferencesView.visibleSections` must exclude
///          `.kvm` when `Settings.kvmSectionEnabled` is false (the default) and
///          include it once true, and `PreferencesView.PrefSection.allCases`
///          must still list `.kvm` unmodified (proving the enum itself stays
///          `CaseIterable`-exhaustive — only the sidebar's *displayed* list is
///          filtered, per PreferencesWindow.swift's `visibleSections` doc
///          comment).
/// How: `PreferencesView` and its nested `PrefSection` were changed from
///      `private` to `internal` (see PreferencesWindow.swift's doc comment on
///      that change) specifically so `@testable import Curtain` can reach them
///      here — `@testable` exposes `internal` declarations to the test target
///      but not `private`/`fileprivate` ones. Each test uses an isolated
///      UserDefaults suite (T-P1-E05-03 `Settings.d` seam, same pattern as
///      MCPServerTests.swift) so it never touches the real app's defaults.
/// Constraints: @MainActor (SwiftUI `View` conformance requires it here since
///      PreferencesView's stored closures capture main-actor state elsewhere
///      in the app, even though these tests never render the view).
/// SPORT: MASTER-PREFS
@MainActor
final class PreferencesWindowKVMVisibilityTests: XCTestCase {

    private var suiteName: String!
    private var originalDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PreferencesWindowKVMVisibilityTests.\(UUID().uuidString)"
        originalDefaults = Settings.d
        let isolated = UserDefaults(suiteName: suiteName)!
        isolated.removePersistentDomain(forName: suiteName)
        Settings.d = isolated
        Settings.registerDefaults()
    }

    override func tearDown() {
        Settings.d = originalDefaults
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeView() -> PreferencesView {
        PreferencesView(
            activateNow: {}, testNow: {}, markDisplayLink: {}, identifyDisplays: {},
            enableDisconnectHelper: { _ in }, openOnboarding: {}, openKVMBridgeSetup: {},
            onMenuBarToggle: { _ in }
        )
    }

    func testKVMSectionAbsentFromSidebarByDefault() {
        // kvmSectionEnabled defaults to false (Settings.registerDefaults()).
        XCTAssertFalse(Settings.kvmSectionEnabled)
        let view = makeView()
        XCTAssertFalse(
            view.visibleSections.contains(.kvm),
            ".kvm must not appear in the sidebar's displayed list when kvmSectionEnabled is false")
    }

    func testKVMSectionAppearsOnceEnabled() {
        Settings.kvmSectionEnabled = true
        let view = makeView()
        XCTAssertTrue(
            view.visibleSections.contains(.kvm),
            ".kvm must appear in the sidebar's displayed list once kvmSectionEnabled is true")
    }

    func testEveryOtherSectionAlwaysVisibleRegardlessOfFlag() {
        // The filter is scoped to .kvm only — every pre-existing section must
        // remain visible whether the flag is false or true, matching this
        // ticket's requirement that no other tab's visibility regresses.
        let alwaysVisible: [PreferencesView.PrefSection] = [
            .general, .appearance, .idleEnd, .security, .disconnect, .displays, .advanced
        ]
        for enabled in [false, true] {
            Settings.kvmSectionEnabled = enabled
            let view = makeView()
            for section in alwaysVisible {
                XCTAssertTrue(
                    view.visibleSections.contains(section),
                    "\(section) must remain visible when kvmSectionEnabled = \(enabled)")
            }
        }
    }

    func testPrefSectionRemainsCaseIterableExhaustiveIncludingKVM() {
        // allCases (unfiltered) must still include .kvm — only the sidebar's
        // displayed list is filtered, per PreferencesWindow.swift's guide. This
        // is what keeps the `detail` ViewBuilder switch exhaustive.
        XCTAssertTrue(PreferencesView.PrefSection.allCases.contains(.kvm))
        XCTAssertEqual(PreferencesView.PrefSection.allCases.count, 8)
    }

    func testKVMSectionHasTitleAndSymbol() {
        XCTAssertEqual(PreferencesView.PrefSection.kvm.title, "KVM")
        XCTAssertFalse(PreferencesView.PrefSection.kvm.symbol.isEmpty)
    }
}
