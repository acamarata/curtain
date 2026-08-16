import Foundation
import CurtainShared

/// Purpose: Deploys, verifies, and updates T-P1-E11-01's `curtain-bridge` Python
///          package on a TinyPilot Pi over real SSH, and relays a Telegram bot
///          token to the Pi's own config file. Runs entirely on the Mac side
///          (invoked by `KVMBridgeSetupWindow`) but never executes any KVM-
///          automation logic itself and never persists the Telegram token
///          anywhere on the Mac — it only ever appears as an in-flight argument
///          passed through to a remote `ssh`/`scp` invocation.
/// Inputs: a `KVMBridgeTarget` (host/user/auth) plus, per-call, the local path to
///         the Bridge/ package (deploy), a token string (sendTelegramToken), or
///         nothing (checkForUpdate). All shell-out happens via the injectable
///         `processRunner` seam (mirrors `CaptureProbe.processRunner`), defaulting
///         to `ProcessRunner.run` against the system's `/usr/bin/ssh` and
///         `/usr/bin/rsync` (the `rsyncPath` constant — macOS ships rsync by
///         default, so no Homebrew/third-party install is required).
/// Outputs: typed `Result<_, KVMBridgeDeployError>` values carrying captured
///          stdout/stderr and exit codes on failure — nothing is ever silently
///          swallowed. `deploy()` chains rsync (package transfer), a remote
///          `pip install .` + systemd-unit install + `systemctl enable --now`,
///          then a `systemctl is-active` verification read-back over the same
///          logical session (each a discrete SSH invocation; Process gives no
///          persistent multiplexed session without ControlMaster, which this
///          type does not set up, so each step is its own `ssh` call — acceptable
///          here since deploy is a rare, user-initiated, foreground operation,
///          not a hot path).
/// Constraints: host-key verification is never silently disabled. First contact
///              with a host uses `fetchHostKeyFingerprint(host:)` (shells out to
///              `ssh-keyscan`) so the wizard can show the fingerprint and get an
///              explicit user confirmation BEFORE any deploy/verify call; only
///              once the caller has that confirmation does it pass
///              `trustHostKey: true`, which this type turns into
///              `-o StrictHostKeyChecking=accept-new` (accept an unseen key,
///              but still fail loudly on a CHANGED key — never
///              `StrictHostKeyChecking=no`, which would also silently accept a
///              key that changed after a prior trusted connection, the exact
///              MITM case host-key checking exists to catch). No third-party SSH
///              library — `ssh`/`scp`/`rsync` are invoked as subprocesses via
///              `ProcessRunner`, matching this package's zero-external-dependency
///              posture (Package.swift has no dependencies). The Telegram token
///              is written to the Pi via a `printf '%s' <token> | ssh ... 'cat >
///              path'` shape (stdin-piped, never interpolated into a shell string
///              or passed as a `ps`-visible argv element) — see `sendTelegramToken`.
///
///              T-P1-E11-03 health-check-based verification (`checkHealth`):
///              queries the Bridge's `/health` endpoint (see
///              `Bridge/curtain_bridge/health.py`) as a real, structured
///              alternative to `verify()`'s `systemctl is-active` string
///              parsing — `/health` reports the actually-running package
///              version (useful for `compareVersions`) and confirms the
///              service is not just "systemd thinks it's active" but genuinely
///              answering HTTP requests. DECISION: `checkHealth` makes a
///              DIRECT LAN call (`http://<host>:8642/health` via `URLSession`)
///              rather than tunneling through SSH, even though every other
///              call in this type goes over SSH. Reasoning: this Bridge exists
///              specifically to remain reachable when things are stressed (the
///              epic's framing — "the one thing that still works when the Mac
///              can't help"); a direct HTTP call has fewer moving parts than
///              standing up an SSH port-forward (`ssh -L`) just to make one
///              GET request, and avoids spending an entire SSH round-trip
///              (auth, session setup, teardown) for what is meant to be a
///              cheap, frequent reachability probe (E-14's future
///              `curtain_kvm_*` tools will call this often). The documented
///              fallback for networks where the health port isn't reachable
///              directly (e.g. Pi on an isolated VLAN, only SSH-reachable) is
///              an SSH-tunneled call — NOT implemented in this ticket (out of
///              scope per the guide's "documented fallback" framing, not
///              "must implement both paths now") — a caller blocked by this
///              can fall back to `verify()`'s `systemctl is-active` check in
///              the interim, since that still works over the existing SSH
///              path unconditionally.
/// SPORT: MASTER-APPS (Curtain.app KVM Bridge setup wizard, code-complete-hardware-unverified)
public enum KVMBridgeDeployer {

