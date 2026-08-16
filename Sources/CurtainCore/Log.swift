import os

/// Purpose: One-line diagnostic logging for live testing, gated by the
///          diagnostics-logging setting so it stays silent in normal use.
/// Inputs: a short, greppable message string, plus an optional per-session
///          `episode` correlation token (see SessionMonitor.currentEpisodeID).
///          Never pass secrets or passwords.
/// Outputs: a `.public` os.Logger line under subsystem io.acamarata.curtain so it
///          shows in `log stream` / Console without redaction. No-op when disabled
///          (event only — error is always emitted).
/// Constraints: only log state transitions, never per-keystroke or per-tick events,
///          to avoid spam. os.Logger is Sendable, so the static instance is safe
///          under Swift 6 strict concurrency. The `episode` parameter is a thin,
///          optional prefix — no tracing framework, no persistence, no cross-call
///          state beyond what the caller passes in.
/// SPORT: MASTER-LOG
public enum Log {
    private static let logger = Logger(subsystem: "io.acamarata.curtain", category: "curtain")

    /// Prefix a message with its episode correlation token, when one is supplied.
    /// Kept as a single shared formatter so `event` and `error` stay in sync.
    private static func tag(_ message: String, episode: String?) -> String {
        guard let episode, !episode.isEmpty else { return message }
        return "[episode=\(episode)] \(message)"
    }

    public static func event(_ message: String, episode: String? = nil) {
        guard Settings.diagnosticsLoggingEnabled else { return }
        logger.log("CURTAIN \(tag(message, episode: episode), privacy: .public)")  // .public so it shows in log stream
    }

    /// Unconditional error logging — NOT gated by the diagnostics setting. Reserved
    /// for failures that would otherwise be silent (e.g. a detection probe that can
    /// no longer launch its helper tool). Errors are rare by definition, so this
    /// never spams; callers must still rate-limit anything that can repeat. Public:
    /// called from the executable target's AppDelegate (T-P1-E08-02 crash telemetry).
    public static func error(_ message: String, episode: String? = nil) {
        logger.error("CURTAIN ERROR \(tag(message, episode: episode), privacy: .public)")
    }
}
