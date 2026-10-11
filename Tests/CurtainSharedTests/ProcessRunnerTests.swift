import XCTest

@testable import CurtainShared

/// Purpose: regression tests for the bounded-timeout `ProcessRunner.run`.
/// The headline case is output larger than the 64 KB pipe buffer: `netstat -an` is
/// ~100 KB on a busy Mac, and the old implementation read the pipe only after exit, so
/// the child blocked on write until the timeout killed it (5 s late, truncated).
final class ProcessRunnerTests: XCTestCase {

    func testLargeOutputIsCapturedInFullWithoutTimeout() {
        let size = 400_000
        let started = Date()
        let (result, timedOut) = ProcessRunner.run(
            "/bin/sh", ["-c", "head -c \(size) /dev/zero | tr '\\0' 'a'"], timeout: 10)
        XCTAssertFalse(timedOut, "a child writing >64 KB must not deadlock on a full pipe")
        XCTAssertEqual(result.output.utf8.count, size)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "must finish promptly, not at the timeout")
    }

    func testHungProcessIsTerminatedAtTimeout() {
        let started = Date()
        let (_, timedOut) = ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testLaunchFailureReportsAndReturnsEmpty() {
        var reported = false
        let (result, timedOut) = ProcessRunner.run(
            "/nonexistent/binary", [], timeout: 1, onLaunchFailure: { _ in reported = true })
        XCTAssertTrue(reported)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.exitCode, -1)
    }

    func testSmallOutputStillCaptured() {
        let (result, timedOut) = ProcessRunner.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(result.output, "hello\n")
    }
}
