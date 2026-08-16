import Foundation

/// Purpose: One shared seam for every `Process`-based shell/exec launch in Curtain,
///          replacing 4 independently reimplemented call sites that previously had
///          no common mockable interface and differing error handling
///          (CaptureProbe.shell, DisconnectClient.runAdminShell +
///          runSudoEndSession, System.lockScreen + sleepDisplays, and
///          CurtainHelper's DisconnectService.runMatched). A bug fixed in one shape
///          (e.g. the netstat wrong-path incident recorded in session memory) now
///          propagates to every caller automatically.
/// Inputs: an executable path, arguments, and optional stdin data / timeout.
/// Outputs: `Result` (captured stdout + exit status) for the blocking/polling
///          shapes, or nothing for the fire-and-forget shape.
/// Constraints: zero dependencies beyond Foundation (matches CurtainShared's
///              existing zero-dep, fully-tested posture). Every shape here is a
///              thin wrapper over `Process` — no new behavior, no new timeout
///              values; each call site's prior exact semantics (same logging, same
///              timeouts, same return type) are preserved by the call-site
///              migration, not changed by this type.
/// SPORT: MASTER-PROCESSRUNNER
public enum ProcessRunner {

    /// Outcome of a blocking or polling run: captured stdout text and the
    /// process's exit status. `succeeded` is a convenience for the common
    /// "exit 0 means it worked" case (CurtainHelper's runMatched,
    /// DisconnectClient's runAdminShell).
    public struct Result {
        public let output: String
        public let exitCode: Int32
        public var succeeded: Bool { exitCode == 0 }

        /// Public memberwise init: the synthesized one is `internal`, which
        /// blocks construction from other modules (e.g. CurtainCoreTests
        /// building a canned `Result` to inject via CaptureProbe's
        /// `processRunner` test seam).
        public init(output: String, exitCode: Int32) {
            self.output = output
            self.exitCode = exitCode
        }
    }

    /// Run a process to completion, capture stdout, and return once it exits.
    /// Used by CaptureProbe's shell probes (netstat, pgrep) and CurtainHelper's
    /// `DisconnectService.runMatched` (pkill).
    ///
    /// `onLaunchFailure` fires only if the process could not even be started
    /// (e.g. missing binary); the caller supplies its own logging so each site
    /// keeps its existing dedup/throttle behavior (CaptureProbe logs a launch
    /// failure once per path per run; CurtainHelper logs every failure). On
    /// launch failure this returns `Result(output: "", exitCode: -1)`.
    @discardableResult
    public static func run(
        _ path: String,
        _ arguments: [String] = [],
        onLaunchFailure: ((Error) -> Void)? = nil
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            onLaunchFailure?(error)
            return Result(output: "", exitCode: -1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return Result(output: output, exitCode: process.terminationStatus)
    }

    /// Run a process with `stdin` data piped in, and wait for it to exit. Used by
    /// `DisconnectClient.runAdminShell` to pipe a static AppleScript body to
    /// `osascript -` without interpolating untrusted content into script text.
    @discardableResult
    public static func run(
        _ path: String,
        _ arguments: [String] = [],
        stdin: Data,
        onLaunchFailure: ((Error) -> Void)? = nil
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(stdin)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            onLaunchFailure?(error)
            return Result(output: "", exitCode: -1)
        }
        process.waitUntilExit()
        return Result(output: "", exitCode: process.terminationStatus)
    }

    /// Run a process with a bounded wall-clock timeout, polling `isRunning`
    /// rather than blocking indefinitely on `waitUntilExit()`. Used by
    /// `DisconnectClient.runSudoEndSession`, where a hung `sudo` invocation must
    /// never pin the background queue. If the timeout elapses first, the process
    /// is terminated and `timedOut` is true; `Result.exitCode` is the process's
    /// termination status in both cases (whatever `Process` reports after
    /// `terminate()`, matching the pre-extraction behavior exactly).
    ///
    /// `pollInterval` matches the original call site's 50ms poll granularity by
    /// default.
    @discardableResult
    public static func run(
        _ path: String,
        _ arguments: [String] = [],
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        onLaunchFailure: ((Error) -> Void)? = nil
    ) -> (result: Result, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Must be wired before `run()` so stdout written before the first poll
        // tick is still captured. Without this, `pipe.fileHandleForReading` is
        // never read, so CaptureProbe's netstat-based VNC corroborators
        // (establishedVNC/peeredUDPVNC) always saw an empty string regardless
        // of real netstat output — a real bug found and fixed during
        // T-P1-E10-03's verification pass, not a hypothetical.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            onLaunchFailure?(error)
            return (Result(output: "", exitCode: -1), false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(useconds_t(pollInterval * 1_000_000))
        }
        if process.isRunning {
            process.terminate()
            // `terminate()` only sends SIGTERM; it does not block until the
            // process has actually exited. Reading `terminationStatus` before
            // the exit is observed throws NSInvalidArgumentException ("task
            // still running") — a real crash hit by CaptureProbe's shell-out
            // watchdog (T-P1-E05-02) the first time a probe genuinely hung.
            // `waitUntilExit()` here is bounded: SIGTERM reliably ends
            // `sleep`/`netstat`/`pgrep`-class children immediately, so this
            // does not reintroduce an unbounded block.
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (Result(output: output, exitCode: process.terminationStatus), true)
        }
        // Read after confirming exit (not while still running) so this never
        // blocks past the deadline already enforced by the poll loop above.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (Result(output: output, exitCode: process.terminationStatus), false)
    }

    /// Fire-and-forget: launch a process and return immediately without waiting
    /// for it to exit or capturing output. Used by `System.lockScreen`'s
    /// osascript fallback and `System.sleepDisplays`'s pmset call, neither of
    /// which previously checked the result beyond `try?`.
    public static func launchDetached(_ path: String, _ arguments: [String] = []) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }
}
