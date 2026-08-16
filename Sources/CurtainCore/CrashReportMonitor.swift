import Foundation

/// Purpose: T-P1-E12-04 — retroactive crash-cause reporting on the Mac. On
///          every app launch, scans `/Library/Logs/DiagnosticReports/` for
///          crash/panic reports newer than the last check, and — ONLY when
///          this launch also looks like a post-unexpected-reboot recovery
///          launch (see `isRecoveryLaunch`) — relays a short human-readable
///          summary to the Bridge, which forwards it to the user's Telegram
///          chat once the Mac is back online.
///
///          HARD SECURITY BOUNDARY (non-negotiable, inherited from this
///          epic's other three tickets): this is retroactive reporting AFTER
///          the Mac has already been unlocked via E-12's human-confirmed
///          Telegram-recovery flow. Nothing here unlocks anything, caches a
///          credential, or skips a human confirmation step.
///
/// ARCHITECTURAL DECISION — relay through the Bridge, not a direct Mac-side
///          Telegram call (this ticket's guide leaned toward direct-send;
///          the actual constraint below overrides that lean):
///          `KVMBridgeDeployer.sendTelegramToken` (T-P1-E11-02) establishes a
///          HARD boundary that the Telegram bot token is NEVER persisted
///          anywhere on the Mac — it is piped via SSH stdin straight to the
///          Pi's `/etc/curtain-bridge/telegram-token` and exists on the Mac
///          only as a transient in-memory value during the setup wizard's
///          one-time send. A direct Mac-side `sendMessage` call would need a
///          durable copy of that same token available on every future
///          ordinary app launch (Settings/Keychain), which is exactly the
///          "credential lives on the protected Mac" risk E-11-02 was written
///          to avoid — this Mac holds VA/legal/financial records, and E-12's
///          own framing epic-wide is that no standing credential exists
///          anywhere for exactly this reason. Duplicating a small
///          `sendMessage` call is cheap in isolation, but paying for it with
///          a second Telegram credential store on the protected machine is
///          not a good trade. The Bridge already owns the bot token (T-P1-
///          E12-02's `telegram_client.py`) and the pinned chat_id
///          (`TelegramLoginModule._chat_id`), and is reachable from the Mac
///          over the same direct-LAN-HTTP path `KVMBridgeDeployer.checkHealth`
///          already uses (T-P1-E11-03) — relaying through it needs zero new
///          credentials anywhere and reuses an existing, already-verified
///          network path. See `Bridge/curtain_bridge/crash_relay.py` for the
///          Bridge-side half of this decision.
///
/// Inputs: none directly — reads `/Library/Logs/DiagnosticReports/` (best-
///         effort; this directory is not always fully readable without
///         elevated privileges, handled as "found nothing new" rather than a
///         crash), `Settings.crashMonitorLastCheckedTimestamp`, E-10's
///         heartbeat file (`~/Library/Application Support/Curtain/heartbeat.json`,
///         same path/format `SessionMonitor.writeHeartbeatFile` writes), and
///         `sysctl kern.boottime`.
/// Outputs: on a positive recovery-launch detection with at least one new
///          report, POSTs a JSON summary to the Bridge's `/crash-report`
///          relay (see `sendSummary`, injectable for tests) and updates the
///          persisted last-checked marker. No-ops (but still updates the
///          marker) on an ordinary restart or when no new reports exist.
/// Constraints: `check()` must never throw or crash the launch sequence —
///          every filesystem/JSON/sysctl operation is best-effort and falls
///          through to "nothing to report" on any failure. Runs on a
///          background queue (AppDelegate fires it fire-and-forget) since
///          directory listing + `.ips` parsing is disk I/O that must never
///          block `applicationDidFinishLaunching`.
/// SPORT: MASTER-APPS (Curtain.app, T-P1-E12-04)
public enum CrashReportMonitor {

    // MARK: - Injection seams (tests swap these; production never does)

    /// Directory to scan. `internal` (not `public`) — only this file and its
    /// test target need it; mirrors `KVMBridgeDeployer.processRunner`'s
    /// static-var-seam pattern used throughout this codebase for testability
    /// without a network/filesystem dependency-injection framework.
    static var diagnosticReportsDirectory = "/Library/Logs/DiagnosticReports"

