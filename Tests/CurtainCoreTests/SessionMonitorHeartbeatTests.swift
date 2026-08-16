import XCTest
@testable import CurtainCore

/// Purpose: T-P1-E10-01 coverage for SessionMonitor's crash-recovery heartbeat file
///          — the on-disk liveness signal `launchctl`/`ps` cannot provide (see
///          SessionMonitor.writeHeartbeat's doc comment).
/// How: starts a real SessionMonitor (real Timer, real probeQueue, real shell-out
///      probes — CaptureProbe.signals() runs for real here; on CI/dev machines with
///      no active Screen Sharing session this simply reports `connected == false`,
///      which is exactly the state this test asserts against). Waits across real
///      2s tick boundaries (no fast-forward seam exists for the Timer, so this test
///      accepts a real wall-clock wait, per the ticket's guidance) and reads the
///      heartbeat file from disk on every assertion — never from in-memory state —
///      so a regression that stops the file write (but leaves in-memory state
///      correct) still fails this test.
/// Constraints: writes to an isolated per-test-run temp directory via
///      `SessionMonitor.heartbeatDirectoryOverride` (the injection seam this file's
///      own fix added) rather than the real `~/Library/Application
///      Support/Curtain/heartbeat.json` path — a prior version of this file used
///      that real, non-injectable path, which meant a real `SessionMonitor`
///      instance here could race `MCPServerTests` (a different XCTestCase, in a
///      different test target, both linked into the same `swift test` process)
///      writing/reading that exact same shared file. See CHANGELOG.md's
///      `[Unreleased]` entry for the observed failure and the fix. Settings is
///      redirected to an isolated UserDefaults suite (the same T-P1-E05-03 `d`
///      seam SessionCoordinatorTests uses) so `Settings.armed` is deterministic
///      without touching real app defaults.
/// SPORT: MASTER-SESSIONMONITOR
@MainActor
final class SessionMonitorHeartbeatTests: XCTestCase {

    private var suiteName: String!
    private var originalDefaults: UserDefaults!
    private var heartbeatURL: URL!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "SessionMonitorHeartbeatTests.\(UUID().uuidString)"
        originalDefaults = Settings.d
        let isolated = UserDefaults(suiteName: suiteName)!
        isolated.removePersistentDomain(forName: suiteName)
        Settings.d = isolated
        Settings.armed = true