    // MARK: - Types

    /// Connection target for a TinyPilot Pi. `keyPath` is preferred; when nil,
    /// `ssh`/`scp`/`rsync` fall back to whatever identity the invoking user's
    /// own `~/.ssh/config` or agent already offers (password auth over
    /// `Process`-invoked ssh has no clean non-interactive path without a
    /// third-party library, so this type does not attempt to pass a password —
    /// the wizard's guide text tells the user to set up key auth or rely on an
    /// ssh-agent).
    public struct Target {
        public let host: String
        public let user: String
        public let keyPath: String?
        /// Must be true before any of this type's methods run — set only after
        /// the wizard has shown `fetchHostKeyFingerprint(host:)`'s result and the
        /// user has explicitly confirmed it in-app. See the type's doc comment.
        public let trustHostKey: Bool

        public init(host: String, user: String, keyPath: String? = nil, trustHostKey: Bool) {
            self.host = host
            self.user = user
            self.keyPath = keyPath
            self.trustHostKey = trustHostKey
        }
    }

    /// Everything that can go wrong, each carrying the captured evidence rather
    /// than a bare message — callers (and tests) can inspect exit codes/stderr
    /// directly instead of string-matching a description.
    public enum DeployError: Error, Equatable {
        case hostKeyNotTrusted
        case sshLaunchFailed(step: String)
        case sshFailed(step: String, exitCode: Int32, stderr: String)
        case versionParseFailed(raw: String)
    }

    /// Result of a successful deploy: whether the systemd unit reported active,
    /// and the raw `systemctl is-active` output for display/debugging.
    public struct DeployOutcome: Equatable {
        public let serviceActive: Bool
        public let statusOutput: String
    }

    /// Typed parse of `Bridge/curtain_bridge/health.py`'s `/health` JSON
    /// response shape — `{"status": "ok", "version": "...", "uptime_seconds": N}`.
    public struct HealthStatus: Equatable, Decodable {
        public let status: String
        public let version: String
        public let uptimeSeconds: Int

        enum CodingKeys: String, CodingKey {
            case status
            case version
            case uptimeSeconds = "uptime_seconds"
        }

        public init(status: String, version: String, uptimeSeconds: Int) {
            self.status = status
            self.version = version
            self.uptimeSeconds = uptimeSeconds
        }

        /// Convenience the UI can check without string-comparing `status`
        /// itself — matches `health.py`'s only currently-documented value.
        public var isHealthy: Bool { status == "ok" }
    }

    /// Everything that can go wrong specifically in `checkHealth` — kept
    /// distinct from `DeployError` since these are HTTP/JSON failures, not
    /// SSH ones, and callers (the UI) want to word them differently.
    public enum HealthCheckError: Error, Equatable {
        case invalidURL
        case requestFailed(description: String)
        case unexpectedStatusCode(Int)
        case decodingFailed(description: String)
    }

    /// Outcome of an update attempt driven through `performUpdateIfNeeded`,
    /// surfacing the specific rollback case distinctly from a generic
    /// failure so the UI never shows a bare "error" for "it failed safely
    /// and your Pi is fine."
    public enum UpdateOutcome: Equatable {
        case upToDate(version: String)
        case updated(newVersion: String)
        case failedRolledBack(message: String)
        case failed(message: String)
    }

    // MARK: - Injection seam (tests swap this; production never does)

    /// Mirrors `CaptureProbe.processRunner`: the one shell-out point, so tests
    /// can assert exact argv and feed canned output without a real network call.
    /// `timeout` is generous (30s) — deploy steps (pip install, rsync) can
    /// legitimately take longer than CaptureProbe's 5s probe budget.
    static var processRunner:
        (String, [String], TimeInterval, ((Error) -> Void)?) -> (result: ProcessRunner.Result, timedOut: Bool) = {
            path, args, timeout, onLaunchFailure in
            ProcessRunner.run(path, args, timeout: timeout, onLaunchFailure: onLaunchFailure)
        }