    /// Reads the heartbeat file SessionMonitor writes (T-P1-E10-01). Returns
    /// the parsed `timestamp` field, or nil if absent/unreadable/malformed —
    /// callers treat nil as "no heartbeat evidence, do not guess."
    static var readLastHeartbeatTimestamp: () -> Date? = {
        guard
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Curtain", isDirectory: true)
        else { return nil }
        let fileURL = dir.appendingPathComponent("heartbeat.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let timestampString = object["timestamp"] as? String
        else { return nil }
        return isoFormatter.date(from: timestampString)
    }

    /// `sysctl kern.boottime` via the C syscall API (matches this codebase's
    /// existing direct-syscall style, e.g. `CurtainHelper/main.swift`'s
    /// `sysctl(KERN_PROC_ALL)` for process enumeration) rather than shelling
    /// out to the `sysctl` command-line tool.
    static var readBootTime: () -> Date? = {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        let result = sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0)
        guard result == 0, bootTime.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
    }

    /// Sends the built summary to the Bridge's crash-report relay endpoint
    /// (`Bridge/curtain_bridge/crash_relay.py`, POST /crash-report). Default
    /// production implementation does a direct LAN HTTP call, matching
    /// `KVMBridgeDeployer.checkHealth`'s existing direct-HTTP pattern (no
    /// SSH, no host-key dependency — this is a cheap best-effort notify, not
    /// a privileged operation). Host/port are read from Settings-adjacent
    /// KVM Bridge configuration if a target has ever been configured; if
    /// none has, there is nowhere to send, and the call is a no-op success
    /// (nothing to relay through).
    static var sendSummary: (String, String) async -> Bool = { host, summary in
        guard let url = URL(string: "http://\(host):\(crashRelayPort)/crash-report") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        guard let body = try? JSONSerialization.data(withJSONObject: ["summary": summary]) else { return false }
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    /// Matches `Bridge/curtain_bridge/crash_relay.py`'s `DEFAULT_CRASH_RELAY_PORT` —
    /// a third port distinct from TinyPilot's 80 and `KVMBridgeDeployer.healthPort` (8642).
    static let crashRelayPort = 8643

    // MARK: - Recovery-launch threshold (see doc comment on `isRecoveryLaunch`)

    /// SessionMonitor's heartbeat writes roughly every 2s while the app is
    /// alive (`SessionMonitor.pollInterval`). A GRACEFUL shutdown/restart the
    /// user does themselves (Apple menu > Restart, `sudo reboot`, a manual
    /// relaunch) stops the heartbeat writer immediately, then the OS spends
    /// real wall-clock time tearing down and booting back up — commonly
    /// 20-90s on modern Apple Silicon, but can run longer with FileVault
    /// unlock delay, pending updates, or slow login. The one thing that
    /// distinguishes an ordinary restart from the crash-reboot-Telegram-
    /// recovery cycle this ticket cares about is NOT the boot duration
    /// itself (both can take a similar amount of wall-clock time) — it's
    /// that in the crash case, the heartbeat file's last write is stale
    /// relative to when this launch is happening NOW, by more than a normal
    /// single-reboot-cycle's worth of time, because a genuine crash-then-
    /// human-recovery round trip includes the time for a human to notice
    /// (via the KVM Bridge's video detection, T-P1-E12-01) and reply to the
    /// Telegram prompt (T-P1-E12-02) — a process that takes at minimum tens
    /// of seconds to minutes, not the near-instant few seconds between "last
    /// heartbeat tick" and "boot begins" that a user-initiated restart while
    /// physically present produces (they see the "Restart" click and the
    /// reboot begins within the same few seconds, so heartbeat-gap-to-
    /// boot-time stays small). This method compares last-heartbeat to
    /// BOOT TIME (not to launch time) specifically to isolate the
    /// pre-reboot gap from ordinary app-startup/login duration, which is
    /// itself irrelevant to whether the ORIGINAL exit was expected.
    ///
    /// THRESHOLD CHOSEN: 5 minutes (300s). Reasoning: SessionMonitor's 2s
    /// poll interval means an ordinary graceful restart (Apple menu, or the
    /// user closing the lid / choosing Restart while at the desk) leaves a
    /// gap between "last heartbeat write" and "boot time" of at most a few
    /// seconds to low tens of seconds — the OS shutdown sequence itself
    /// (quitting apps, unmounting volumes) rarely exceeds a minute, and the
    /// heartbeat keeps ticking right up until the process is actually
    /// killed during that sequence. 5 minutes gives generous headroom above
    /// that (covers a slow shutdown with many apps quitting, or a delayed
    /// "install update and restart") while still being tight enough that it
    /// will NOT fire on a normal restart and spam the user's Telegram. A
    /// genuine unattended crash (kernel panic, power loss) leaves a gap that
    /// is unbounded — the Mac sits crashed/off until AppSupervisor's launchd
    /// KeepAlive relaunches Curtain.app post-boot, or until someone
    /// physically power-cycles it — so realistically this either reads as a
    /// clearly-small gap (ordinary restart) or a clearly-large one (crash,
    /// often minutes to hours), with little ambiguous middle ground; 5
    /// minutes sits safely on the "definitely not an ordinary graceful
    /// restart" side without being so large that a genuine crash's summary
    /// arrives inconveniently late.
    static let recoveryLaunchThresholdSeconds: TimeInterval = 5 * 60

    /// True when the gap between the last heartbeat and the current boot
    /// time exceeds `recoveryLaunchThresholdSeconds` — see the extended
    /// reasoning above. Returns `false` (never a false positive) whenever
    /// either timestamp is unavailable, since there is no evidence to act on.
    static func isRecoveryLaunch(lastHeartbeat: Date?, bootTime: Date?) -> Bool {
        guard let lastHeartbeat, let bootTime else { return false }
        let gap = bootTime.timeIntervalSince(lastHeartbeat)
        // A negative gap (heartbeat written AFTER boot, e.g. clock skew, or
        // heartbeat somehow post-dating boot on a fresh install) is not
        // evidence of an unexpected reboot either — only a genuinely large
        // POSITIVE gap counts.
        return gap > recoveryLaunchThresholdSeconds
    }

    // MARK: - Report scanning

    /// One parsed crash/panic report's human-readable summary line. `.ips`
    /// reports on modern macOS (confirmed by inspecting a real
    /// `JetsamEvent-*.ips` file on this development machine, since a full
    /// application-crash `.ips` was not available to read directly in this
    /// environment) are two NDJSON lines: a compact "header" object
    /// (`bug_type`, `timestamp`, `os_version`, `incident_id`) followed by a
    /// larger "payload" object whose exact keys vary by `bug_type`, but
    /// commonly include `procName`/`process`, `exception`, and `termination`
    /// for actual process-crash reports (bug_type "309") — parsed
    /// defensively below since the payload shape is not guaranteed identical
    /// across bug_type values or OS versions.
    struct ParsedReport {
        let fileName: String
        let summary: String
    }

    /// Lists files in `diagnosticReportsDirectory` modified after `since`
    /// (or all `.ips` files if `since` is nil — first-ever check), parses
    /// each as an `.ips` report, and builds a short summary. Best-effort:
    /// unreadable files, non-JSON files, and permission failures are skipped
    /// individually rather than aborting the whole scan — this directory
    /// commonly contains files this process cannot read (other users' crash
    /// reports, root-owned diagnostic files), and that is expected, not an
    /// error condition.
    static func scanForNewReports(since: Date?) -> [ParsedReport] {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: diagnosticReportsDirectory),
                includingPropertiesForKeys: [.contentModificationDateKey])
        else {
            return []
        }

