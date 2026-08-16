import Foundation

/// Purpose: Optional, independently-toggleable consumer of `KVMInputFilter`'s
///          read-only `onMatchedDeviceActivity` hook (T-P1-E13-02's observation
///          point, added in T-P1-E13-03). Posts a throttled "the KVM operator is
///          active right now" banner via the existing `Notifier.post(...)`
///          mechanism — no new notification infrastructure. Purely situational
///          awareness for the desk user; this class has no relationship
///          whatsoever to `CurtainController.shouldCover(uuid:isNew:)` or to
///          `KVMInputFilter`'s seize/pass-through decision, and reads only its
///          own Settings key.
/// Inputs: a `KVMInputFilter` instance to attach to (`attach(to:)`), plus
///          `Settings.kvmActivityNotificationEnabled` (checked fresh on every
///          activity callback, not cached, so a Preferences toggle flip mid-
///          session takes effect immediately — mirrors
///          `KVMInputFilter.registeredIdentity`'s same "read fresh, don't cache"
///          pattern).
/// Outputs: `Notifier.post(...)` banners, throttled to at most once per
///          `throttleSeconds` while matched-device activity continues.
/// Honesty: as of T-P1-E13-03, nothing in production code constructs a
///          `KVMActivityNotifier` or calls `attach(to:)` — this class exists,
///          is fully unit-tested, and does exactly what its doc comment says,
///          but has no live production entry point yet. That is because
///          `KVMInputFilter` (T-P1-E13-02) itself has no production owner
///          either: no ticket has yet wired `activate()`/`deactivate()` into a
///          real "entering/leaving the KVM context" trigger, so there is no
///          existing call site in `SessionCoordinator`/`AppDelegate` for this
///          ticket to hook into without inventing that lifecycle decision,
///          which is out of this ticket's scope (`touches` never listed
///          SessionCoordinator.swift). A later ticket must construct both a
///          `KVMInputFilter` and this class together and call `attach(to:)`
///          for the Preferences toggle to have any observable effect. Until
///          then this feature is inert but harmless — the toggle persists a
///          Settings value and nothing else.
/// Constraints: `attach(to:)` sets `filter.onMatchedDeviceActivity` to a closure
///          that calls back into this instance — genuinely additive, since
///          `KVMInputFilter` neither knows nor cares whether a listener is
///          attached, what it does, or whether it throws (Swift closures here
///          cannot throw uncaught into the filter's call site regardless, but the
///          design intent is the same one documented on `onMatchedDeviceActivity`
///          itself: total one-way, read-only observation). Safe to construct and
///          attach even when the feature is disabled or no KVM is registered —
///          `notify()` simply becomes a no-op when
///          `Settings.kvmActivityNotificationEnabled` is false.
/// SPORT: MASTER-KVMINPUTFILTER
@MainActor
final class KVMActivityNotifier {
    /// Throttle key/window: at most one banner per this many seconds while
    /// activity continues, so continuous KVM typing/clicking does not spam
    /// repeated banners. Matches the throttled-post pattern already used by
    /// `SessionCoordinator.notifyAccessibilityNeeded()` (60s window).
    static let throttleKey = "kvm-activity"
    static let throttleSeconds: TimeInterval = 60

    /// Test-injection point (mirrors `SessionCoordinator.isAccessibilityTrusted`'s
    /// seam): defaults to the real `Notifier.post`, which is itself a no-op under
    /// `xctest` (see Notifier.swift), so tests substitute a spy here to observe
    /// call counts/throttling instead of relying on real UNUserNotificationCenter
    /// delivery, which cannot be observed in a test host.
    var postAction: (String, String, String?, TimeInterval) -> Void = { title, body, throttleKey, throttleSeconds in
        Notifier.post(title: title, body: body, throttleKey: throttleKey, throttleSeconds: throttleSeconds)
    }

    /// Subscribes to the filter's read-only activity hook. Overwrites any
    /// previously-attached closure (matching `onBlockedDevice`'s single-listener
    /// shape) — callers attach once per filter instance.
    func attach(to filter: KVMInputFilter) {
        filter.onMatchedDeviceActivity = { [weak self] in self?.notify() }
    }

    /// Posts the throttled banner iff the feature is enabled. Read fresh from
    /// Settings on every call, not cached at `attach(to:)` time.
    func notify() {
        guard Settings.kvmActivityNotificationEnabled else { return }
        postAction(
            "Curtain",
            "The KVM operator is active right now.",
            Self.throttleKey,
            Self.throttleSeconds
        )
    }
}
