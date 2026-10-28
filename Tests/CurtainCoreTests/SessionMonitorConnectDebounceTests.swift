import XCTest
@testable import CurtainCore

/// A bare TCP connect-and-drop on 5900 (a LAN port probe) must not count as a session.
/// Regression for the 2026-10-28 lock: one ESTABLISHED tick armed the cover, then the
/// "session ended" action locked the Mac and slept the displays.
@MainActor
final class SessionMonitorConnectDebounceTests: XCTestCase {
    private let tcpOnly = CaptureProbe.CaptureSignals(captured: false, tcpEstablished: true, udpPeered: false)
    private let captured = CaptureProbe.CaptureSignals(captured: true, tcpEstablished: true, udpPeered: false)
    private let none = CaptureProbe.CaptureSignals(captured: false, tcpEstablished: false, udpPeered: false)

    func testSingleTickProbeDoesNotConnect() {
        let monitor = SessionMonitor()
        var connects = 0
        monitor.onConnect = { _ in connects += 1 }
        monitor.apply(signals: tcpOnly, idle: 0)
        monitor.apply(signals: none, idle: 0)
        XCTAssertEqual(connects, 0)
    }

    func testSustainedNetworkOnlySessionConnects() {
        let monitor = SessionMonitor()
        var connects = 0
        monitor.onConnect = { _ in connects += 1 }
        for _ in 0..<3 { monitor.apply(signals: tcpOnly, idle: 0) }
        XCTAssertEqual(connects, 1)
    }

    func testCaptureFlagConnectsOnFirstTick() {
        let monitor = SessionMonitor()
        var connects = 0
        monitor.onConnect = { _ in connects += 1 }
        monitor.apply(signals: captured, idle: 0)
        XCTAssertEqual(connects, 1)
    }

    func testInterruptedProbesNeverAccumulate() {
        let monitor = SessionMonitor()
        var connects = 0
        monitor.onConnect = { _ in connects += 1 }
        for _ in 0..<4 {
            monitor.apply(signals: tcpOnly, idle: 0)
            monitor.apply(signals: none, idle: 0)
        }
        XCTAssertEqual(connects, 0)
    }
}
