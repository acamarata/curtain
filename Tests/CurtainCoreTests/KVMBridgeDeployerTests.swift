import XCTest
import CurtainShared
@testable import CurtainCore

/// Purpose: Coverage for `KVMBridgeDeployer`'s SSH-based deploy/verify/token-relay/
///          update logic via the injected `processRunner`/`processRunnerStdin`
///          seams (mirrors `CaptureProbeTests`' pattern for `CaptureProbe.processRunner`).
///          The mocked-seam tests below run unconditionally in CI/any environment
///          and assert exact argv + error propagation without a real network call.
///          A second group, gated behind `CURTAIN_LOCAL_SSH_TEST=1`, exercises the
///          real `ssh`/`ssh-keyscan` binaries against `127.0.0.1` as the "local SSH
///          stand-in" the ticket calls for.
/// Inputs: none (each test installs/restores the deployer's static seams).
/// Outputs: N/A (assertions only).
/// Constraints: `KVMBridgeDeployer.processRunner`/`processRunnerStdin` are shared
///              static vars, so every test restores the original in `defer` —
///              same discipline as `CaptureProbeTests`.
///
///              LOCAL SSH STAND-IN STATUS (verified this session, 2026-08-15):
///              this development machine does NOT have a local SSH server
///              enabled — `ssh -o ConnectTimeout=3 -o BatchMode=yes localhost
///              echo ok` returned "Connection refused" (port 22 closed), and
///              enabling Remote Login (`systemsetup -setremotelogin`) requires
///              sudo credentials not available non-interactively in this
///              environment. The gated tests below are therefore SKIPPED (not
///              deleted) in this run — `testGatedLocalSSHRoundTrip` reports via
///              `XCTSkip` with the exact reason. To run them for real: on a Mac
///              with System Settings > General > Sharing > Remote Login enabled
///              (or any reachable Linux/macOS SSH host), set
///              `CURTAIN_LOCAL_SSH_TEST=1` and `CURTAIN_LOCAL_SSH_HOST` (defaults
///              to `127.0.0.1`) and re-run `swift test`.
/// SPORT: MASTER-APPS (Curtain.app KVM Bridge setup wizard, code-complete-hardware-unverified)
final class KVMBridgeDeployerTests: XCTestCase {

    // MARK: - Mocked-seam tests (unconditional)

