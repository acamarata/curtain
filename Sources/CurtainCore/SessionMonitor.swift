import CoreGraphics
import Foundation

/// Purpose: Detect Screen Sharing connect / disconnect / idle and fire callbacks.
/// How: polls every 2s. The connect signal is `CaptureProbe.signals()`: the CGSession
///      capture key is authoritative; the fallback activators are an ESTABLISHED
///      inbound TCP session on port 5900 (classic VNC) and a peered UDP socket on
///      5900-5902 (High-Performance transport). This replaces the old netstat-only
///      detection, which silently failed under macOS Sequoia/26 High-Performance
///      Screen Sharing (UDP, no ESTABLISHED state) and on remapped ports, and it
///      drops the old process / LISTEN-socket activators that lingered with no
///      session and kept the curtain up overnight. Disconnect is debounced
///      (3 consecutive misses, ~6s) so a transient blip never kills a live session.
/// Constraints: the class lives on the main thread (the Timer runs on the main
///      runloop and all state vars are main-thread-only). Probes block on shell
///      calls, so each tick runs the probes on a background queue and hops back to
///      the main thread before touching state or firing callbacks. A `probing` flag
///      coalesces ticks so a slow probe never overlaps the next one.
///
///      Console-vs-virtual stand-down is inherent: `combinedCaptureActive()` is
///      driven by the capture key, which reads false for a different-user virtual
///      session, so we simply never report a connect in that case.
///
///      Each detected connect generates a short `currentEpisodeID` correlation
///      token, passed to `onConnect` and tagged onto this class's own log lines, so
///      one session's Console.app/`log stream` lines can be filtered together.
/// SPORT: MASTER-SESSIONMONITOR
@MainActor
public final class SessionMonitor {
    /// Fires when a connect is detected. Carries the freshly-generated episode ID
    /// (see `currentEpisodeID`) so the coordinator can thread it through the
    /// session's connect/idle/end log lines without a second lookup.
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onIdleTimeout: (() -> Void)?

    private var timer: Timer?
    private var connected = false
    private var missCount = 0
    private var probing = false
    /// Last raw signal snapshot, kept only to log per-signal changes (which signal
    /// actually saw the session) without spamming a line per tick.
    private var lastSignals: CaptureProbe.CaptureSignals?

    /// Short correlation token for the in-progress session, regenerated each time a
    /// connect is detected (`connected` flips false -> true). `nil` while idle. Not
    /// a tracing framework — just a value threaded into log message strings so one
    /// session's lines can be grepped/filtered together in Console.app/`log stream`.
    private(set) var currentEpisodeID: String?

    private var idleFired = false
    /// Idle only counts once we have seen a sub-threshold reading. This prevents
    /// firing on connect-time idle: if the user was already idle when the session
    /// began, we wait for one reading below the threshold before arming.
    private var idleArmed = false

    private let missLimit = 3  // ~6s at the 2s poll interval
    private let pollInterval: TimeInterval = 2

    private let probeQueue = DispatchQueue(label: "com.curtain.session-monitor.probe", qos: .userInitiated)

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Evaluate once immediately so a session already in progress is caught at start.
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Poll

    private func tick() {
        guard !probing else { return }
        probing = true

        probeQueue.async { [weak self] in
            let signals = CaptureProbe.signals()
            let idle = SessionMonitor.idleSeconds()
            Task { @MainActor in
                self?.apply(signals: signals, idle: idle)
            }
        }
    }