        var reports: [ParsedReport] = []
        for fileURL in entries where fileURL.pathExtension == "ips" {
            guard
                let attributes = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                let modified = attributes.contentModificationDate
            else { continue }
            if let since, modified <= since { continue }
            guard let parsed = parseReport(at: fileURL) else { continue }
            reports.append(parsed)
        }
        return reports
    }

    /// Parses a single `.ips` file's two-line NDJSON shape into a short
    /// human-readable summary. Returns nil (skips the file) on any read/
    /// parse failure rather than throwing — a single malformed report must
    /// never block the rest of the scan.
    static func parseReport(at url: URL) -> ParsedReport? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        guard let headerLine = lines.first,
            let headerData = headerLine.data(using: .utf8),
            let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else {
            return nil
        }

        var payload: [String: Any] = [:]
        if lines.count > 1, let payloadData = lines[1].data(using: .utf8),
            let parsedPayload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        {
            payload = parsedPayload
        }

        let processName =
            (payload["procName"] as? String) ?? (payload["process"] as? String) ?? "unknown process"
        let bugType = (header["bug_type"] as? String) ?? "unknown"
        let timestamp = (header["timestamp"] as? String) ?? (payload["date"] as? String) ?? "unknown time"
        let terminationReason = summarizeTermination(payload: payload)

        let summary = "\(processName) (bug_type \(bugType))\(terminationReason) at \(timestamp)"
        return ParsedReport(fileName: url.lastPathComponent, summary: summary)
    }

    /// Extracts a short termination/exception description from the payload's
    /// `termination`/`exception` objects when present — both are
    /// dictionaries in the real `.ips` schema, so this reads defensively
    /// rather than assuming either key exists or has the expected shape.
    private static func summarizeTermination(payload: [String: Any]) -> String {
        if let termination = payload["termination"] as? [String: Any],
            let reasonText = termination["indicator"] as? String
        {
            return " — \(reasonText)"
        }
        if let exception = payload["exception"] as? [String: Any], let type = exception["type"] as? String {
            return " — \(type)"
        }
        return ""
    }

    // MARK: - Orchestration (called from AppDelegate's launch sequence)

    /// Runs the full check: scan for new reports, evaluate recovery-launch
    /// detection, and — only when BOTH are positive — build a combined
    /// summary and relay it. Always updates the persisted marker at the end
    /// (idempotent: safe to call on every launch, never double-sends for
    /// reports already accounted for). Runs entirely off the main thread —
    /// callers should fire this from a background `Task`.
    public static func check() async {
        let lastChecked = Settings.crashMonitorLastCheckedTimestamp.flatMap { isoFormatter.date(from: $0) }
        let newReports = scanForNewReports(since: lastChecked)

        // Marker is "now" rounded UP to the next whole second (`.rounded(.up)`
        // on the Unix-epoch interval), not a plain `Date()`. `isoFormatter`'s
        // ISO 8601 string is second-resolution (fractional seconds are
        // dropped), so persisting a plain `Date()` truncates DOWN on the next
        // decode — a file whose mtime falls in the sub-second window between
        // the truncated marker and the real capture instant would then read
        // as `mtime > since` on the very next call and be treated as "new"
        // again, re-triggering a send for a report already accounted for.
        // Rounding up guarantees the persisted (then re-parsed) marker is
        // always >= every file this call actually observed, closing that gap.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up))

        // Always advance the marker before any early return below — this
        // scan just examined everything newer than the previous marker, so
        // nothing found now should be re-examined on the next launch even if
        // this launch turns out not to be a recovery launch.
        defer { Settings.crashMonitorLastCheckedTimestamp = isoFormatter.string(from: now) }

        guard !newReports.isEmpty else {
            Log.event("CrashReportMonitor: no new reports since last check")
            return
        }

        let lastHeartbeat = readLastHeartbeatTimestamp()
        let bootTime = readBootTime()
        guard isRecoveryLaunch(lastHeartbeat: lastHeartbeat, bootTime: bootTime) else {
            Log.event(
                "CrashReportMonitor: \(newReports.count) new report(s) found but this does not look like a "
                    + "recovery launch (ordinary restart) — not sending")
            return
        }

        guard let bridgeHost = Settings.kvmBridgeHost, !bridgeHost.isEmpty else {
            Log.event(
                "CrashReportMonitor: recovery launch detected but no KVM Bridge host is configured — cannot relay")
            return
        }

        let summary = newReports.map(\.summary).joined(separator: "\n")
        let sent = await sendSummary(bridgeHost, summary)
        if sent {
            Log.event("CrashReportMonitor: relayed \(newReports.count) report summary/summaries to the Bridge")
        } else {
            Log.error("CrashReportMonitor: recovery-launch crash summary relay failed (Bridge unreachable?)")
        }
    }

    /// Shared ISO 8601 UTC formatter, matching `SessionMonitor`'s heartbeat
    /// timestamp format exactly (`.withInternetDateTime`, no fractional
    /// seconds) so the two files' persisted timestamps are directly
    /// comparable/interchangeable in format.
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