    func testDeployFailsFastWhenHostKeyNotTrusted() async {
        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: false)
        let result = await KVMBridgeDeployer.deploy(target: target, localBridgePath: "/tmp/Bridge")
        switch result {
        case .success:
            XCTFail("deploy() must not proceed without an explicitly trusted host key")
        case .failure(let error):
            XCTAssertEqual(error, .hostKeyNotTrusted)
        }
    }

    func testVerifyFailsFastWhenHostKeyNotTrusted() async {
        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: false)
        let result = await KVMBridgeDeployer.verify(target: target)
        switch result {
        case .success:
            XCTFail("verify() must not proceed without an explicitly trusted host key")
        case .failure(let error):
            XCTAssertEqual(error, .hostKeyNotTrusted)
        }
    }

    func testSendTelegramTokenFailsFastWhenHostKeyNotTrusted() {
        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: false)
        let result = KVMBridgeDeployer.sendTelegramToken(target: target, token: "123:abc")
        switch result {
        case .success:
            XCTFail("sendTelegramToken() must not proceed without an explicitly trusted host key")
        case .failure(let error):
            XCTAssertEqual(error, .hostKeyNotTrusted)
        }
    }

    /// Regression guard for the never-silently-disabled host-key requirement:
    /// even with a trusted target, confirms the exact ssh option string used is
    /// `accept-new`, never `no` — a mutation to `=no` here would defeat the
    /// MITM protection this ticket's CR-C gate specifically checks for.
    func testDeployUsesAcceptNewNeverDisablesHostKeyChecking() async {
        var capturedArgsByPath: [String: [String]] = [:]
        let originalRunner = KVMBridgeDeployer.processRunner
        KVMBridgeDeployer.processRunner = { path, args, _, _ in
            capturedArgsByPath[path] = args
            return (ProcessRunner.Result(output: "active", exitCode: 0), false)
        }
        defer { KVMBridgeDeployer.processRunner = originalRunner }

        let target = KVMBridgeDeployer.Target(
            host: "pi.local", user: "pilot", keyPath: "/tmp/id_ed25519", trustHostKey: true)
        _ = await KVMBridgeDeployer.verify(target: target)

        let sshArgs = capturedArgsByPath["/usr/bin/ssh"]
        XCTAssertNotNil(sshArgs)
        XCTAssertTrue(sshArgs?.contains("StrictHostKeyChecking=accept-new") == true)
        XCTAssertFalse(sshArgs?.contains("StrictHostKeyChecking=no") == true)
        XCTAssertTrue(sshArgs?.contains("-i") == true)
        XCTAssertTrue(sshArgs?.contains("/tmp/id_ed25519") == true)
    }

    func testVerifyReportsActiveOnTrimmedActiveOutput() async {
        let originalRunner = KVMBridgeDeployer.processRunner
        KVMBridgeDeployer.processRunner = { _, _, _, _ in
            (ProcessRunner.Result(output: "active\n", exitCode: 0), false)
        }
        defer { KVMBridgeDeployer.processRunner = originalRunner }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let result = await KVMBridgeDeployer.verify(target: target)
        guard case .success(let outcome) = result else { return XCTFail("expected success") }
        XCTAssertTrue(outcome.serviceActive)
        XCTAssertEqual(outcome.statusOutput, "active")
    }

    func testVerifyReportsInactiveWithoutErroringWhenServiceStopped() async {
        // `systemctl is-active` exits non-zero for "inactive" — this must still
        // surface as a DeployOutcome, not a DeployError (see verify()'s doc
        // comment on why non-active states are informative, not launch failures).
        let originalRunner = KVMBridgeDeployer.processRunner
        KVMBridgeDeployer.processRunner = { _, _, _, _ in
            (ProcessRunner.Result(output: "inactive\n", exitCode: 3), false)
        }
        defer { KVMBridgeDeployer.processRunner = originalRunner }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let result = await KVMBridgeDeployer.verify(target: target)
        guard case .success(let outcome) = result else {
            return XCTFail("expected success, not an error, for a non-active-but-reachable service")
        }
        XCTAssertFalse(outcome.serviceActive)
        XCTAssertEqual(outcome.statusOutput, "inactive")
    }

    func testDeployPropagatesRsyncFailureWithoutRunningRemoteInstall() async {
        var sshInvoked = false
        let originalRunner = KVMBridgeDeployer.processRunner
        KVMBridgeDeployer.processRunner = { path, _, _, _ in
            if path == "/usr/bin/ssh" { sshInvoked = true }
            if path == KVMBridgeDeployer.rsyncPath {
                return (ProcessRunner.Result(output: "rsync: connection unexpectedly closed", exitCode: 12), false)
            }
            return (ProcessRunner.Result(output: "", exitCode: 0), false)
        }
        defer { KVMBridgeDeployer.processRunner = originalRunner }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let result = await KVMBridgeDeployer.deploy(target: target, localBridgePath: "/tmp/Bridge")

        switch result {
        case .success:
            XCTFail("a failed rsync must abort deploy(), not proceed to remote install")
        case .failure(let error):
            guard case .sshFailed(let step, let exitCode, _) = error else {
                return XCTFail("expected .sshFailed, got \(error)")
            }
            XCTAssertEqual(step, "rsync")
            XCTAssertEqual(exitCode, 12)
        }
        XCTAssertFalse(sshInvoked, "ssh must never run after rsync fails — the Pi is left in a known, untouched state")
    }

    func testSendTelegramTokenPipesTokenViaStdinNotArgv() {
        var capturedStdin: Data?
        var capturedArgs: [String]?
        let originalRunner = KVMBridgeDeployer.processRunnerStdin
        KVMBridgeDeployer.processRunnerStdin = { _, args, stdin, _ in
            capturedArgs = args
            capturedStdin = stdin
            return ProcessRunner.Result(output: "", exitCode: 0)
        }
        defer { KVMBridgeDeployer.processRunnerStdin = originalRunner }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let secretToken = "123456789:AAExampleTokenValueNeverInArgv"
        let result = KVMBridgeDeployer.sendTelegramToken(target: target, token: secretToken)

        guard case .success = result else { return XCTFail("expected success") }
        XCTAssertEqual(capturedStdin, secretToken.data(using: .utf8))
        // The token must never appear as a literal argv element — argv is
        // visible to other processes via `ps`, stdin is not.
        XCTAssertFalse(capturedArgs?.contains(secretToken) == true)
    }

    func testCheckForUpdateDetectsVersionSkew() async {
        let originalRunner = KVMBridgeDeployer.processRunner
        KVMBridgeDeployer.processRunner = { _, _, _, _ in
            (ProcessRunner.Result(output: "0.0.9\n", exitCode: 0), false)
        }
        defer { KVMBridgeDeployer.processRunner = originalRunner }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let result = await KVMBridgeDeployer.checkForUpdate(target: target)
        guard case .success(let (remoteVersion, needsUpdate)) = result else { return XCTFail("expected success") }
        XCTAssertEqual(remoteVersion, "0.0.9")
        XCTAssertTrue(needsUpdate)
    }

    func testCheckForUpdateReportsNoSkewWhenVersionsMatch() async {
        let originalRunner = KVMBridgeDeployer.processRunner
        KVMBridgeDeployer.processRunner = { _, _, _, _ in
            (ProcessRunner.Result(output: KVMBridgeDeployer.expectedBridgeVersion, exitCode: 0), false)
        }
        defer { KVMBridgeDeployer.processRunner = originalRunner }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let result = await KVMBridgeDeployer.checkForUpdate(target: target)
        guard case .success(let (_, needsUpdate)) = result else { return XCTFail("expected success") }
        XCTAssertFalse(needsUpdate)
    }

    func testFetchHostKeyFingerprintSurfacesEmptyOutputAsFailure() {
        let originalRunner = KVMBridgeDeployer.processRunner
        KVMBridgeDeployer.processRunner = { _, _, _, _ in
            (ProcessRunner.Result(output: "", exitCode: 0), false)
        }
        defer { KVMBridgeDeployer.processRunner = originalRunner }

        let result = KVMBridgeDeployer.fetchHostKeyFingerprint(host: "unreachable.invalid")
        switch result {
        case .success:
            XCTFail("empty ssh-keyscan output must not be treated as a fetched fingerprint")
        case .failure:
            break
        }
    }

    // MARK: - compareVersions (pure logic, no network)

    func testCompareVersionsDetectsMismatch() {
        XCTAssertTrue(KVMBridgeDeployer.compareVersions(local: "0.1.0", remote: "0.1.1"))
        XCTAssertTrue(KVMBridgeDeployer.compareVersions(local: "0.1.0", remote: "0.0.9"))
        XCTAssertTrue(KVMBridgeDeployer.compareVersions(local: "1.0.0", remote: "2.0.0"))
    }

    func testCompareVersionsReportsNoMismatchWhenEqual() {
        XCTAssertFalse(KVMBridgeDeployer.compareVersions(local: "0.1.0", remote: "0.1.0"))
    }

    func testCompareVersionsTreatsUnparseableRemoteAsNeedingUpdate() {
        // Conservative-by-design per this method's doc comment: an
        // unparseable version string must never be silently treated as
        // "no update needed".
        XCTAssertTrue(KVMBridgeDeployer.compareVersions(local: "0.1.0", remote: "not-a-version"))
        XCTAssertTrue(KVMBridgeDeployer.compareVersions(local: "0.1.0", remote: "0.1"))
        XCTAssertTrue(KVMBridgeDeployer.compareVersions(local: "0.1.0", remote: ""))
    }

    func testCompareVersionsTreatsUnparseableLocalAsNeedingUpdate() {
        XCTAssertTrue(KVMBridgeDeployer.compareVersions(local: "bogus", remote: "0.1.0"))
    }

    // MARK: - checkHealth (network seam stubbed, no real HTTP call)

    private func stubHealthSession(
        statusCode: Int = 200,
        body: Data?,
        error: Error? = nil
    ) {
        KVMBridgeDeployer.healthURLSession = { url in
            if let error {
                return (nil, nil, error)
            }
            let response = HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil
            )
            return (body, response, nil)
        }
    }

    func testCheckHealthParsesSuccessfulResponse() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        defer { KVMBridgeDeployer.healthURLSession = originalSession }
        let json = """
            {"status": "ok", "version": "0.1.0", "uptime_seconds": 42}
            """.data(using: .utf8)
        stubHealthSession(body: json)

        let result = await KVMBridgeDeployer.checkHealth(host: "pi.local")
        guard case .success(let status) = result else { return XCTFail("expected success") }
        XCTAssertEqual(status.status, "ok")
        XCTAssertEqual(status.version, "0.1.0")
        XCTAssertEqual(status.uptimeSeconds, 42)
        XCTAssertTrue(status.isHealthy)
    }

    func testCheckHealthRequestsExpectedURL() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        defer { KVMBridgeDeployer.healthURLSession = originalSession }
        var capturedURL: URL?
        KVMBridgeDeployer.healthURLSession = { url in
            capturedURL = url
            let json = """
                {"status": "ok", "version": "0.1.0", "uptime_seconds": 1}
                """.data(using: .utf8)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            return (json, response, nil)
        }

        _ = await KVMBridgeDeployer.checkHealth(host: "192.168.1.50")
        XCTAssertEqual(capturedURL?.absoluteString, "http://192.168.1.50:8642/health")
    }

    func testCheckHealthFailsOnNonJSONBody() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        defer { KVMBridgeDeployer.healthURLSession = originalSession }
        stubHealthSession(body: "not json".data(using: .utf8))

        let result = await KVMBridgeDeployer.checkHealth(host: "pi.local")
        switch result {
        case .success:
            XCTFail("malformed JSON body must not parse as success")
        case .failure(let error):
            guard case .decodingFailed = error else { return XCTFail("expected .decodingFailed, got \(error)") }
        }
    }

    func testCheckHealthFailsOnNon200Status() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        defer { KVMBridgeDeployer.healthURLSession = originalSession }
        stubHealthSession(statusCode: 503, body: nil)

        let result = await KVMBridgeDeployer.checkHealth(host: "pi.local")
        switch result {
        case .success:
            XCTFail("503 must not be treated as success")
        case .failure(let error):
            XCTAssertEqual(error, .unexpectedStatusCode(503))
        }
    }

    func testCheckHealthFailsOnNetworkError() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        defer { KVMBridgeDeployer.healthURLSession = originalSession }
        struct FakeNetworkError: Error {}
        stubHealthSession(body: nil, error: FakeNetworkError())

        let result = await KVMBridgeDeployer.checkHealth(host: "pi.local")
        switch result {
        case .success:
            XCTFail("a transport-level error must not be treated as success")
        case .failure(let error):
            guard case .requestFailed = error else { return XCTFail("expected .requestFailed, got \(error)") }
        }
    }

    // MARK: - performUpdateIfNeeded (decision logic, seams stubbed)

    /// Feeds `healthURLSession` a sequence of canned bodies, one per call —
    /// used to simulate the pre-update health check followed by the
    /// post-update health check returning different versions.
    private func stubHealthSessionSequence(_ bodies: [Data]) {
        var remaining = bodies
        KVMBridgeDeployer.healthURLSession = { url in
            let body = remaining.isEmpty ? bodies.last : remaining.removeFirst()
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            return (body, response, nil)
        }
    }

    func testPerformUpdateIfNeededSkipsDeployWhenVersionsMatch() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        let originalRunner = KVMBridgeDeployer.processRunner
        defer {
            KVMBridgeDeployer.healthURLSession = originalSession
            KVMBridgeDeployer.processRunner = originalRunner
        }
        let json = """
            {"status": "ok", "version": "\(KVMBridgeDeployer.expectedBridgeVersion)", "uptime_seconds": 5}
            """.data(using: .utf8)!
        stubHealthSessionSequence([json])
        var deployInvoked = false
        KVMBridgeDeployer.processRunner = { _, _, _, _ in
            deployInvoked = true
            return (ProcessRunner.Result(output: "active", exitCode: 0), false)
        }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let outcome = await KVMBridgeDeployer.performUpdateIfNeeded(target: target, localBridgePath: "/tmp/Bridge")

        guard case .upToDate(let version) = outcome else { return XCTFail("expected .upToDate, got \(outcome)") }
        XCTAssertEqual(version, KVMBridgeDeployer.expectedBridgeVersion)
        XCTAssertFalse(deployInvoked, "no redeploy should be triggered when versions already match")
    }

    func testPerformUpdateIfNeededTriggersDeployAndReportsUpdatedOnMismatch() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        let originalRunner = KVMBridgeDeployer.processRunner
        defer {
            KVMBridgeDeployer.healthURLSession = originalSession
            KVMBridgeDeployer.processRunner = originalRunner
        }
        // First health check (pre-update decision): stale version. Second
        // health check (post-update confirmation): matches expected.
        let staleJSON = """
            {"status": "ok", "version": "0.0.9", "uptime_seconds": 5}
            """.data(using: .utf8)!
        let freshJSON = """
            {"status": "ok", "version": "\(KVMBridgeDeployer.expectedBridgeVersion)", "uptime_seconds": 1}
            """.data(using: .utf8)!
        stubHealthSessionSequence([staleJSON, freshJSON])

        var deployInvoked = false
        KVMBridgeDeployer.processRunner = { path, _, _, _ in
            if path == KVMBridgeDeployer.rsyncPath || path == "/usr/bin/ssh" {
                deployInvoked = true
            }
            return (ProcessRunner.Result(output: "active", exitCode: 0), false)
        }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let outcome = await KVMBridgeDeployer.performUpdateIfNeeded(target: target, localBridgePath: "/tmp/Bridge")

        XCTAssertTrue(deployInvoked, "a genuine version mismatch must trigger the deploy/update path")
        guard case .updated(let newVersion) = outcome else { return XCTFail("expected .updated, got \(outcome)") }
        XCTAssertEqual(newVersion, KVMBridgeDeployer.expectedBridgeVersion)
    }

    func testPerformUpdateIfNeededReportsFailedRolledBackWhenPostUpdateHealthUnconfirmed() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        let originalRunner = KVMBridgeDeployer.processRunner
        defer {
            KVMBridgeDeployer.healthURLSession = originalSession
            KVMBridgeDeployer.processRunner = originalRunner
        }
        let staleJSON = """
            {"status": "ok", "version": "0.0.9", "uptime_seconds": 5}
            """.data(using: .utf8)!
        var callCount = 0
        KVMBridgeDeployer.healthURLSession = { url in
            callCount += 1
            if callCount == 1 {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                return (staleJSON, response, nil)
            }
            // Post-update health check never comes back healthy — simulates
            // updater.py's rollback-safety leaving the OLD version running,
            // which this method must not mis-report as a plain "updated".
            let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)
            return (nil, response, nil)
        }
        KVMBridgeDeployer.processRunner = { _, _, _, _ in
            (ProcessRunner.Result(output: "active", exitCode: 0), false)
        }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let outcome = await KVMBridgeDeployer.performUpdateIfNeeded(target: target, localBridgePath: "/tmp/Bridge")

        guard case .failedRolledBack = outcome else {
            return XCTFail("expected .failedRolledBack when post-update health check can't confirm, got \(outcome)")
        }
    }

    func testPerformUpdateIfNeededFailsWhenInitialHealthCheckUnreachable() async {
        let originalSession = KVMBridgeDeployer.healthURLSession
        defer { KVMBridgeDeployer.healthURLSession = originalSession }
        struct FakeNetworkError: Error {}
        KVMBridgeDeployer.healthURLSession = { _ in (nil, nil, FakeNetworkError()) }

        let target = KVMBridgeDeployer.Target(host: "pi.local", user: "pilot", trustHostKey: true)
        let outcome = await KVMBridgeDeployer.performUpdateIfNeeded(target: target, localBridgePath: "/tmp/Bridge")

        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - Gated local-SSH-stand-in tests

    /// Real end-to-end round trip against a local/reachable SSH host: fetches
    /// the real host-key fingerprint via `ssh-keyscan`, then runs `verify()`
    /// against the real `ssh` binary (using the production `processRunner`,
    /// not a mock) invoking a harmless remote `systemctl is-active
    /// curtain-bridge` — expected to fail cleanly (non-zero, service does not
    /// exist) rather than crash, proving the real ssh/argv plumbing works
    /// end-to-end. Skipped unless CURTAIN_LOCAL_SSH_TEST=1 is set, since this
    /// development machine's SSH server is disabled (verified 2026-08-15 — see
    /// this file's class-level doc comment for the exact command and result).
    func testGatedLocalSSHRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["CURTAIN_LOCAL_SSH_TEST"] == "1" else {
            throw XCTSkip(
                "Local SSH server not available in this environment (port 22 closed on 127.0.0.1, "
                    + "no sudo to enable Remote Login). Set CURTAIN_LOCAL_SSH_TEST=1 and "
                    + "CURTAIN_LOCAL_SSH_HOST on a machine with SSH enabled to run this test."
            )
        }
        let host = ProcessInfo.processInfo.environment["CURTAIN_LOCAL_SSH_HOST"] ?? "127.0.0.1"
        let user = ProcessInfo.processInfo.environment["CURTAIN_LOCAL_SSH_USER"] ?? NSUserName()

        let fingerprintResult = KVMBridgeDeployer.fetchHostKeyFingerprint(host: host)
        guard case .success(let fingerprint) = fingerprintResult, !fingerprint.isEmpty else {
            return XCTFail("ssh-keyscan against \(host) returned no fingerprint — is sshd running?")
        }

        let target = KVMBridgeDeployer.Target(host: host, user: user, trustHostKey: true)
        let verifyResult = await KVMBridgeDeployer.verify(target: target)
        switch verifyResult {
        case .success(let outcome):
            // curtain-bridge is not installed on the test host, so "inactive"
            // (or an equivalent non-active status) is the expected, successful
            // outcome here — the point is that a real ssh round trip completed.
            XCTAssertFalse(outcome.serviceActive)
        case .failure(let error):
            XCTFail("real ssh round trip against \(host) failed: \(error)")
        }
    }
}
