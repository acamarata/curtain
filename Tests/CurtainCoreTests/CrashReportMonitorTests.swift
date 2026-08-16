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

    /// Test-only stand-in bearer token, mirroring
    /// `KVMBridgeDeployerTests.stubBridgeAuthToken`. `check()` now guards on
    /// `Settings.kvmBridgeAuthToken` being present (security follow-up)
    /// BEFORE calling `sendSummary` at all — every positive-path test below
    /// sets this in the isolated `Settings.d` suite `setUp` already redirects
    /// to, so it never touches real app defaults.
    private static let stubBridgeAuthToken = "test-crash-monitor-auth-token"

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
        let payload =
            #"{"procName":"\#(procName)","termination":{"indicator":"Namespace SIGNAL, Code 6 Abort trap: 6"}}"#
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
        Settings.kvmBridgeAuthToken = Self.stubBridgeAuthToken
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
        Settings.kvmBridgeAuthToken = Self.stubBridgeAuthToken
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
        Settings.kvmBridgeAuthToken = Self.stubBridgeAuthToken
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
        Settings.kvmBridgeAuthToken = Self.stubBridgeAuthToken
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

    // MARK: - Auth token guard (security follow-up)

    /// A recovery launch with a new report and a configured host, but NO
    /// stored auth token (e.g. an install from before this security fix that
    /// hasn't been re-run through the setup wizard) -> must not call
    /// sendSummary at all, and must produce the distinct log path rather than
    /// silently sending an unauthenticated request the Bridge would 401.
    func testCheckDoesNotSendWhenNoBridgeAuthTokenStored() async throws {
        try writeFixtureReport(named: "crash.ips")
        Settings.kvmBridgeHost = "pi.local"
        Settings.kvmBridgeAuthToken = nil
        CrashReportMonitor.readLastHeartbeatTimestamp = { Date().addingTimeInterval(-3600) }
        CrashReportMonitor.readBootTime = { Date() }

        var sendWasCalled = false
        CrashReportMonitor.sendSummary = { _, _ in
            sendWasCalled = true
            return true
        }

        await CrashReportMonitor.check()

        XCTAssertFalse(sendWasCalled, "no relay attempt should ever be made without a stored auth token")
        XCTAssertNotNil(Settings.crashMonitorLastCheckedTimestamp, "marker must still advance")
    }

    /// Confirms the production `sendSummary` closure itself attaches the
    /// stored token as an `Authorization: Bearer <token>` header — this test
    /// swaps back to the REAL closure (not the test-installed fake) to
    /// verify the header-attachment behavior directly, using a
    /// `URLProtocol` intercept (Foundation's own documented mechanism for
    /// observing an outgoing `URLRequest` without a real network call) so
    /// the test proves the ACTUAL production closure — not a stand-in —
    /// attaches the header.
    func testProductionSendSummaryAttachesAuthorizationHeader() async throws {
        Settings.kvmBridgeAuthToken = Self.stubBridgeAuthToken
        _CapturingURLProtocol.capturedAuthorizationHeader = nil
        _CapturingURLProtocol.register()
        defer { _CapturingURLProtocol.unregister() }

        // Exercise the REAL production closure (CrashReportMonitor.sendSummary's
        // default value), not a test-installed fake -- this is what makes the
        // test a genuine regression guard on the header-attachment code path.
        // `URLSession.shared` cannot have a protocol class injected after the
        // fact, so this relies on `URLProtocol.registerClass`, which
        // URLSession's default configuration consults for every request.
        _ = await CrashReportMonitor.sendSummary("192.0.2.1", "test summary")

        XCTAssertEqual(_CapturingURLProtocol.capturedAuthorizationHeader, "Bearer \(Self.stubBridgeAuthToken)")
    }
}

// MARK: - URLProtocol-based request capture (file-private, test-only)

/// Purpose: intercepts every outgoing `URLRequest` made through
/// `URLSession.shared` (via `URLProtocol.registerClass`, Foundation's
/// documented mechanism for this) so
/// `testProductionSendSummaryAttachesAuthorizationHeader` can inspect the
/// REAL header `CrashReportMonitor.sendSummary`'s production closure
/// attaches, without a real network call and without the risks of a
/// hand-rolled socket server under Swift 6 strict concurrency.
/// Inputs: none (registered/unregistered per-test). Outputs: captures the
/// request's `Authorization` header into a static var the test reads after
/// the request completes; responds with a synthetic 200 so the awaiting
/// `sendSummary` call completes normally.
/// Constraints: test-only. `capturedAuthorizationHeader` is deliberately
/// static (URLProtocol instances are created internally by URLSession, not
/// by the test) — safe here since exactly one test in this file registers
/// this class and it is unregistered in that test's `defer`.
private final class _CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capturedAuthorizationHeader: String?

    static func register() { URLProtocol.registerClass(_CapturingURLProtocol.self) }
    static func unregister() { URLProtocol.unregisterClass(_CapturingURLProtocol.self) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        _CapturingURLProtocol.capturedAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: "{}".data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
