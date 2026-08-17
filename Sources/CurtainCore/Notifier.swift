import Foundation
import UserNotifications

/// Purpose: Thin wrapper over UNUserNotificationCenter for the app's banners. Replaces
///          the deprecated NSUserNotification path with the modern UserNotifications API.
/// Inputs: title/body strings; optional throttleKey + window to suppress repeats.
/// Outputs: an immediate (nil-trigger) user notification, or nothing when throttled.
/// Constraints: @MainActor — touches shared throttle state and the notification center
///          from a single context to satisfy Swift 6 strict concurrency. Every call is
///          defensive: a missing bundle id or unavailable center must never crash the
///          agent, so failures are logged and swallowed. Authorization is best-effort.
///          `requestAuthorization()` is `public` because AppDelegate calls it
///          across the CurtainCore module boundary; `post` stays internal since
///          it is only called from within CurtainCore itself. `postPublic(...)`
///          (T-P1-E08-03) is the one narrow public passthrough to `post`, added so
///          AppDelegate can surface the post-crash-relaunch banner without CurtainCore
///          exposing its whole internal notification surface across the module
///          boundary.
/// SPORT: MASTER-NOTIFIER
@MainActor
public enum Notifier {

    /// Last post time per throttle key, used to suppress rapid repeats.
    private static var lastPost: [String: Date] = [:]

    /// True when running under `xctest` (e.g. `swift test`), where there is no real
    /// app bundle/notification proxy even though `Bundle.main.bundleIdentifier` can
    /// be non-nil (under SwiftPM's `swift test` it reads back as the tool's own
    /// identifier, `com.apple.dt.xctest.tool` — confirmed by inspection, not a
    /// helpful "no bundle" nil). `UNUserNotificationCenter.current()` throws
    /// `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil") in
    /// that host process — an uncatchable crash when hit from inside a detached
    /// `Task`, since it terminates the whole test process rather than failing one
    /// test. `ProcessInfo.processInfo.processName` is reliably `"xctest"` in this
    /// host (both the Xcode-hosted and SwiftPM `swift test` paths launch the same
    /// `xctest` tool), so checking that name is a cheap, reliable short-circuit
    /// before ever touching UserNotifications.
    fileprivate static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.processName == "xctest"
    }

    /// Ask once (at launch) for permission to show banners and play sounds. The result
    /// is ignored: if the user declines, post(...) simply becomes a no-op silently.
    public static func requestAuthorization() {
        guard !isRunningUnderXCTest, Bundle.main.bundleIdentifier != nil else {
            NSLog("Curtain: skipping notification authorization — no bundle identifier")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Curtain: notification authorization failed: \(error.localizedDescription)") }
        }
    }

    /// Public passthrough to `post(...)` for callers outside CurtainCore (T-P1-E08-03:
    /// AppDelegate posts the post-crash-relaunch banner from the `Curtain` executable
    /// target, across the module boundary). Kept separate from `post` itself so the
    /// rest of CurtainCore's notification call sites are unaffected by this narrow
    /// exposure.
    public static func postPublic(
        title: String, body: String, throttleKey: String? = nil, throttleSeconds: TimeInterval = 0
    ) {
        post(title: title, body: body, throttleKey: throttleKey, throttleSeconds: throttleSeconds)
    }

    /// Post an immediate banner. When `throttleKey` is set and `throttleSeconds > 0`,
    /// repeats inside the window are dropped. Safe to call from anywhere; hops to main.
    static func post(title: String, body: String, throttleKey: String? = nil, throttleSeconds: TimeInterval = 0) {
        Task { @MainActor in
            guard !isRunningUnderXCTest, Bundle.main.bundleIdentifier != nil else { return }

            if let key = throttleKey, throttleSeconds > 0 {
                let now = Date()
                if let last = lastPost[key], now.timeIntervalSince(last) < throttleSeconds { return }
                lastPost[key] = now
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                NSLog("Curtain: failed to post notification: \(error.localizedDescription)")
            }
        }
    }
}
