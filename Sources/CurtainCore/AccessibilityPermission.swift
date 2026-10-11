import ApplicationServices
import Cocoa
import CurtainShared

/// Purpose: One place for everything Curtain does about the Accessibility permission:
///          check it, ask for it (the native system prompt, which also lists Curtain in
///          System Settings), open the exact Settings list, and clear a stale grant.
/// Inputs: none; reads live TCC state through the Accessibility API.
/// Outputs: Bool results and side effects (system prompt, System Settings opening).
/// Constraints: `requestPrompt()` never shows UI under xctest, so `swift test` cannot pop a
///          real permission dialog. The pane link is a list tried in order because the
///          deep-link scheme has changed across macOS releases: on macOS 27 the legacy
///          `com.apple.Privacy-Accessibility-Settings` link opened nothing, while the two
///          below land on the list (titled "Device Control and Data Access" there).
///          `public` because the Curtain executable's onboarding, preferences and menu
///          call it across the module boundary.
/// SPORT: MASTER-SYSTEM
public enum AccessibilityPermission {

    /// Deep links to the Accessibility list, best first.
    static let settingsURLStrings = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ]

    /// The list is called "Accessibility" up to macOS 15 and "Device Control and Data
    /// Access" on macOS 27; user-facing text names both so the wizard matches the screen.
    public static let paneNameHint = "Accessibility (shown as \"Device Control and Data Access\" on newer macOS)"

    public static var isGranted: Bool { AXIsProcessTrusted() }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.processName == "xctest"
    }

    /// Ask macOS to show its own "allow Curtain to control this computer" prompt. This is
    /// also what adds Curtain to the Settings list, so a user never has to hunt for it.
    /// Returns the current trust state. A no-op under xctest.
    @discardableResult
    public static func requestPrompt() -> Bool {
        guard !isRunningUnderXCTest else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Open the Accessibility list directly. Falls back to the next link, then to just
    /// opening System Settings, if a link cannot be opened. `opener` is injectable for tests.
    @discardableResult
    public static func openSettings(opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        for string in settingsURLStrings {
            if let url = URL(string: string), opener(url) { return true }
        }
        return opener(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// The one-click path: show the system prompt, then bring the exact Settings list up
    /// right behind it so the user only has to flip Curtain's switch.
    public static func requestAndOpenSettings() {
        requestPrompt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { openSettings() }
    }

    /// `tccutil` arguments that clear Curtain's Accessibility entry. Pure for testing.
    static func resetArguments(bundleID: String) -> [String] { ["reset", "Accessibility", bundleID] }

    /// Clear a stale grant: after a re-sign the Settings switch can read ON while the
    /// running app is still not trusted. Resetting lets the next request prompt cleanly.
    @discardableResult
    public static func resetStaleGrant(bundleID: String = Bundle.main.bundleIdentifier ?? "io.acamarata.curtain")
        -> Bool
    {
        ProcessRunner.run("/usr/bin/tccutil", resetArguments(bundleID: bundleID)).succeeded
    }

    // MARK: - Throttled automatic prompt

    private static var lastAutoPrompt: Date?

    /// Raise the system prompt at the moment a feature needs it (an activation refused for
    /// lack of Accessibility), at most once per `interval`, so a refused session never
    /// nags. Visible over a remote session too, so the operator can grant it from there.
    public static func promptIfDue(interval: TimeInterval = 600, now: Date = Date()) {
        if let last = lastAutoPrompt, now.timeIntervalSince(last) < interval { return }
        lastAutoPrompt = now
        requestPrompt()
    }

    /// Test seam: forget the throttle.
    static func resetThrottleForTesting() { lastAutoPrompt = nil }
}
