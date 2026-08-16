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
/// Constraints: writes to the REAL `~/Library/Application Support/Curtain/
///      heartbeat.json` path (there is no injectable path seam — this mirrors
///      CrashSignalHandler's fixed-path convention). Settings is redirected to an
///      isolated UserDefaults suite (the same T-P1-E05-03 `d` seam
///      SessionCoordinatorTests uses) so `Settings.armed` is deterministic without
///      touching real app defaults.
/// SPORT: MASTER-SESSIONMONITOR
@MainActor
final class SessionMonitorHeartbeatTests: XCTestCase {

    private var suiteName: String!
    private var originalDefaults: UserDefaults!
    private var heartbeatURL: URL!

    override func setUp() {
        super.setUp()
        suiteName = "SessionMonitorHeartbeatTests.\(UUID().uuidString)"
        originalDefaults = Settings.d
        let isolated = UserDefaults(suiteName: suiteName)!
        isolated.removePersistentDomain(forName: suiteName)
        Settings.d = isolated
        Settings.armed = true

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Curtain", isDirectory: true)
        heartbeatURL = dir.appendingPathComponent("heartbeat.json")
    }

    override func tearDown() {
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
        wait(for: [firstExpectation], timeout: 5)

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
        // timestamp is asserted to actually advance, not merely exist once.
        let secondExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: self.heartbeatURL),
                    let payload = try? JSONDecoder().decode(HeartbeatPayload.self, from: data),
                    let date = self.isoDate(payload.timestamp)
                else { return false }
                return date > firstDate
            },
            object: nil)
        wait(for: [secondExpectation], timeout: 6)

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
        wait(for: [firstExpectation], timeout: 5)

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
        wait(for: [firstExpectation], timeout: 5)
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
        wait(for: [flippedExpectation], timeout: 6)

        XCTAssertFalse(try readHeartbeat().armed)
    }
}