    private func apply(signals: CaptureProbe.CaptureSignals, idle: Int) {
        defer { probing = false }

        // Log raw signal changes (transitions only) so a live test shows exactly
        // which signal saw the session — and which one missed it.
        if signals != lastSignals {
            Log.event(
                "signals: captured=\(signals.captured) tcpEstab=\(signals.tcpEstablished) udpPeered=\(signals.udpPeered)",
                episode: currentEpisodeID)
            lastSignals = signals
        }

        if signals.any {
            missCount = 0
            if !connected {
                connected = true
                idleFired = false
                idleArmed = false
                let episodeID = String(UUID().uuidString.prefix(8))
                currentEpisodeID = episodeID
                Log.event(
                    "session detected: captured=\(signals.captured) tcpEstab=\(signals.tcpEstablished) udpPeered=\(signals.udpPeered) idle=\(idle)",
                    episode: episodeID)
                onConnect?(episodeID)
            }
            evaluateIdle(idle)
        } else if connected {
            missCount += 1
            if missCount >= missLimit {
                connected = false
                missCount = 0
                Log.event("session ended (debounced)", episode: currentEpisodeID)
                onDisconnect?()
                currentEpisodeID = nil
            }
        }

        writeHeartbeat()
    }

    // MARK: - Heartbeat (T-P1-E10-01)

    /// Purpose: crash-recovery liveness signal. `launchctl`/`ps` can only confirm a
    ///          PID exists — they cannot tell you whether this class's Timer is still
    ///          actually firing, whether the probe queue has wedged, or whether the
    ///          reported state is correct. This file is overwritten (never appended)
    ///          at the end of every `apply(signals:idle:)` call — i.e. post-tick state,
    ///          not pre-tick — so an external reader always sees the monitor's latest
    ///          verdict, not a stale pre-update snapshot.
    /// Format: a small JSON object at
    ///          `~/Library/Application Support/Curtain/heartbeat.json`:
    ///            - `timestamp` (String, ISO 8601 UTC, e.g. "2026-08-15T12:00:00Z")
    ///            - `armed`     (Bool, Settings.armed at tick time)
    ///            - `connected` (Bool, this monitor's own `connected` var)
    ///            - `idleArmed` (Bool, this monitor's own `idleArmed` var)
    ///            - `idleFired` (Bool, this monitor's own `idleFired` var)
    ///          Cadence: written once per tick, ~2s (pollInterval). CONSUMED BY THE
    ///          FUTURE E-14 `curtain_status` MCP TOOL — do not rename/remove any of
    ///          these fields without updating that tool. Directory resolution goes
    ///          through `heartbeatDirectory()`, which honors `heartbeatDirectoryOverride`
    ///          (test seam, `nil` in production) — see that property's doc comment.
    /// Constraints: must never crash the tick loop. Directory creation and the file
    ///          write are both best-effort: any thrown error (disk full, permission
    ///          race, sandbox denial) is caught and dropped, leaving the previous
    ///          heartbeat file (or none) in place rather than propagating. The write
    ///          hops to `probeQueue` (the same background queue `tick()` already uses
    ///          for probe work) so JSON encoding + file I/O never blocks the main
    ///          thread's tick path. A value-type snapshot is captured on the main
    ///          actor first so nothing `@MainActor`-isolated crosses the queue hop.
    private func writeHeartbeat() {
        let snapshot = HeartbeatSnapshot(
            timestamp: SessionMonitor.iso8601Formatter.string(from: Date()),
            armed: Settings.armed,
            connected: connected,
            idleArmed: idleArmed,
            idleFired: idleFired)

        probeQueue.async {
            SessionMonitor.writeHeartbeatFile(snapshot)
        }
    }

    /// Plain value type so a heartbeat snapshot can cross the `probeQueue` hop
    /// without carrying any `@MainActor`-isolated state.
    private struct HeartbeatSnapshot: Encodable {
        let timestamp: String
        let armed: Bool
        let connected: Bool
        let idleArmed: Bool
        let idleFired: Bool
    }

