import Foundation

/// Purpose: Pure path-matching/OR-semantics logic pulled out of
///          `CurtainHelper.DisconnectService`, so it is unit testable without a
///          live `sysctl(KERN_PROC_ALL)` process enumeration or a real `kill(2)`
///          call. Covers two things: (1) does a resolved executable path belong
///          to a fixed, known-target path list (the exact-path check that
///          replaced the old `pkill -f` argv-substring matching), and (2) the
///          "matched = true if ANY of N independent checks matched" OR-reduction
///          used by `endScreenSharingSession`, which runs three independent kill
///          attempts (two `killByExactPath` calls + one `pkill -x`) and reports
///          success if any one of them found a target.
/// Inputs: plain `String` paths and `Bool` outcomes — no PID enumeration, no
///         filesystem/process access of any kind.
/// Outputs: `Bool` match/overall-success results.
/// Constraints: zero dependencies beyond Foundation. This file contains no
///              `kill(2)`/`proc_pidpath`/`sysctl` calls — those stay in
///              `CurtainHelper/main.swift`, which is the only place actual
///              process termination may happen (root-privileged daemon code).
/// SPORT: MASTER-DISCONNECT
public enum DisconnectMatcher {

    /// True if `path` is exactly one of `expectedPaths`. Mirrors the real
    /// `killByExactPath` targeting rule: an exact string match against a fixed,
    /// known system location — never a substring/regex match against argv, so a
    /// process cannot spoof its way into (or out of) a match by controlling its
    /// own command-line arguments.
    public static func pathMatches(_ path: String, expectedPaths: [String]) -> Bool {
        expectedPaths.contains(path)
    }

    /// OR-reduction over independent kill-attempt outcomes: true if any one of
    /// them reports a match. Mirrors `endScreenSharingSession`'s
    /// `matched = false; if a { matched = true }; if b { matched = true }; if c { matched = true }`
    /// accumulation — three independent targeting strategies (two exact-path
    /// kills + one exact-process-name `pkill -x`), any one of which succeeding is
    /// sufficient to report the disconnect as having found and signalled a
    /// target process.
    public static func anyMatched(_ outcomes: [Bool]) -> Bool {
        outcomes.contains(true)
    }
}
