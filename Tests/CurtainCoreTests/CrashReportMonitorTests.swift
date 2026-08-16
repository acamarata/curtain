import XCTest
@testable import CurtainCore

/// Purpose: T-P1-E12-04 coverage for `CrashReportMonitor` — confirms the
///          recovery-launch threshold logic, the `.ips` report parser against
///          the real two-line NDJSON shape, and the full `check()`
///          orchestration's positive (new report + recovery-launch gap ->
///          send fires) and negative (ordinary-restart-sized gap -> no send)
///          cases via the injectable seams (`diagnosticReportsDirectory`,
///          `readLastHeartbeatTimestamp`, `readBootTime`, `sendSummary`) —
///          mirrors `KVMBridgeDeployerTests`' static-seam-swap-and-restore
///          discipline.
/// Inputs: none (each test writes fixture `.ips` files to a temp directory
///         and installs/restores the static seams).
/// Outputs: N/A (assertions only).
/// Constraints: `Settings.d` is redirected to an isolated UserDefaults suite
///          (same T-P1-E05-03 seam `SessionMonitorHeartbeatTests` uses) so
///          the persisted last-checked marker never touches real app
///          defaults. Every seam is restored in `tearDown` unconditionally.
/// SPORT: MASTER-APPS (Curtain.app, T-P1-E12-04)
@MainActor
final class CrashReportMonitorTests: XCTestCase {

    private var suiteName: String!
    private var originalDefaults: UserDefaults!
    private var originalDirectory: String!
    private var originalReadHeartbeat: (() -> Date?)!
    private var originalReadBootTime: (() -> Date?)!
    private var originalSendSummary: ((String, String) async -> Bool)!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "CrashReportMonitorTests.\(UUID().uuidString)"
        originalDefaults = Settings.d
        let isolated = UserDefaults(suiteName: suiteName)!
        isolated.removePersistentDomain(forName: suiteName)
        Settings.d = isolated

        originalDirectory = CrashReportMonitor.diagnosticReportsDirectory
        originalReadHeartbeat = CrashReportMonitor.readLastHeartbeatTimestamp
        originalReadBootTime = CrashReportMonitor.readBootTime
        originalSendSummary = CrashReportMonitor.sendSummary

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CrashReportMonitor.diagnosticReportsDirectory = tempDir.path
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        Settings.d = originalDefaults
        CrashReportMonitor.diagnosticReportsDirectory = originalDirectory
        CrashReportMonitor.readLastHeartbeatTimestamp = originalReadHeartbeat
        CrashReportMonitor.readBootTime = originalReadBootTime
        CrashReportMonitor.sendSummary = originalSendSummary
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixture helpers

    /// Writes a real-shaped `.ips` fixture: a compact header JSON line
    /// followed by a payload JSON line, matching the two-line NDJSON
    /// structure confirmed by inspecting a real `JetsamEvent-*.ips` file
    /// (`{"bug_type":...,"timestamp":...}` then a larger payload object) on
    /// this development machine, extended with `procName`/`termination`
    /// fields documented as present on real application-crash (bug_type
    /// "309") reports.
    @discardableResult
    private func writeFixtureReport(named name: String, procName: String = "Curtain") throws -> URL {
        let header = #"{"bug_type":"309","timestamp":"2026-08-15 12:00:00.00 -0400","incident_id":"TEST-\#(name)"}"#
        let payload = #"{"procName":"\#(procName)","termination":{"indicator":"Namespace SIGNAL, Code 6 Abort trap: 6"}}"#
        let url = tempDir.appendingPathComponent(name)
        try "\(header)\n\(payload)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Recovery-launch threshold

    func testIsRecoveryLaunchFalseWhenGapWithinThreshold() {
        let heartbeat = Date().addingTimeInterval(-30)
        let boot = Date()  // 30s gap — an ordinary graceful restart
        XCTAssertFalse(CrashReportMonitor.isRecoveryLaunch(lastHeartbeat: heartbeat, bootTime: boot))
    }

    func testIsRecoveryLaunchTrueWhenGapExceedsThreshold() {
        let heartbeat = Date().addingTimeInterval(-3600)
        let boot = Date()  // 1 hour gap — consistent with an unattended crash
        XCTAssertTrue(CrashReportMonitor.isRecoveryLaunch(lastHeartbeat: heartbeat, bootTime: boot))
    }

    func testIsRecoveryLaunchFalseWhenEitherTimestampMissing() {
        XCTAssertFalse(CrashReportMonitor.isRecoveryLaunch(lastHeartbeat: nil, bootTime: Date()))
        XCTAssertFalse(CrashReportMonitor.isRecoveryLaunch(lastHeartbeat: Date(), bootTime: nil))
        XCTAssertFalse(CrashReportMonitor.isRecoveryLaunch(lastHeartbeat: nil, bootTime: nil))
    }

    func testIsRecoveryLaunchFalseWhenGapIsNegative() {
        // Heartbeat written after boot time — clock skew or a fresh
        // install's first-ever heartbeat; not evidence of an unexpected
        // reboot either way.
        let heartbeat = Date()
        let boot = Date().addingTimeInterval(-3600)
        XCTAssertFalse(CrashReportMonitor.isRecoveryLaunch(lastHeartbeat: heartbeat, bootTime: boot))
    }

    // MARK: - .ips parsing

    func testParseReportExtractsProcessNameAndTerminationReason() throws {
        let url = try writeFixtureReport(named: "Curtain-crash.ips", procName: "Curtain")
        let parsed = CrashReportMonitor.parseReport(at: url)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed!.summary.contains("Curtain"))
        XCTAssertTrue(parsed!.summary.contains("Abort trap"))
        XCTAssertTrue(parsed!.summary.contains("309"))
    }