    /// Separate seam for the stdin-piping shape (`sendTelegramToken`), matching
    /// `ProcessRunner`'s `run(_:_:stdin:onLaunchFailure:)` overload.
    static var processRunnerStdin: (String, [String], Data, ((Error) -> Void)?) -> ProcessRunner.Result = {
        path, args, stdin, onLaunchFailure in
        ProcessRunner.run(path, args, stdin: stdin, onLaunchFailure: onLaunchFailure)
    }

    /// Network seam for `checkHealth` — mirrors the `processRunner` pattern
    /// so tests can feed canned HTTP responses (via a local stand-in server,
    /// per this ticket's guide, or an in-process stub) without any change to
    /// production code. Production installs the real `URLSession.shared`
    /// data-task call; tests swap this static var directly.
    static var healthURLSession: (URL) async -> (data: Data?, response: URLResponse?, error: Error?) = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = healthCheckTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response, nil)
        } catch {
            return (nil, nil, error)
        }
    }

    static let deployTimeout: TimeInterval = 60.0
    static let quickTimeout: TimeInterval = 15.0
    static let healthCheckTimeout: TimeInterval = 5.0

    /// Curtain.app's bundled expected Bridge version. Bumped alongside Bridge/'s
    /// own `pyproject.toml` `version` field whenever the two need to move
    /// together (this ticket does not add release-automation to keep them in
    /// lock-step beyond this constant — see the ticket's out_of_scope).
    public static let expectedBridgeVersion = "0.1.0"

    /// Matches `Bridge/curtain_bridge/health.py`'s `DEFAULT_HEALTH_PORT` —
    /// deliberately distinct from TinyPilot's own port (documented in both
    /// `Bridge/README.md`'s "Health endpoint" section and this file's
    /// class-level doc comment).
    public static let healthPort = 8642

    // MARK: - Host key verification (Step 7 of the guide)

    /// Shells out to `ssh-keyscan` to fetch the host's public key fingerprint
    /// WITHOUT connecting as a client and without touching `known_hosts`. The
    /// wizard shows this raw text to the user for explicit confirmation before
    /// any `trustHostKey: true` Target is constructed.
    public static func fetchHostKeyFingerprint(host: String) -> Result<String, DeployError> {
        let (outcome, timedOut) = processRunner("/usr/bin/ssh-keyscan", [host], quickTimeout, nil)
        if timedOut {
            return .failure(.sshFailed(step: "ssh-keyscan", exitCode: -1, stderr: "timed out"))
        }
        guard outcome.succeeded, !outcome.output.isEmpty else {
            return .failure(.sshFailed(step: "ssh-keyscan", exitCode: outcome.exitCode, stderr: outcome.output))
        }
        return .success(outcome.output)
    }

    // MARK: - Deploy (Steps 3, 6, 7 of the guide)

    /// rsync's the local Bridge/ package to the Pi, installs it with `pip
    /// install .` into a venv, installs the systemd unit, enables+starts it,
    /// then verifies via `systemctl is-active`. Every step's exit code and
    /// stderr are captured; the first failing step aborts the chain and returns
    /// it — later steps never run against a Pi in an unknown intermediate state.
    public static func deploy(target: Target, localBridgePath: String) async -> Result<DeployOutcome, DeployError> {
        guard target.trustHostKey else { return .failure(.hostKeyNotTrusted) }

        let dest = "\(target.user)@\(target.host):/opt/curtain-bridge"

        // 1. Transfer the package. `-e "ssh <opts>"` routes rsync's transport
        // through ssh with the same StrictHostKeyChecking/ConnectTimeout/-i
        // options used everywhere else in this type, rather than rsync's own
        // (unrelated) flags — rsync does not accept `-o`/`-i` directly.
        var args = [
            "-a", "--delete", "-e", "ssh \(sshOptionArgs(target: target).joined(separator: " "))",
            "\(localBridgePath)/", dest
        ]
        var (outcome, timedOut) = processRunner(rsyncPath, args, deployTimeout, nil)
        if timedOut { return .failure(.sshFailed(step: "rsync", exitCode: -1, stderr: "timed out")) }
        guard outcome.succeeded else {
            return .failure(.sshFailed(step: "rsync", exitCode: outcome.exitCode, stderr: outcome.output))
        }

        // 2. Remote install: venv + pip install + systemd unit + enable --now.
        // Single remote shell command so it runs as one ssh invocation rather
        // than four round-trips; each `&&`-chained sub-step still surfaces its
        // own failure via the shell's own exit code, captured below.
        let installScript = """
            set -e
            cd /opt/curtain-bridge
            python3 -m venv venv
            ./venv/bin/pip install --quiet .
            sudo install -m 644 Bridge/systemd/curtain-bridge.service /etc/systemd/system/curtain-bridge.service 2>/dev/null \
                || sudo install -m 644 systemd/curtain-bridge.service /etc/systemd/system/curtain-bridge.service
            sudo systemctl daemon-reload
            sudo systemctl enable --now curtain-bridge
            """
        args = sshOptionArgs(target: target) + ["\(target.user)@\(target.host)", installScript]
        (outcome, timedOut) = processRunner("/usr/bin/ssh", args, deployTimeout, nil)
        if timedOut { return .failure(.sshFailed(step: "remote-install", exitCode: -1, stderr: "timed out")) }
        guard outcome.succeeded else {
            return .failure(.sshFailed(step: "remote-install", exitCode: outcome.exitCode, stderr: outcome.output))
        }

        // 3. Verify.
        return await verify(target: target)
    }

    /// Re-checks `systemctl is-active curtain-bridge` on an already-deployed Pi,
    /// independent of `deploy()` — used both as deploy's last step and standalone
    /// by the wizard's "re-check status" affordance.
    public static func verify(target: Target) async -> Result<DeployOutcome, DeployError> {
        guard target.trustHostKey else { return .failure(.hostKeyNotTrusted) }
        let args =
            sshOptionArgs(target: target) + ["\(target.user)@\(target.host)", "systemctl is-active curtain-bridge"]
        let (outcome, timedOut) = processRunner("/usr/bin/ssh", args, quickTimeout, nil)
        if timedOut { return .failure(.sshFailed(step: "systemctl-is-active", exitCode: -1, stderr: "timed out")) }
        // `systemctl is-active` exits non-zero for any state other than "active"
        // (e.g. "inactive", "failed") — that is informative output, not a launch
        // failure, so a non-zero exit here still produces a DeployOutcome rather
        // than a DeployError; only an actual ssh-launch/connection failure does.
        let trimmed = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(DeployOutcome(serviceActive: trimmed == "active", statusOutput: trimmed))
    }

    // MARK: - Health check (T-P1-E11-03, Step 5 of that ticket's guide)

    /// GETs `http://<host>:healthPort/health` directly over the LAN (see this
    /// type's class-level doc comment for the direct-vs-tunneled decision)
    /// and parses the JSON body into a typed `HealthStatus`. Unlike `verify`,
    /// this does not require `target.trustHostKey` — it is a plain HTTP call
    /// with no SSH/host-key involvement, and is meant to be cheap enough to
    /// call frequently (e.g. by E-14's future `curtain_kvm_*` tools) without
    /// requiring the user to have gone through the SSH trust flow at all.
    public static func checkHealth(host: String) async -> Result<HealthStatus, HealthCheckError> {
        guard let url = URL(string: "http://\(host):\(healthPort)/health") else {
            return .failure(.invalidURL)
        }
        let (data, response, error) = await healthURLSession(url)
        if let error {
            return .failure(.requestFailed(description: "\(error)"))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.requestFailed(description: "no HTTP response"))
        }
        guard httpResponse.statusCode == 200, let data else {
            return .failure(.unexpectedStatusCode(httpResponse.statusCode))
        }
        do {
            let status = try JSONDecoder().decode(HealthStatus.self, from: data)
            return .success(status)
        } catch {
            return .failure(.decodingFailed(description: "\(error)"))
        }
    }

    /// Semantic-version comparison of `local` vs `remote` (both expected in
    /// `MAJOR.MINOR.PATCH` form, matching `expectedBridgeVersion` and
    /// `health.py`'s reported `version` field). Returns `true` only when
    /// `remote` is a DIFFERENT version than `local` — this drives
    /// `performUpdateIfNeeded`'s "only on genuine mismatch" gate per the
    /// ticket's Step 6, deliberately not attempting an older/newer directional
    /// judgment (a remote version *older* than expected is just as much a
    /// "needs update" case as a newer one would be unexpected — either way,
    /// the Pi is not running what Curtain.app expects it to run).
    ///
    /// Unparseable version strings (missing components, non-numeric parts)
    /// are treated conservatively as "needs update" — an unparseable remote
    /// version is itself a strong signal something is wrong that a redeploy
    /// may fix, and silently treating "I can't tell" as "no update needed"
    /// would be the more dangerous failure mode for a Pi meant to work
    /// reliably while unattended for months.
    public static func compareVersions(local: String, remote: String) -> Bool {
        guard let localParts = parsedSemVer(local), let remoteParts = parsedSemVer(remote) else {
            return true
        }
        return localParts != remoteParts
    }

    private static func parsedSemVer(_ raw: String) -> [Int]? {
        let components = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard components.count == 3 else { return nil }
        let parsed = components.compactMap { Int($0) }
        guard parsed.count == 3 else { return nil }
        return parsed
    }

    // MARK: - Update decision flow (T-P1-E11-03, Step 6 of that ticket's guide)

    /// Orchestrates the full update decision: check the Pi's live health/
    /// version, compare against what's expected, and only trigger
    /// `updater.py`'s `apply_update` (via SSH, reusing T-P1-E11-02's deploy
    /// path — `deploy()` is upgrade-safe/idempotent, matching `update()`'s
    /// existing doc comment) on a genuine mismatch. Surfaces the specific
    /// rolled-back-safely case distinctly (`UpdateOutcome.failedRolledBack`)
    /// so the UI never shows a bare, unqualified error for the case where the
    /// Pi's prior version is confirmed still running.
    ///
    /// This method does not itself implement the staged-install swap logic —
    /// that lives entirely in `Bridge/curtain_bridge/updater.py`, run on the
    /// Pi. This method's job is the DECISION (compare versions, decide
    /// whether to trigger a redeploy at all) plus relaying `deploy()`'s
    /// result into the UI-facing `UpdateOutcome` shape.
    public static func performUpdateIfNeeded(
        target: Target, localBridgePath: String
    ) async -> UpdateOutcome {
        let healthResult = await checkHealth(host: target.host)
        guard case .success(let health) = healthResult else {
            if case .failure(let error) = healthResult {
                return .failed(message: "could not reach Bridge health endpoint: \(error)")
            }
            return .failed(message: "could not reach Bridge health endpoint")
        }

        guard compareVersions(local: expectedBridgeVersion, remote: health.version) else {
            return .upToDate(version: health.version)
        }

        let updateResult = await update(target: target, localBridgePath: localBridgePath)
        switch updateResult {
        case .success:
            // deploy()/update() already re-verifies via systemctl is-active
            // as its own last step; re-confirm via the richer health check
            // here so the reported version reflects reality, not an assumed
            // value.
            let postUpdateHealth = await checkHealth(host: target.host)
            if case .success(let confirmed) = postUpdateHealth, confirmed.isHealthy {
                return .updated(newVersion: confirmed.version)
            }
            return .failedRolledBack(
                message:
                    "deploy reported success but the post-update health check did not confirm it; "
                    + "updater.py's own rollback-safety guarantees the Pi is not left broken — re-run "
                    + "the setup wizard's health check to confirm current state"
            )
        case .failure(let error):
            return .failed(message: "update deploy failed: \(error)")
        }
    }

    // MARK: - Telegram token relay (never touches Mac-side storage)

    /// Writes `token` to the Bridge's config file location on the Pi over the
    /// same SSH channel used for deploy. The token is piped via stdin to a
    /// remote `cat > path` — never interpolated into a shell command string
    /// (which `ps aux` on the Pi, or shell history, could otherwise leak) and
    /// never written, cached, logged, or stored in any Keychain entry,
    /// UserDefaults key, or file on the Mac. This function's only side effect
    /// on the Mac is the outbound SSH process invocation itself; `token` lives
    /// only in this call's stack frame and the child process's stdin pipe.
    public static func sendTelegramToken(target: Target, token: String) -> Result<Void, DeployError> {
        guard target.trustHostKey else { return .failure(.hostKeyNotTrusted) }
        guard let tokenData = token.data(using: .utf8) else {
            return .failure(.sshFailed(step: "encode-token", exitCode: -1, stderr: "non-UTF8 token"))
        }
        let remoteCommand = "cat > /etc/curtain-bridge/telegram-token"
        let args = sshOptionArgs(target: target) + ["\(target.user)@\(target.host)", remoteCommand]
        let outcome = processRunnerStdin("/usr/bin/ssh", args, tokenData, nil)
        guard outcome.succeeded else {
            return .failure(.sshFailed(step: "send-telegram-token", exitCode: outcome.exitCode, stderr: outcome.output))
        }
        return .success(())
    }

    // MARK: - Update story (Step 5 of the guide)

    /// Queries the remote Bridge's reported version via `curtain-bridge
    /// --version` and compares it against `expectedBridgeVersion`. Returns the
    /// remote version string and whether it differs from what Curtain.app
    /// expects — the caller (wizard) decides whether to re-run `deploy()`.
    public static func checkForUpdate(target: Target) async -> Result<
        (remoteVersion: String, needsUpdate: Bool), DeployError
    > {
        guard target.trustHostKey else { return .failure(.hostKeyNotTrusted) }
        let args =
            sshOptionArgs(target: target)
            + ["\(target.user)@\(target.host)", "/opt/curtain-bridge/venv/bin/curtain-bridge --version"]
        let (outcome, timedOut) = processRunner("/usr/bin/ssh", args, quickTimeout, nil)
        if timedOut { return .failure(.sshFailed(step: "check-version", exitCode: -1, stderr: "timed out")) }
        guard outcome.succeeded else {
            return .failure(.sshFailed(step: "check-version", exitCode: outcome.exitCode, stderr: outcome.output))
        }
        let remoteVersion = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteVersion.isEmpty else {
            return .failure(.versionParseFailed(raw: outcome.output))
        }
        return .success((remoteVersion: remoteVersion, needsUpdate: remoteVersion != expectedBridgeVersion))
    }

    /// Re-runs `deploy()` unconditionally — the caller is expected to have
    /// already consulted `checkForUpdate` and decided an update is warranted.
    /// `deploy()`'s remote install script (`pip install .` into the existing
    /// venv, `systemctl enable --now`) is naturally idempotent/upgrade-safe
    /// against an already-deployed Pi, so no separate "update" code path exists.
    public static func update(target: Target, localBridgePath: String) async -> Result<DeployOutcome, DeployError> {
        await deploy(target: target, localBridgePath: localBridgePath)
    }

    // MARK: - Shared ssh option assembly

    /// `-o StrictHostKeyChecking=accept-new`: accepts a host key never seen
    /// before (expected on first deploy to a fresh Pi) but still HARD FAILS if
    /// a previously-trusted key changes — never `=no`, which would silently
    /// accept a changed key too and defeat the point of host-key checking.
    /// Only reached once `target.trustHostKey` is true, i.e. only after the
    /// wizard has shown the user `fetchHostKeyFingerprint`'s output and they
    /// confirmed it (see this type's doc comment and KVMBridgeSetupWindow).
    private static func sshOptionArgs(target: Target) -> [String] {
        var args = ["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
        if let keyPath = target.keyPath, !keyPath.isEmpty {
            args += ["-i", keyPath]
        }
        return args
    }

    /// `/usr/bin/rsync` ships with macOS by default (BSD's openrsync,
    /// protocol-compatible with the archive-mode flags used here) — no
    /// Homebrew or other third-party install required, matching the guide's
    /// "check which is present on macOS by default" instruction.
    static let rsyncPath = "/usr/bin/rsync"
}
