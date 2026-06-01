import Cocoa
import IOKit.pwr_mgt

/// Purpose: Thin wrappers over the macOS system actions Curtain needs.
/// Constraints: every call here was validated against macOS 26 (Sequoia-era).
/// SPORT: MASTER-SYSTEM
enum System {

    // MARK: - Reliable screen lock
    //
    // CGSession -suspend was removed in recent macOS. osascript Ctrl+Cmd+Q needs
    // Accessibility and is unreliable from a launchd agent. SACLockScreenImmediate
    // (private login.framework symbol) locks immediately with no extra permission.

    static func lockScreen() {
        let paths = [
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            "/System/Library/PrivateFrameworks/login.framework/login"
        ]
        typealias LockFn = @convention(c) () -> Int32
        for p in paths {
            if let h = dlopen(p, RTLD_LAZY), let sym = dlsym(h, "SACLockScreenImmediate") {
                _ = unsafeBitCast(sym, to: LockFn.self)()
                return
            }
        }
        // Fallback (needs Accessibility): the lock-screen shortcut.
        let t = Process()
        t.launchPath = "/usr/bin/osascript"
        t.arguments = ["-e", "tell application \"System Events\" to keystroke \"q\" using {command down, control down}"]
        try? t.run()
    }

    /// Put all displays to sleep (after a lock = a dark, locked Mac).
    static func sleepDisplays() {
        let t = Process(); t.launchPath = "/usr/bin/pmset"; t.arguments = ["displaysleepnow"]
        try? t.run()
    }

    // MARK: - Prevent display sleep during a session

    private static var assertionID: IOPMAssertionID = 0
    private static var assertionActive = false

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
    // Killing the connection processes needs root, so install.sh drops a tiny
    // helper at /usr/local/bin/curtain-endsession with a NOPASSWD sudoers rule.
    // launchd respawns the listener, so Screen Sharing stays available afterward.

    static func endScreenShareSession() {
        let helper = "/usr/local/bin/curtain-endsession"
        guard FileManager.default.isExecutableFile(atPath: helper) else { return }
        let t = Process(); t.launchPath = "/usr/bin/sudo"; t.arguments = ["-n", helper]
        try? t.run(); t.waitUntilExit()
    }

    // MARK: - Displays

    static func serial(of screen: NSScreen) -> UInt32 {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        return CGDisplaySerialNumber(id)
    }

    /// A native display can be hidden invisibly (sharingType .none). A DisplayLink
    /// display only exists via screen capture, so .none hides it from the capture
    /// too — it must use .readOnly (visible in the remote view). We identify them
    /// by serial because EDID passthrough makes vendor IDs identical.
    static func isDisplayLink(_ screen: NSScreen) -> Bool {
        Config.shared.displayLinkSerials.contains(serial(of: screen))
    }
}
