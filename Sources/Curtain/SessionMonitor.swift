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
/// SPORT: MASTER-SESSIONMONITOR
@MainActor
final class SessionMonitor {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onIdleTimeout: (() -> Void)?

    private var timer: Timer?
    private var connected = false
    private var missCount = 0
    private var probing = false
    /// Last raw signal snapshot, kept only to log per-signal changes (which signal
    /// actually saw the session) without spamming a line per tick.
    private var lastSignals: CaptureProbe.CaptureSignals?

    private var idleFired = false
    /// Idle only counts once we have seen a sub-threshold reading. This prevents
    /// firing on connect-time idle: if the user was already idle when the session
    /// began, we wait for one reading below the threshold before arming.
    private var idleArmed = false

    private let missLimit = 3                 // ~6s at the 2s poll interval
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
            Log.event("signals: captured=\(signals.captured) tcpEstab=\(signals.tcpEstablished) udpPeered=\(signals.udpPeered)")
            lastSignals = signals
        }

        if signals.any {
            missCount = 0
            if !connected {
                connected = true
                idleFired = false
                idleArmed = false
                Log.event("session detected: captured=\(signals.captured) tcpEstab=\(signals.tcpEstablished) udpPeered=\(signals.udpPeered) idle=\(idle)")
                onConnect?()
            }
            evaluateIdle(idle)
        } else if connected {
            missCount += 1
            if missCount >= missLimit {
                connected = false
                missCount = 0
                Log.event("session ended (debounced)")
                onDisconnect?()
            }
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
            Log.event("idle timeout fired")
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
