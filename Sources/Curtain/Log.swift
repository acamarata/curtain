import os

/// Purpose: One-line diagnostic logging for live testing, gated by the
///          diagnostics-logging setting so it stays silent in normal use.
/// Inputs: a short, greppable message string. Never pass secrets or passwords.
/// Outputs: a `.public` os.Logger line under subsystem io.acamarata.curtain so it
///          shows in `log stream` / Console without redaction. No-op when disabled.
/// Constraints: only log state transitions, never per-keystroke or per-tick events,
///          to avoid spam. os.Logger is Sendable, so the static instance is safe
///          under Swift 6 strict concurrency.
/// SPORT: MASTER-LOG
enum Log {
    private static let logger = Logger(subsystem: "io.acamarata.curtain", category: "curtain")

    static func event(_ message: String) {
        guard Settings.diagnosticsLoggingEnabled else { return }
        logger.log("CURTAIN \(message, privacy: .public)")  // .public so it shows in log stream
    }

    /// Unconditional error logging — NOT gated by the diagnostics setting. Reserved
    /// for failures that would otherwise be silent (e.g. a detection probe that can
    /// no longer launch its helper tool). Errors are rare by definition, so this
    /// never spams; callers must still rate-limit anything that can repeat.
    static func error(_ message: String) {
        logger.error("CURTAIN ERROR \(message, privacy: .public)")
    }
}
