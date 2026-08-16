import XCTest
import CurtainShared
@testable import CurtainCore

/// Purpose: End-to-end coverage of `CaptureProbe`'s shell-out point — path
///          resolution, signal parsing through the full shell-out-to-signals()
///          path, and the shell-out watchdog timeout (T-P1-E05-02).
/// Inputs: none (each test installs/restores `CaptureProbe.processRunner`).
/// Outputs: N/A (assertions only).
/// Constraints: `CaptureProbe.processRunner` is a shared static var, so every test
///              must restore the original in a `defer` to avoid cross-test leakage
///              (XCTest runs test methods within a class serially, but state must
///              still not leak into other test files/classes in the same process).
/// SPORT: MASTER-CAPTUREPROBE
final class CaptureProbeTests: XCTestCase {

    // MARK: - Path resolution regression (curtain-netstat-path-root-cause.md)

    /// Regression test for the exact historical bug: netstat lives in /usr/sbin,
    /// not /usr/bin. A revert to /usr/bin/netstat here previously caused
    /// Process.run() to throw silently, so this assertion — asserting the actual
    /// invoked path via the injection seam — fails immediately if that regression
    /// is reintroduced (mutate CaptureProbe.swift's netstatOutput() path to
    /// /usr/bin/netstat and this test goes red).
    func testNetstatInvokesCorrectSbinPath() {
        var invokedPath: String?
        var invokedArgs: [String]?
        let original = CaptureProbe.processRunner
        CaptureProbe.processRunner = { path, args, _, _ in
            invokedPath = path
            invokedArgs = args
            return (ProcessRunner.Result(output: "", exitCode: 0), false)
        }
        defer { CaptureProbe.processRunner = original }

        _ = CaptureProbe.netstatOutput()

        XCTAssertEqual(invokedPath, "/usr/sbin/netstat")
        XCTAssertNotEqual(invokedPath, "/usr/bin/netstat")
        XCTAssertEqual(invokedArgs, ["-an"])
    }

    // MARK: - End-to-end signal parsing (shell-out -> signals())

    /// Real captured netstat output (adapted from the macOS 26.5 fixture pattern
    /// used in NetstatParseTests) with an ESTABLISHED TCP session on 5900 alongside
    /// listener noise. Confirms establishedVNC() and signals() are true end-to-end
    /// through the injected shell-out, not just through NetstatParse directly.
    func testEstablishedTCPFixtureDrivesSignalsTrue() {
        let fixture = """
            Active Internet connections (including servers)
            Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
            tcp4       0      0  *.5900                 *.*                    LISTEN
            tcp6       0      0  *.5900                 *.*                    LISTEN
            tcp4       0      0  192.168.1.20.5900      10.0.0.9.62000         ESTABLISHED
            """
        withNetstatFixture(fixture) {
            XCTAssertTrue(CaptureProbe.establishedVNC())
            XCTAssertFalse(CaptureProbe.peeredUDPVNC())
        }
    }

    /// LISTEN-only netstat output (Screen Sharing enabled, no session) must never
    /// read as active — the overnight false-positive class this probe exists to
    /// avoid.
    func testListenOnlyFixtureDrivesSignalsFalse() {
        let fixture = """
            Active Internet connections (including servers)
            Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
            tcp4       0      0  *.5900                 *.*                    LISTEN
            tcp6       0      0  *.5900                 *.*                    LISTEN
            """
        withNetstatFixture(fixture) {
            XCTAssertFalse(CaptureProbe.establishedVNC())
            XCTAssertFalse(CaptureProbe.peeredUDPVNC())
        }
    }

    /// Peered UDP on 5900 (High-Performance Screen Sharing transport, no
    /// ESTABLISHED TCP row at all) must read as active via peeredUDPVNC() and must
    /// not be confused with the TCP detector.
    func testPeeredUDPFixtureDrivesSignalsTrue() {
        let fixture = """
            Proto Recv-Q Send-Q  Local Address          Foreign Address
            udp4       0      0  192.168.1.20.5900      192.168.1.55.61234
            udp4       0      0  *.5901                 *.*
            """
        withNetstatFixture(fixture) {
            XCTAssertTrue(CaptureProbe.peeredUDPVNC())
            XCTAssertFalse(CaptureProbe.establishedVNC())
        }
    }

