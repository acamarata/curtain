import Cocoa
import IOKit.pwr_mgt
import CurtainShared

/// Purpose: Thin wrappers over the macOS system actions Curtain needs.
/// Constraints: every call here was validated against macOS 26 (Sequoia-era).
///          `startupLockProbe()` and `uuid(of:)` are `public` because the thin
///          `Curtain` executable (AppDelegate, PrefDisplaysTab, PreferencesWindow)
///          calls them across the CurtainCore module boundary; everything else
///          here is only used internally within CurtainCore.
/// SPORT: MASTER-SYSTEM
public enum System {

    // MARK: - Reliable screen lock
    //
    // CGSession -suspend was removed in recent macOS. osascript Ctrl+Cmd+Q needs
    // Accessibility and is unreliable from a launchd agent. SACLockScreenImmediate
    // (private login.framework symbol) locks immediately with no extra permission.

    private static let loginPaths = [
        "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
        "/System/Library/PrivateFrameworks/login.framework/login"
    ]

    /// Resolve the private lock symbol without calling it. Returns the function
    /// pointer if found, nil otherwise. Both callers use this so probing and
    /// locking stay in sync.
    private static func resolveLockFn() -> (@convention(c) () -> Int32)? {
        typealias LockFn = @convention(c) () -> Int32
        for p in loginPaths {
            if let h = dlopen(p, RTLD_LAZY), let sym = dlsym(h, "SACLockScreenImmediate") {
                return unsafeBitCast(sym, to: LockFn.self)
            }
        }
        return nil
    }

    /// Call once at launch to surface a clear warning if the fast lock path is
    /// missing on this OS build, before the user ever relies on it.
    public static func startupLockProbe() {
        if resolveLockFn() == nil {
            NSLog("Curtain: SACLockScreenImmediate unavailable — lock will fall back to osascript")
        }
    }

    static func lockScreen() {
        if let lock = resolveLockFn() {
            _ = lock()
            return
        }
        NSLog(
            "Curtain: SACLockScreenImmediate could not be resolved on either login.framework path — falling back to osascript"
        )
        // Fallback (needs Accessibility): the lock-screen shortcut. Fire-and-forget
        // via the shared ProcessRunner, matching the prior `try? t.run()` behavior.
        ProcessRunner.launchDetached(
            "/usr/bin/osascript",
            ["-e", "tell application \"System Events\" to keystroke \"q\" using {command down, control down}"])
    }

    /// Put all displays to sleep (after a lock = a dark, locked Mac).
    /// Runs off the main thread so a slow exec never stalls the UI.
    static func sleepDisplays() {
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessRunner.launchDetached("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    // MARK: - Prevent display sleep during a session

    nonisolated(unsafe) private static var assertionID: IOPMAssertionID = 0
    nonisolated(unsafe) private static var assertionActive = false

    static func preventDisplaySleep() {
        guard !assertionActive else { return }
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Curtain active" as CFString,
            &assertionID)
        assertionActive = (ok == kIOReturnSuccess)
    }

    static func allowDisplaySleep() {
        if assertionActive { IOPMAssertionRelease(assertionID); assertionActive = false }
    }

    // MARK: - End the active Screen Sharing session
    //
    // Killing the connection processes needs root. The disconnect feature is an
    // optional privileged daemon installed separately (SMAppService.daemon). The
    // daemon client sets disconnectHandler at launch; if nothing sets it, the
    // disconnect is simply a no-op with a logged note. No sudo, no blocking.

    /// Set by the daemon client when the privileged disconnect helper is enabled.
    /// Invoked on a background queue so it never touches the main thread.
    nonisolated(unsafe) static var disconnectHandler: (() -> Void)?

    static func endScreenShareSession() {
        if let handler = disconnectHandler {
            DispatchQueue.global(qos: .userInitiated).async { handler() }
            return
        }
        NSLog("Curtain: disconnect requested but the remote-disconnect helper is not enabled")
    }

    // MARK: - Displays

    static func serial(of screen: NSScreen) -> UInt32? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            NSLog("Curtain: screen missing NSScreenNumber — serial lookup failed")
            return nil
        }
        return CGDisplaySerialNumber(id)
    }

    /// Stable per-display UUID. Survives reboots and port changes better than the
    /// serial, and unlike the serial it is unique even when EDID passthrough makes
    /// vendor IDs identical. Returns nil if the display can't be resolved.
    public static func uuid(of screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, cfUUID) as String
    }

    /// A native display can be hidden invisibly (sharingType .none). A DisplayLink
    /// display only exists via screen capture, so .none hides it from the capture
    /// too — it must use .readOnly (visible in the remote view). We match by UUID
    /// now, falling back to the legacy serial list so older configs keep working.
    static func isDisplayLink(_ screen: NSScreen) -> Bool {
        if let id = uuid(of: screen) {
            return Settings.displayLinkUUIDs.contains(id)
        }
        guard let serial = serial(of: screen) else { return false }
        return Settings.legacyDisplayLinkSerials.contains(serial)
    }
}