    /// Shared formatter for the heartbeat's `timestamp` field (ISO 8601 UTC,
    /// fractional seconds omitted — second-resolution is enough for a liveness
    /// signal on a 2s cadence). `nonisolated(unsafe)`: `DateFormatter` is not
    /// `Sendable`, but this instance is only ever read (never mutated) after
    /// creation, and only from `probeQueue`/callers that already synchronize via
    /// that serial queue, so concurrent access is safe in practice.
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Injection seam for tests: the directory `writeHeartbeatFile` writes into,
    /// defaulting to `nil` (production real path, `~/Library/Application
    /// Support/Curtain`). Production code never overrides this — see
    /// `heartbeatDirectory()` below, which falls back to the real Application
    /// Support path whenever this is `nil`. Tests set it to a private per-test-run
    /// temp directory (mirroring the `CaptureProbe.processRunner` seam convention)
    /// so a real `SessionMonitor` instance started by one test can never race
    /// another test's, or a real running Curtain instance's, heartbeat file.
    /// `CurtainStatusTool`'s read side consults the same override via
    /// `SessionMonitor.heartbeatDirectory()` so write and read sides always agree
    /// on the current path.
    public nonisolated(unsafe) static var heartbeatDirectoryOverride: URL?

    /// Resolves the directory `heartbeat.json` lives in: `heartbeatDirectoryOverride`
    /// if a test has set one, otherwise the real `~/Library/Application
    /// Support/Curtain` path. Shared by both the write side (`writeHeartbeatFile`
    /// below) and the read side (`CurtainStatusTool.readHeartbeatTimestamp`) so
    /// they can never disagree about where the file lives. `public` (rather than
    /// internal) so the `Curtain` target's `CurtainStatusTool` can consult the same
    /// resolution logic across the module boundary — this is a real, non-`@testable`
    /// cross-target dependency, unlike the tests below which reach the override
    /// property directly via `@testable import CurtainCore`.
    public nonisolated static func heartbeatDirectory() -> URL? {
        if let override = heartbeatDirectoryOverride { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Curtain", isDirectory: true)
    }

    /// Best-effort directory-create + atomic overwrite. Runs off the main thread
    /// (called only from `probeQueue`). Never throws out of this function — any
    /// failure is silently dropped so a wedged disk/permission race can never crash
    /// the tick loop (see CR-A guidance on this ticket).
    nonisolated private static func writeHeartbeatFile(_ snapshot: HeartbeatSnapshot) {
        guard let dir = heartbeatDirectory() else { return }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            let fileURL = dir.appendingPathComponent("heartbeat.json")
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort only — a failed heartbeat write must never crash the
            // monitor. Nothing else reads the result on this queue, so there is
            // no state to roll back; the previous file (or none) is left as-is.
        }
    }

    private func evaluateIdle(_ idle: Int) {
        guard Settings.idleEnabled else { return }
        let threshold = Settings.idleMinutes * 60

        if idle < threshold {
            // Below threshold: arm the latch and clear any prior fire.
            idleArmed = true
            idleFired = false
            return
        }

        // At or above threshold: only fire if we have armed since connect and
        // have not already fired this idle stretch.
        if idleArmed, !idleFired {
            idleFired = true
            Log.event("idle timeout fired", episode: currentEpisodeID)
            onIdleTimeout?()
        }
    }

    // MARK: - Idle source

    /// Seconds since the last qualifying input event, from the event system rather
    /// than ioreg.
    ///
    /// Source selection (Settings.idleSourceIsHID):
    /// - `false` (default "sessionInput"): `.combinedSessionState` — counts activity
    ///   from ALL sources in the session, including the remote operator. This is the
    ///   product default because idle-on-session should respond to operator inactivity,
    ///   not just physical desk input.
    /// - `true` ("hidIdle"): `.hidSystemState` — counts only physical HID events at
    ///   the desk. Remote operator activity is invisible to this source; the idle
    ///   clock ticks even while the operator types remotely.
    nonisolated private static func idleSeconds() -> Int {
        let source: CGEventSourceStateID = Settings.idleSourceIsHID ? .hidSystemState : .combinedSessionState
        let seconds = CGEventSource.secondsSinceLastEventType(source, eventType: .null)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds)
    }
}