    /// signals() shells out once and derives both booleans from the same
    /// snapshot — confirm the combined struct is correct end-to-end for a
    /// peered-UDP-only fixture (captured stays false since CGSession is real
    /// system state here, unmocked; the test only asserts the network-derived
    /// fields).
    func testSignalsStructReflectsFixtureEndToEnd() {
        let fixture = """
            tcp4       0      0  192.168.1.20.5900      10.0.0.9.62000         ESTABLISHED
            """
        withNetstatFixture(fixture) {
            let signals = CaptureProbe.signals()
            XCTAssertTrue(signals.tcpEstablished)
            XCTAssertFalse(signals.udpPeered)
            XCTAssertTrue(signals.any)
        }
    }

    // MARK: - Shell-out watchdog timeout (ST1)

    /// Simulates a hung probe binary via the injection seam (no real process is
    /// spawned or slept on — this exercises CaptureProbe's handling of a
    /// `timedOut == true` result, not ProcessRunner's own polling loop, so the test
    /// completes instantly rather than waiting out a real timeout). Asserts the
    /// call still returns (empty string) rather than hanging, which is what
    /// guarantees a downstream coalescing flag like SessionMonitor.probing resets.
    func testHungProcessTimeoutStillReturns() {
        let original = CaptureProbe.processRunner
        CaptureProbe.processRunner = { _, _, timeout, _ in
            // Simulate ProcessRunner's own timeout contract: process was
            // terminated, timedOut is true, output is empty.
            XCTAssertEqual(timeout, CaptureProbe.shellTimeout)
            return (ProcessRunner.Result(output: "", exitCode: -1), true)
        }
        defer { CaptureProbe.processRunner = original }

        let start = Date()
        let output = CaptureProbe.netstatOutput()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(output, "")
        XCTAssertLessThan(elapsed, 1.0, "CaptureProbe must not itself block on a timed-out result")
    }

    /// establishedVNC()/peeredUDPVNC() must both read false (never crash, never
    /// hang) when the underlying shell-out times out — a hung probe must degrade
    /// to "no signal", never to a crash or a stuck read.
    func testTimeoutDegradesSignalsToFalseNotCrash() {
        let original = CaptureProbe.processRunner
        CaptureProbe.processRunner = { _, _, _, _ in
            (ProcessRunner.Result(output: "", exitCode: -1), true)
        }
        defer { CaptureProbe.processRunner = original }

        XCTAssertFalse(CaptureProbe.establishedVNC())
        XCTAssertFalse(CaptureProbe.peeredUDPVNC())
    }

    /// Exercises ProcessRunner's real timeout mechanism directly (not through the
    /// injection seam) with an actual long-running process (`sleep 30`) and a
    /// short 1s timeout, confirming the polling-based wait returns promptly rather
    /// than hanging the test suite — this is the fallback the ticket spec allows
    /// when the higher-level call site is hard to drive into a real hang.
    func testProcessRunnerRealTimeoutFiresAndTerminates() {
        let start = Date()
        let (result, timedOut) = ProcessRunner.run("/bin/sleep", ["30"], timeout: 1.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(timedOut)
        XCTAssertEqual(result.output, "")
        // Generous upper bound: the poll loop's default 50ms granularity means
        // this should return just over 1s, well under the 30s sleep duration.
        XCTAssertLessThan(
            elapsed, 5.0, "ProcessRunner must terminate the hung process near the timeout, not wait it out")
    }

    /// Regression test for a real bug found during T-P1-E10-03's verification pass:
    /// the timeout-bounded `run` overload never wired `standardOutput`, so
    /// CaptureProbe's netstat-based VNC corroborators (establishedVNC/peeredUDPVNC)
    /// always saw an empty string regardless of real command output. This proves
    /// stdout is now genuinely captured for a process that exits well within the
    /// timeout window (the common case for netstat/pgrep).
    func testProcessRunnerTimeoutOverloadCapturesStdout() {
        let (result, timedOut) = ProcessRunner.run("/bin/echo", ["hello-from-process-runner"], timeout: 5.0)

        XCTAssertFalse(timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello-from-process-runner")
    }

    // MARK: - Helpers

    private func withNetstatFixture(_ fixture: String, _ body: () -> Void) {
        let original = CaptureProbe.processRunner
        CaptureProbe.processRunner = { _, _, _, _ in
            (ProcessRunner.Result(output: fixture, exitCode: 0), false)
        }
        defer { CaptureProbe.processRunner = original }
        body()
    }
}
