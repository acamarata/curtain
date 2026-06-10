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
/// SPORT: MASTER-NOTIFIER
@MainActor
enum Notifier {

    /// Last post time per throttle key, used to suppress rapid repeats.
    private static var lastPost: [String: Date] = [:]

    /// Ask once (at launch) for permission to show banners and play sounds. The result
    /// is ignored: if the user declines, post(...) simply becomes a no-op silently.
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("Curtain: skipping notification authorization — no bundle identifier")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Curtain: notification authorization failed: \(error.localizedDescription)") }
        }
    }

    /// Post an immediate banner. When `throttleKey` is set and `throttleSeconds > 0`,
    /// repeats inside the window are dropped. Safe to call from anywhere; hops to main.
    static func post(title: String, body: String, throttleKey: String? = nil, throttleSeconds: TimeInterval = 0) {
        Task { @MainActor in
            guard Bundle.main.bundleIdentifier != nil else { return }

            if let key = throttleKey, throttleSeconds > 0 {
                let now = Date()
                if let last = lastPost[key], now.timeIntervalSince(last) < throttleSeconds { return }
                lastPost[key] = now
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { NSLog("Curtain: failed to post notification: \(error.localizedDescription)") }
            }
        }
    }
}
