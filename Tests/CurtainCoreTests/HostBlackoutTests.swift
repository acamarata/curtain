import CoreGraphics
import XCTest

@testable import CurtainCore

@MainActor
final class HostBlackoutTests: XCTestCase {

    private final class FakeGamma: GammaControlling {
        var black: Set<CGDirectDisplayID> = []
        var setCalls: [CGDirectDisplayID] = []
        var restoreCalls = 0
        func setBlack(_ d: CGDirectDisplayID) { black.insert(d); setCalls.append(d) }
        func isBlack(_ d: CGDirectDisplayID) -> Bool { black.contains(d) }
        func restoreAll() { black = []; restoreCalls += 1 }
    }

    func testSetTargetsBlanksEveryTargetOnce() {
        let g = FakeGamma()
        let sut = HostBlackout(gamma: g)
        sut.setTargets([1, 2, 3])
        XCTAssertEqual(g.black, [1, 2, 3])
        XCTAssertTrue(sut.isActive)
        XCTAssertEqual(g.restoreCalls, 0)
    }

    func testRefreshOnlyReappliesWhereMacOSResetTheTable() {
        let g = FakeGamma()
        let sut = HostBlackout(gamma: g)
        sut.setTargets([1, 2])
        g.setCalls = []
        sut.refresh()
        XCTAssertTrue(g.setCalls.isEmpty, "already black: no redundant gamma writes (they can flicker)")
        g.black.remove(2)  // macOS reset display 2 (wake or reconfiguration)
        sut.refresh()
        XCTAssertEqual(g.setCalls, [2])
        XCTAssertEqual(g.black, [1, 2])
    }

    func testRemovingATargetRestoresThenReblanksTheRest() {
        let g = FakeGamma()
        let sut = HostBlackout(gamma: g)
        sut.setTargets([1, 2])
        sut.setTargets([1])
        XCTAssertEqual(g.restoreCalls, 1)
        XCTAssertEqual(g.black, [1], "display 2 is visible again, display 1 stays black")
    }

    func testPauseShowsOneDisplayAndResumeBlanksItAgain() {
        let g = FakeGamma()
        let sut = HostBlackout(gamma: g)
        sut.setTargets([1, 2])
        sut.pause(1)
        XCTAssertEqual(g.black, [2], "display 1 visible for the password box, display 2 still black")
        sut.refresh()
        XCTAssertEqual(g.black, [2], "a paused display is not re-blanked by the watchdog")
        sut.resume(1)
        XCTAssertEqual(g.black, [1, 2])
    }

    func testRestoreGivesEverythingBack() {
        let g = FakeGamma()
        let sut = HostBlackout(gamma: g)
        sut.setTargets([1, 2])
        sut.restore()
        XCTAssertTrue(g.black.isEmpty)
        XCTAssertFalse(sut.isActive)
        sut.refresh()
        XCTAssertTrue(g.black.isEmpty, "nothing left to refresh after restore")
    }

    func testPauseOfAnUntargetedDisplayIsIgnored() {
        let g = FakeGamma()
        let sut = HostBlackout(gamma: g)
        sut.setTargets([1])
        sut.pause(9)
        XCTAssertEqual(g.restoreCalls, 0)
        XCTAssertEqual(g.black, [1])
    }
}

extension HostBlackoutTests {
    func testPauseSeveralThenResumeAll() {
        let g = FakeGammaForSets()
        let sut = HostBlackout(gamma: g)
        sut.setTargets([1, 2, 3])
        sut.pause([1, 2])
        XCTAssertEqual(g.black, [3], "1 and 2 visible for the padlock screen, 3 untouched")
        sut.refresh()
        XCTAssertEqual(g.black, [3], "paused displays are not re-blanked by the watchdog")
        sut.resumeAll()
        XCTAssertEqual(g.black, [1, 2, 3])
    }
}

private final class FakeGammaForSets: GammaControlling {
    var black: Set<CGDirectDisplayID> = []
    func setBlack(_ d: CGDirectDisplayID) { black.insert(d) }
    func isBlack(_ d: CGDirectDisplayID) -> Bool { black.contains(d) }
    func restoreAll() { black = [] }
}