        // Isolated per-test-run directory: unique per test invocation (not just per
        // test class) so even repeated runs of this same test never collide with a
        // leftover directory from a prior run. Never the real Application Support
        // path — see this file's Constraints doc above.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionMonitorHeartbeatTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        SessionMonitor.heartbeatDirectoryOverride = tempDir
        heartbeatURL = tempDir.appendingPathComponent("heartbeat.json")
    }

    override func tearDown() {
        SessionMonitor.heartbeatDirectoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults().removePersistentDomain(forName: suiteName)
        Settings.d = originalDefaults
        super.tearDown()
    }

    // MARK: - Helpers

    private struct HeartbeatPayload: Decodable {
        let timestamp: String
        let armed: Bool
        let connected: Bool
        let idleArmed: Bool
        let idleFired: Bool
    }

    /// Reads and decodes the real on-disk heartbeat file. Fails the test (rather
    /// than returning nil) on any read/decode error so a broken write is a loud
    /// failure, not a silently-skipped assertion.
    private func readHeartbeat(file: StaticString = #filePath, line: UInt = #line) throws -> HeartbeatPayload {
        let data = try Data(contentsOf: heartbeatURL)
        return try JSONDecoder().decode(HeartbeatPayload.self, from: data)
    }

    private func isoDate(_ s: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }

    // MARK: - Tests

    /// Starts the monitor, waits across two real tick cycles (pollInterval ~2s), and
    /// asserts the heartbeat file exists on disk with a fresh timestamp and fields
    /// matching the known test state (armed = true, connected = false — no real
    /// Screen Sharing session is active in a test process).
    func testHeartbeatWrittenAcrossRealTickCycles() throws {
        let monitor = SessionMonitor()
        monitor.start()
        defer { monitor.stop() }

        let firstExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: self.heartbeatURL.path) },
            object: nil)
        // 20s, not the shellTimeout-adjacent 5s: CaptureProbe's own probes are bounded
        // by a 5s `shellTimeout`, so under heavy concurrent CPU/swap load (several
        // parallel `swift build`/`swift test` invocations routinely happening during
        // this project's multi-agent build sessions) a single tick's probe queue can
        // itself take close to 5s before the first write even happens — a flake
        // observed directly at exactly the 5s bound. Same widened-tolerance reasoning
        // as this file's other waits (see below): no real coverage is lost by a
        // generous bound here since the assertions that follow still verify content,
        // not just timing.
        wait(for: [firstExpectation], timeout: 20)

        let first = try readHeartbeat()
        XCTAssertTrue(first.armed)
        XCTAssertFalse(first.connected)
        guard let firstDate = isoDate(first.timestamp) else {
            return XCTFail("heartbeat.json timestamp is not valid ISO 8601: \(first.timestamp)")
        }
        // 20s tolerance, not the write cadence's 2s: `wait(for:timeout:)` only polls
        // its NSPredicate periodically, and under heavy concurrent CPU load (e.g.
        // several parallel `swift build`/`swift test` invocations, as happens
        // routinely during this project's multi-agent build sessions) the runloop
        // itself can be delayed well past the file's actual write time before this
        // assertion runs — a flake observed directly (6.5s elapsed) with the
        // original 5s bound. The product's own freshness contract only cares about
        // minute-scale staleness (see this file's own doc comment and
        // heartbeat.json's documented "monitoring signal" role), so a generous
        // test-side bound loses no real coverage.
        XCTAssertLessThan(abs(firstDate.timeIntervalSinceNow), 20, "heartbeat timestamp should be recent")

        // Wait across at least one more full tick (pollInterval = 2s) so the
        // timestamp is asserted to actually advance, not merely exist once. 20s,
        // not the 2s tick cadence — same widened-tolerance reasoning as the
        // `firstExpectation` wait above: a probe queue bounded by CaptureProbe's 5s
        // `shellTimeout` can itself eat several seconds per tick under heavy
        // concurrent CPU/swap load, so two ticks' worth of margin at a tight bound
        // flakes exactly the way this was observed to (6.4s elapsed against the
        // prior 6s bound).
        let secondExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: self.heartbeatURL),
                    let payload = try? JSONDecoder().decode(HeartbeatPayload.self, from: data),
                    let date = self.isoDate(payload.timestamp)
                else { return false }
                return date > firstDate
            },
            object: nil)
        wait(for: [secondExpectation], timeout: 20)

        let second = try readHeartbeat()
        guard let secondDate = isoDate(second.timestamp) else {
            return XCTFail("heartbeat.json timestamp is not valid ISO 8601: \(second.timestamp)")
        }
        XCTAssertGreaterThan(secondDate, firstDate, "heartbeat timestamp must advance across tick cycles")
    }

    /// Confirms the heartbeat file is overwritten in place, not appended: file size
    /// stays roughly constant (a single JSON object) across multiple tick cycles,
    /// rather than growing as a log would.
    func testHeartbeatOverwritesRatherThanAppends() throws {
        let monitor = SessionMonitor()
        monitor.start()
        defer { monitor.stop() }

        let firstExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: self.heartbeatURL.path) },
            object: nil)
        // 20s, not the shellTimeout-adjacent 5s: CaptureProbe's own probes are bounded
        // by a 5s `shellTimeout`, so under heavy concurrent CPU/swap load (several
        // parallel `swift build`/`swift test` invocations routinely happening during
        // this project's multi-agent build sessions) a single tick's probe queue can
        // itself take close to 5s before the first write even happens — a flake
        // observed directly at exactly the 5s bound. Same widened-tolerance reasoning
        // as this file's other waits (see below): no real coverage is lost by a
        // generous bound here since the assertions that follow still verify content,
        // not just timing.
        wait(for: [firstExpectation], timeout: 20)

        let sizeAfterFirstTick =
            try FileManager.default.attributesOfItem(atPath: heartbeatURL.path)[.size] as? Int ?? -1

        // Sleep across ~3 more tick cycles (pollInterval = 2s) so the file is
        // rewritten several more times.
        let laterExpectation = expectation(description: "wait for additional ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { laterExpectation.fulfill() }
        wait(for: [laterExpectation], timeout: 8)

        let sizeAfterLaterTicks =
            try FileManager.default.attributesOfItem(atPath: heartbeatURL.path)[.size] as? Int ?? -1

        XCTAssertGreaterThan(sizeAfterFirstTick, 0)
        // A fixed-shape JSON object's encoded size varies by at most a few bytes
        // (timestamp second-digit width, bool literal lengths never change) — an
        // append-based bug would instead multiply the size several-fold.
        XCTAssertLessThan(
            abs(sizeAfterLaterTicks - sizeAfterFirstTick), 8,
            "heartbeat.json size should stay roughly constant (overwrite), not grow (append): \(sizeAfterFirstTick) -> \(sizeAfterLaterTicks)"
        )

        // Also confirm it decodes as exactly one JSON object, not concatenated/appended fragments.
        _ = try readHeartbeat()
    }

    /// Confirms the `armed` field reflects `Settings.armed` at tick time — flipping
    /// the setting and waiting one more tick should flip the on-disk field too.
    func testHeartbeatArmedFieldTracksSettings() throws {
        let monitor = SessionMonitor()
        monitor.start()
        defer { monitor.stop() }

        let firstExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: self.heartbeatURL.path) },
            object: nil)
        // 20s, not the shellTimeout-adjacent 5s: CaptureProbe's own probes are bounded
        // by a 5s `shellTimeout`, so under heavy concurrent CPU/swap load (several
        // parallel `swift build`/`swift test` invocations routinely happening during
        // this project's multi-agent build sessions) a single tick's probe queue can
        // itself take close to 5s before the first write even happens — a flake
        // observed directly at exactly the 5s bound. Same widened-tolerance reasoning
        // as this file's other waits (see below): no real coverage is lost by a
        // generous bound here since the assertions that follow still verify content,
        // not just timing.
        wait(for: [firstExpectation], timeout: 20)
        XCTAssertTrue(try readHeartbeat().armed)

        Settings.armed = false

        let flippedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: self.heartbeatURL),
                    let payload = try? JSONDecoder().decode(HeartbeatPayload.self, from: data)
                else { return false }
                return payload.armed == false
            },
            object: nil)
        // 20s, not the write cadence's 2s — same widened-tolerance reasoning as
        // `testHeartbeatWrittenAcrossRealTickCycles` above: `wait(for:timeout:)`
        // only polls its NSPredicate periodically, and under heavy concurrent CPU
        // load (several parallel `swift build`/`swift test` invocations, as
        // happens routinely during this project's multi-agent build sessions) the
        // runloop can be delayed well past the point Settings.armed actually
        // flipped and SessionMonitor's next tick actually wrote it — a flake
        // observed directly with the original 6s bound. This is a real product
        // requirement question ("does armed flip within N seconds") only at
        // minute-scale (see writeHeartbeat's doc comment on the field's
        // "monitoring signal" role), so a generous test-side bound loses no real
        // coverage.
        wait(for: [flippedExpectation], timeout: 20)

        XCTAssertFalse(try readHeartbeat().armed)
    }
}