    func testParseReportReturnsNilForMalformedFile() throws {
        let url = tempDir.appendingPathComponent("garbage.ips")
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(CrashReportMonitor.parseReport(at: url))
    }

    func testScanForNewReportsOnlyReturnsFilesNewerThanSince() throws {
        let oldURL = try writeFixtureReport(named: "old.ips")
        // Backdate the "old" file well before `since`.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: oldURL.path)

        let since = Date().addingTimeInterval(-60)
        try writeFixtureReport(named: "new.ips")

        let results = CrashReportMonitor.scanForNewReports(since: since)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.fileName, "new.ips")
    }

    func testScanForNewReportsReturnsAllWhenSinceIsNil() throws {
        try writeFixtureReport(named: "a.ips")
        try writeFixtureReport(named: "b.ips")
        let results = CrashReportMonitor.scanForNewReports(since: nil)
        XCTAssertEqual(results.count, 2)
    }

    func testScanForNewReportsIgnoresNonIpsFiles() throws {
        try "irrelevant".write(
            to: tempDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let results = CrashReportMonitor.scanForNewReports(since: nil)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - check() orchestration (positive/negative, per ticket's acceptance criteria)

    /// Positive case: a new report exists AND the heartbeat-to-boot-time gap
    /// is consistent with an unexpected reboot -> the summary is built and
    /// `sendSummary` is invoked.
    func testCheckSendsSummaryOnRecoveryLaunchWithNewReport() async throws {
        try writeFixtureReport(named: "crash.ips")
        Settings.kvmBridgeHost = "pi.local"
        CrashReportMonitor.readLastHeartbeatTimestamp = { Date().addingTimeInterval(-3600) }
        CrashReportMonitor.readBootTime = { Date() }

        let sendExpectation = expectation(description: "sendSummary invoked")
        CrashReportMonitor.sendSummary = { host, summary in
            XCTAssertEqual(host, "pi.local")
            XCTAssertTrue(summary.contains("Curtain"))
            sendExpectation.fulfill()
            return true
        }

        await CrashReportMonitor.check()
        await fulfillment(of: [sendExpectation], timeout: 2)

        // Marker must advance so a re-run doesn't re-report the same file.
        XCTAssertNotNil(Settings.crashMonitorLastCheckedTimestamp)
    }

    /// Negative case: a new report exists but the gap is ordinary-restart-
    /// sized -> `sendSummary` must NOT be invoked, even though a report was
    /// found.
    func testCheckDoesNotSendOnOrdinaryRestartEvenWithNewReport() async throws {
        try writeFixtureReport(named: "crash.ips")
        Settings.kvmBridgeHost = "pi.local"
        CrashReportMonitor.readLastHeartbeatTimestamp = { Date().addingTimeInterval(-15) }
        CrashReportMonitor.readBootTime = { Date() }

        var sendWasCalled = false
        CrashReportMonitor.sendSummary = { _, _ in
            sendWasCalled = true
            return true
        }

        await CrashReportMonitor.check()

        XCTAssertFalse(sendWasCalled, "an ordinary-restart-sized gap must never trigger a Telegram relay")
        XCTAssertNotNil(Settings.crashMonitorLastCheckedTimestamp, "marker must still advance")
    }

    /// No new report at all -> never even reaches recovery-launch evaluation.
    func testCheckDoesNotSendWhenNoNewReportsExist() async {
        CrashReportMonitor.readLastHeartbeatTimestamp = { Date().addingTimeInterval(-3600) }
        CrashReportMonitor.readBootTime = { Date() }

        var sendWasCalled = false
        CrashReportMonitor.sendSummary = { _, _ in
            sendWasCalled = true
            return true
        }

        await CrashReportMonitor.check()
        XCTAssertFalse(sendWasCalled)
    }

    /// A recovery launch with a new report but no configured Bridge host ->
    /// nothing to relay through, must not crash and must not call sendSummary.
    func testCheckDoesNotSendWhenNoBridgeHostConfigured() async throws {
        try writeFixtureReport(named: "crash.ips")
        Settings.kvmBridgeHost = nil
        CrashReportMonitor.readLastHeartbeatTimestamp = { Date().addingTimeInterval(-3600) }
        CrashReportMonitor.readBootTime = { Date() }

        var sendWasCalled = false
        CrashReportMonitor.sendSummary = { _, _ in
            sendWasCalled = true
            return true
        }

        await CrashReportMonitor.check()
        XCTAssertFalse(sendWasCalled)
    }

    /// Idempotency: running check() twice in a row with no new reports
    /// between runs must not re-send.
    func testCheckIsIdempotentAcrossRepeatedCalls() async throws {
        try writeFixtureReport(named: "crash.ips")
        Settings.kvmBridgeHost = "pi.local"
        CrashReportMonitor.readLastHeartbeatTimestamp = { Date().addingTimeInterval(-3600) }
        CrashReportMonitor.readBootTime = { Date() }

        var sendCount = 0
        CrashReportMonitor.sendSummary = { _, _ in
            sendCount += 1
            return true
        }

        await CrashReportMonitor.check()
        await CrashReportMonitor.check()

        XCTAssertEqual(sendCount, 1, "the second run's marker should already cover the first run's report")
    }
}
