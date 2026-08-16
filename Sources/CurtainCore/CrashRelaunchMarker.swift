import Foundation

/// Purpose: Distinguish "this launch follows a clean quit" from "this launch follows
///          an unexpected exit" (crash, kill -9 relaunch via AppSupervisor's launchd
///          KeepAlive, force-quit, power loss) for T-P1-E08-03. The main app has no
///          durable state of its own to consult at launch other than this marker.
/// Inputs: none — reads/writes a single UserDefaults bool.
/// Outputs: `wasCleanShutdown` (bool); `armClean()`/`disarm()` mutate the marker.
/// Constraints (READ BEFORE EDITING — the ordering here is the entire point of this
///          file, see CR-B guidance in T-P1-E08-03): the marker MUST be written only
///          from `applicationWillTerminate`/`cleanup()`, i.e. only once AppKit has
///          already decided to terminate the process and no further crash can occur
///          before exit — writing it any earlier (e.g. speculatively during normal
///          operation, or eagerly at launch) would falsely mark a session "clean" that
///          then crashes seconds later, producing the exact false-negative the ticket's
///          CR-B guidance calls out. Symmetrically, the marker MUST be disarmed
///          (cleared) at the very start of the next `applicationDidFinishLaunching`,
///          before any code that could itself crash runs, so a crash during THIS
///          session doesn't inherit the previous session's "clean" marker and read as
///          falsely clean — `disarm()` runs first and returns what it found, so the
///          read-then-clear is a single atomic step from the caller's point of view.
///          UserDefaults.synchronize() is called explicitly on write, even though
///          modern UserDefaults auto-persists async, because this specific write must
///          survive a SIGTERM/process-exit race immediately after cleanup() returns —
///          the whole point of the marker is that it needs to be durable before the
///          process actually dies, and the standard "eventually synced" async
///          contract is not good enough for a flag whose only job is to be correct at
///          the moment of death.
/// SPORT: MASTER-APP
public enum CrashRelaunchMarker {
    private static let key = "cleanShutdownMarker"

    /// Call once, at the very start of `applicationDidFinishLaunching`, before any
    /// other startup work. Returns `true` if the marker was ABSENT (i.e. the previous
    /// run did not exit cleanly — crash, kill -9, force-quit, power loss), which is
    /// the signal AppDelegate uses to decide whether to post the "restarted after an
    /// unexpected exit" notification. Immediately clears the marker either way, so a
    /// crash partway through THIS session is correctly detected as unclean on the
    /// NEXT launch rather than inheriting a stale "clean" reading.
    @discardableResult
    public static func disarmAndCheckPriorCrash() -> Bool {
        let defaults = UserDefaults.standard
        let wasClean = defaults.bool(forKey: key)
        defaults.removeObject(forKey: key)
        return !wasClean
    }

    /// Call once, at the very end of `cleanup()`/`applicationWillTerminate`, after
    /// every other teardown step has already run (curtain dropped, input/display
    /// assertions released) — i.e. only once nothing else could plausibly fail. Marks
    /// this shutdown as clean and forces synchronous persistence so the flag survives
    /// the process actually exiting immediately afterward.
    public static func armClean() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: key)
        defaults.synchronize()
    }
}
