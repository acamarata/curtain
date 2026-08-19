# Architecture

## Module overview

All app source lives in `Sources/Curtain/`. A shared target `Sources/CurtainShared/` holds the XPC contract, and a second executable `Sources/CurtainHelper/` is the privileged disconnect daemon. Each file has a single responsibility.

### `Sources/Curtain/`

| File | Role |
|---|---|
| `main.swift` | Entry point. Sets `NSApplication` activation policy to `.accessory` (no Dock icon). Contains a hidden `--render-icon <dir>` build helper used by the release script to generate the app icon without shipping image assets. |
| `AppDelegate.swift` | Wires all pieces together. No logic of its own: it connects callbacks between the coordinator, the menu bar, and the settings window. Registers defaults, reconciles the login item state, and shows onboarding on first launch. |
| `SessionCoordinator.swift` | The brain. An explicit state machine (idle, active, unlocking) that owns the curtain, the input filter, and the monitor. Responds to connect/idle/end/password events and drives `ActionRunner`. Exposes `activateNow`, `deactivateNow`, and `testCurtain` for manual control. Also re-verifies `AXIsProcessTrusted()` every tick while a cover is active — see "Mid-session Accessibility re-check" below. |
| `SessionMonitor.swift` | Combines the capture probe, process presence, and netstat into one connect/disconnect signal. Reads idle time. Fires `onConnect`, `onIdleTimeout`, and `onDisconnect`. Disconnect is debounced over 3 consecutive misses of the combined signal. |
| `CaptureProbe.swift` | The detection primitive. Reads `CGSessionScreenIsCaptured` from `CGSessionCopyCurrentDictionary()`. Transport-independent: true whether the remote streams over TCP or UDP. Also reports whether the captured session is the local console (curtain applies) or a different user's virtual session (Curtain stands down). |
| `InputFilter.swift` | Installs a `CGEventTap` covering keyboard, mouse, scroll, and `.systemDefined` (media and brightness keys) events. Blocks physical events (`sourceStateID == 1`), passes remote events. Routes physical `keyDown` events to `onPhysicalKey`. Re-enables the tap on timeout/disable, and retries automatically once Accessibility is granted. A convenience filter, not a security boundary. |
| `KVMInputFilter.swift` (T-P1-E13-02) | A second, independent input-filtering mechanism, IOHIDManager-based rather than CGEventTap-based. `InputFilter`'s `sourceStateID` check cannot distinguish a KVM's emulated USB HID device from real desk hardware — both report `sourceStateID == 1` — because device identity is already abstracted away by the time an event reaches a CGEventTap. `KVMInputFilter` watches HID device attach/detach (`IOHIDManagerRegisterDeviceMatchingCallback`/`...RegisterDeviceRemovalCallback`, plus an `IOHIDManagerCopyDevices` sweep at `activate()` for devices already present), reads each device's identity (vendor ID / product ID / location ID via `IOHIDDeviceGetProperty`), and compares it against the registered TinyPilot identity using the pure, fully-unit-tested `KVMDeviceIdentity.matches(candidate:)`. Non-matching devices are genuinely blocked via `IOHIDDeviceOpen(_:kIOHIDOptionsTypeSeizeDevice)` (exclusive open — prevents the system and other clients from receiving that device's events), not merely detected; `deactivate()` closes every seized device. Scoped narrowly: `isEffectivelyActive` requires both an explicit `activate()` call and a registered identity in `Settings`, so a forgotten-active filter or a not-yet-paired KVM can never seize input elsewhere. `locationID` is optional/advisory (a KVM's port path can shift across reconnects) — only vendor+product ID are required to match. Does not read, call, or modify `InputFilter.swift` in any way; the two run independently on separate event pipelines. Live verification against a real TinyPilot's actual vendor/product ID, and end-to-end confirmation that seizure blocks a real keyboard/mouse, remain outstanding hardware-in-hand steps. |
| `KVMActivityNotifier.swift` (T-P1-E13-03) | Optional, independently-toggleable consumer of `KVMInputFilter`'s read-only `onMatchedDeviceActivity` hook. Posts a throttled "the KVM operator is active right now" banner via the existing `Notifier.post(...)` mechanism when `Settings.kvmActivityNotificationEnabled` is on (off by default). Has no relationship to `CurtainController.shouldCover(uuid:isNew:)` or to `KVMInputFilter`'s seize/pass-through decision — see the KVM section below for the zero-coupling guarantee. Not yet constructed/attached anywhere in production code (no ticket has wired `KVMInputFilter` into a real session-lifecycle trigger yet); fully unit-tested but inert until that wiring lands. |
| `CurtainController.swift` | Manages the set of per-display cover windows (replaces the cover-management code that was in `Curtain.swift`). Creates, reconciles, and destroys `CoverWindow` instances keyed by display UUID. Handles hotplug via `didChangeScreenParametersNotification`. |
| `CoverContentView.swift` | SwiftUI view rendered inside each cover window. Draws the chosen cover style: solid, message, blur, logo, or aerial video. One shared `AVPlayer` decoder services all displays when the aerial style is active. |
| `PasswordBox.swift` | The on-curtain password entry UI. Appears on a chosen display when a physical key is pressed. Manages timeout, attempt backoff, and routing the result to the coordinator. |
| `Actions.swift` | `ActionSet` struct (activateCurtain, disconnect, lock, screenOff, deactivateCurtain) and `ActionRunner` that executes a set in a defined order: disconnect first, deactivate, lock, then sleep displays last. |
| `System.swift` | Thin wrappers: `lockScreen` (SACLockScreenImmediate via dlopen/dlsym + fallback), `sleepDisplays`, `preventDisplaySleep`/`allowDisplaySleep` (IOPMAssertion), display UUID/serial helpers, `isDisplayLink(_:)`. |
| `DisconnectClient.swift` | Client side of the disconnect XPC. Talks to `CurtainHelper` over the shared `DisconnectXPC` protocol when the optional disconnect daemon is installed. |
| `Settings.swift` | All preferences backed by `UserDefaults`. Defines `Key` constants shared with `@AppStorage`. Typed accessors for the coordinator. Password stored as a salted PBKDF2-HMAC-SHA256 hash. Default password `curtain` when no hash is set. Also holds the KVM device-identity storage contract (`kvmDeviceVendorID`/`kvmDeviceProductID`/`kvmDeviceLocationID`, T-P1-E13-02) — defined here and read by `KVMInputFilter`, populated by E-11's setup-wizard pairing flow (not yet built). |
| `PrefGeneralTab.swift` | SwiftUI view for the General settings tab. |
| `PrefAppearanceTab.swift` | SwiftUI view for the Appearance tab. |
| `PrefIdleEndTab.swift` | SwiftUI view for the On Session Idle / On Session End tabs. |
| `PrefSecurityTab.swift` | SwiftUI view for the Security tab. |
| `PrefDisconnectTab.swift` | SwiftUI view for the Disconnect tab. |
| `PrefDisplaysTab.swift` | SwiftUI view for the Displays tab. |
| `PrefAdvancedTab.swift` | SwiftUI view for the Advanced tab. |
| `PreferencesWindow.swift` | `NSWindow` host for the per-tab SwiftUI settings views. Binds to `@AppStorage` keys so changes apply live. |
| `OnboardingWindow.swift` | First-launch walkthrough: explains the Accessibility grant, the optional disconnect daemon, and a quick visual test. |
| `MenuBarController.swift` | Optional `NSStatusItem` showing the curtains glyph. Menu: Open Settings, Activate Now, Deactivate, Test (10s), Quit. Icon tints red when active, template when idle. |
| `CurtainIcon.swift` | Draws the curtains logo in code using `NSBezierPath`. Produces a menu-bar template image and a full-color `.iconset` of PNGs. Renders into an offscreen `NSBitmapImageRep` (`NSImage(flipped:)` hangs headless). |
| `LoginItem.swift` | Thin wrapper over `SMAppService.mainApp`. Registers or unregisters the app as a login item. Only works for an installed bundle. |

### `Sources/CurtainShared/`

| File | Role |
|---|---|
| `DisconnectXPC.swift` | The `@objc` protocol shared between the app and the helper. Defines the single privileged operation: end the active Screen Sharing session. |

### `Sources/CurtainHelper/`

The privileged disconnect daemon. Registered optionally via `SMAppService.daemon`, it vends the `DisconnectXPC` service over XPC and performs the session termination as root. No sudoers rule, no shell helper on disk.

## Key macOS APIs

### Session detection: three signals

Three independent signals each independently activate the curtain. The first that fires is enough.

**Signal 1 — `CGSSessionScreenIsCaptured` (primary)**

```swift
let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
let captured = dict?["CGSSessionScreenIsCaptured"] as? Bool ?? false
let onConsole = dict?["kCGSSessionOnConsoleKey"] as? Bool ?? false
```

Transport-independent. Reports true for classic Screen Sharing (TCP) and for the macOS 14+ high-performance mode (UDP, Apple Silicon). Combined with the on-console key, it also distinguishes a local-console capture from a different-user virtual session.

**Signal 2 — ESTABLISHED TCP on port 5900**

A genuinely established inbound TCP connection on port 5900 catches a classic session in the window before the capture flag settles. A `:5900` LISTEN socket (idle machine waiting for connections) does not activate.

**Signal 3 — Peered UDP on ports 5900-5902**

macOS 14+ High-Performance Screen Sharing on Apple Silicon uses UDP. The corroborating signal is a bound, peered UDP socket on ports 5900-5902. A wildcard or LISTEN-state UDP socket does not activate.

Probe helpers (`/usr/sbin/netstat`, not `/usr/bin/netstat` — the latter does not exist on macOS) log launch failures loudly so a misconfigured path is immediately visible in the system log rather than silently returning no results. Process presence (`ScreenSharingAgent`, `ScreenSharingSubscriber`, `screensharingd`) is checked but never activates the curtain on its own.

The combined signal is debounced over 3 consecutive misses (~6 seconds) before declaring the session gone.

Idle time comes from the event system. The source is configurable in Settings (see [Settings — On Session Idle](Settings#on-session-idle)):

```swift
// "Remote session activity" (default)
CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)

// "This Mac's physical input only"
CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
```

### Physical vs remote input: `CGEventTap` + `eventSourceStateID`

```swift
CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,        // active — can block by returning nil
    eventsOfInterest: <keyDown/keyUp/flagsChanged + all mouse + scroll + systemDefined>,
    callback: ...,
    userInfo: ...
)
```

Inside the callback:

```swift
let physical = (event.getIntegerValueField(.eventSourceStateID) == 1)
if physical { return nil }                           // block desk input
return Unmanaged.passUnretained(event)               // pass remote input
```

Physical source ID `1` is `kCGEventSourceStateHIDSystemState`. Remote events carry a large, per-session ID that is never `1`. The mask includes `.systemDefined` so media and brightness keys from the desk are masked too. The tap re-enables itself on `.tapDisabledByTimeout` and `.tapDisabledByUserInput`, and retries creation once Accessibility is granted. This is a convenience filter to keep desk input out of your session, not a hardened security boundary.

### Cover windows: per-display, keyed by UUID

Windows are keyed by `CGDisplayCreateUUIDFromDisplayID`, because identical monitors report serial `0` and cannot be told apart by serial alone. The set rebuilds on `NSApplication.didChangeScreenParametersNotification`, so hotplug, resolution change, and display rearrangement mid-session all keep every panel covered.

- `sharingType = .none`: excluded from screen capture. Opaque at the desk, invisible to the remote. Used for native displays.
- `sharingType = .readOnly`: included in capture. Visible to the remote. Required for DisplayLink displays, which only exist through screen capture.
- **KVM-excluded (no cover window at all)**: a third category, distinct from the two `sharingType` values above (T-P1-E13-01). `sharingType` is a ScreenCaptureKit/Screen-Sharing concept — it only changes what a *remote capture consumer* sees. A hardware KVM (e.g. a TinyPilot) taps the raw HDMI signal off the physical port, upstream of any macOS capture API entirely, so a cover window of either sharingType still physically occupies that display's framebuffer and is visible to the KVM operator regardless of which value is set. The only correct behavior for a display identity designated as a KVM's dedicated headless output is to never construct a cover window for it at all. `Settings.kvmExcludedDisplayUUIDs` holds the excluded UUIDs (same storage shape as the per-display Cover-disabled list); `CurtainController.shouldCover(uuid:isNew:)` checks it first, unconditionally, before any cover-scope or new-display-policy logic — for both first attach and mid-session arrival. If a display is added to this list while its cover is already showing, `reconcile()`'s survivor loop tears the cover down on the next pass, reusing the identical teardown used for a vanished display (`teardownAerialLayer` + `orderOut` + removal from the covers map) — not a partial cleanup, and not merely a `sharingType` change. This exclusion is permanent and identity-driven only; no runtime "is a KVM session currently active" detection exists or is planned, since a passive HDMI capture dongle gives no observable in-use signal to key such detection on even if it were wanted.

Cover appearance is configurable: solid color, a message, a blur, or the logo, with an optional clock. When the aerial video style is selected, one shared `AVPlayer` decoder services all cover windows rather than one decoder per display. Windows are `ignoresMouseEvents = true` and `canBecomeKey = false`, so they never interfere with the remote cursor or steal focus. A `ScreenCaptureKit` self-test verifies that `.none` covers are excluded from capture.

Cover scope is a two-mode setting: **All displays** (default, fail-safe) or **Per-display Cover toggles** (each display's Cover switch in Settings determines whether it is covered). An unknown or newly attached display is covered under both modes — unless it is on the KVM-exclusion list above, which overrides cover scope entirely.

### Optional KVM-activity notification (T-P1-E13-03)

Separate from — and with **zero effect on** — the covering decision above: an optional, off-by-default "the KVM operator is active right now" banner, purely for situational awareness at the desk. Its data source is `KVMInputFilter`'s (T-P1-E13-02) matched-device handling: `evaluate(device:)` already has a branch that recognizes "this HID device is the registered KVM, leave it alone"; a new read-only closure property, `onMatchedDeviceActivity`, fires alongside that existing early-return with no other change to the method. `KVMActivityNotifier.attach(to:)` subscribes to that hook and, when `Settings.kvmActivityNotificationEnabled` is on (off by default, following the same fail-safe-default convention as `disconnectFeatureEnabled`), calls the existing `Notifier.post(...)` throttled-banner mechanism (60-second throttle window) — no new notification infrastructure.

The zero-coupling guarantee is structural, not conventional: `CurtainController.shouldCover(uuid:isNew:)` reads only `Settings.kvmExcludedDisplayUUIDs` (and `coverScope`/`newDisplayPolicy`/`perDisplayCoverDisabled`) — it has no reference to `KVMActivityNotifier`, `KVMInputFilter.onMatchedDeviceActivity`, or `Settings.kvmActivityNotificationEnabled` anywhere in its call graph. A dedicated regression test (`KVMActivityNotifierTests.testShouldCover_zeroCoupling_acrossEnabledDisabledAndFailingObserverStates`) exercises a real `shouldCover()` call against a KVM-excluded display's UUID with the notification feature enabled-and-firing, disabled, and backed by a misbehaving/no-op observer, and asserts the result is identical (`false`) in all three states. Whether this feature ships, works, is enabled, or is disabled has no bearing on which displays get a cover window.

**Not yet live in production.** Nothing in `SessionCoordinator`/`AppDelegate` constructs a `KVMInputFilter` or a `KVMActivityNotifier` yet — `KVMInputFilter` (T-P1-E13-02) has no production owner either, since no ticket has wired its `activate()`/`deactivate()` into a real "entering/leaving the KVM context" trigger, and inventing that lifecycle decision is out of this ticket's scope. The Preferences toggle correctly persists `Settings.kvmActivityNotificationEnabled`, and the Preferences UI discloses this gap directly ("Not yet active..."), but flipping it has no observable effect until a later ticket constructs both pieces together and calls `attach(to:)`.

### Screen lock: `SACLockScreenImmediate`

`CGSession -suspend` was removed from recent macOS. `osascript` Ctrl+Cmd+Q needs Accessibility and a GUI context. `SACLockScreenImmediate` is a private symbol in `login.framework`:

```swift
dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
dlsym(handle, "SACLockScreenImmediate")
```

Locks immediately, no extra permission, works from a background agent. Falls back to a scripted lock if the symbol is unavailable.

### Display-sleep prevention: `IOPMAssertion`

```swift
IOPMAssertionCreateWithName(
    kIOPMAssertionTypeNoDisplaySleep as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "Curtain active" as CFString,
    &assertionID
)
```

Held for the duration of a session. Released explicitly on deactivate. In-process, so it goes away if the process exits. No orphaned PIDs. After locking, displays are slept via the same path that `pmset displaysleepnow` would trigger.

### Session termination: `SMAppService.daemon` + XPC

```swift
SMAppService.daemon(plistName: "com.acamarata.curtain.helper.plist").register()
```

The optional disconnect daemon (`CurtainHelper`) vends the `DisconnectXPC` service. The app calls it through `DisconnectClient` to end the active session as root. No sudoers rule and no shell helper on disk. If the daemon is not installed, disconnect actions are simply unavailable.

### Login item: `SMAppService.mainApp`

```swift
SMAppService.mainApp.register()    // open at login
SMAppService.mainApp.unregister()  // remove from login items
```

Modern API, macOS 13+. Requires an installed app bundle. No LaunchAgent plist.

### Settings: `UserDefaults` + `@AppStorage`

`Settings.swift` defines `Key` constants as static strings. The coordinator reads preferences via typed accessors (`Settings.onIdle`, `Settings.idleMinutes`, etc.). The SwiftUI view binds to the same keys via `@AppStorage(Settings.Key.xxx)`. Changes in the view are immediately visible to the coordinator.

### Icon rendering: offscreen `NSBitmapImageRep`

The app icon is drawn in code and exported as a PNG at each required size. `NSImage(flipped:)` hangs when called from a headless process (the `--render-icon` build step). Instead, `CurtainIcon` renders into an `NSBitmapImageRep` directly, which works in any context.

### Crash-recovery heartbeat file (T-P1-E10-01)

`SessionMonitor` ticks every ~2s via a main-thread `Timer` (`start()`/`tick()`, `pollInterval = 2`). That tick is proof the process's runloop is alive, but `launchctl list`/`ps` can only confirm a PID exists — they cannot tell you whether the Timer is actually still firing, whether the probe queue has wedged, or whether `SessionCoordinator`'s state machine has locked up while the process itself never crashes. A hung-but-still-running Curtain is worse than a crashed one: a crash is at least visible (no menu-bar icon, no PID), while a hang leaves every external signal saying "it's fine" while the privacy guarantee has silently stopped being enforced.

**Path:** `~/Library/Application Support/Curtain/heartbeat.json` — the same Application Support root already used by `CrashSignalHandler`'s `last-crash.log` marker.

**Format:** a JSON object with exactly five fields:

| Field | Type | Meaning |
|---|---|---|
| `timestamp` | String, ISO 8601 UTC (`ISO8601DateFormatter`, `.withInternetDateTime`) | Wall-clock time of the write, e.g. `"2026-08-15T17:45:21Z"` |
| `armed` | Bool | `Settings.armed` at tick time |
| `connected` | Bool | `SessionMonitor`'s own `connected` var |
| `idleArmed` | Bool | `SessionMonitor`'s own `idleArmed` var |
| `idleFired` | Bool | `SessionMonitor`'s own `idleFired` var |

**Cadence:** written once per tick (~2s), at the end of `apply(signals:idle:)` — after state is updated, so the file always reflects post-tick state, never a stale pre-update snapshot. Overwritten in place via `Data.write(to:options:.atomic)`, never appended, so it cannot grow unbounded over weeks of uptime.

**Write path:** a plain value-type snapshot (`HeartbeatSnapshot`) is captured on the main actor first — nothing `@MainActor`-isolated crosses the queue hop — then JSON-encoded and written on `probeQueue`, the same background queue `tick()` already uses for its shell-out probe work, so the write never blocks the 2s tick cadence. Directory creation (`FileManager.createDirectory(withIntermediateDirectories: true)`) and the write itself are both wrapped in a `do`/`catch` that silently drops any error (disk full, permission race, sandbox denial) — a failed heartbeat write must never crash the tick loop, since that would be a strictly worse regression than the liveness gap this file closes.

**Consumer contract:** this file is the intended read-dependency for the future E-14 `curtain_status` MCP tool, which should read this file directly rather than re-implementing liveness detection. Do not rename or remove any of the five fields above without updating that tool. An external reader determines liveness by checking `timestamp` recency (a stale timestamp past a few tick intervals means the Timer/probe queue has wedged even though the process is still running) and determines correctness by comparing `armed`/`connected`/`idleArmed`/`idleFired` against the expected state for the situation. JSON key order is not guaranteed (`JSONEncoder`'s default output order can vary) — any consumer must parse by field name, not positionally.

### Mid-session Accessibility re-check (T-P1-E10-02)

`AXIsProcessTrusted()` is checked at two activation-time gates — `SessionCoordinator.enterActive(notify:requireAX:)` and `setArmed(_:)` — but neither runs again once a cover is already up. If Accessibility is revoked while `state == .active` (direct user action in System Settings, or a signature change breaking the binary's TCC grant, which affects local ad-hoc rebuilds and the one-time move from ad-hoc to Developer ID in v2.0.3), `InputFilter`'s event tap goes dead while the cover stays visually up: the desk silently stops being blocked.

`SessionCoordinator` closes this gap by piggybacking on its existing 1s `tickTimer` (the same timer that drives `CurtainController.tick()`/`PasswordBox` auto-hide) rather than starting a second Timer — `AXIsProcessTrusted()` is a fast TCC lookup, cheap enough to call every tick. The re-check only runs while `state == .active`; the two activation-time gates already cover the idle case. A private `lastKnownAXTrusted` latch makes the check edge-triggered (mirrors `SessionMonitor`'s `signals != lastSignals` pattern), so a sustained revocation doesn't spam the log or repeatedly re-fire the banner's VoiceOver announcement:

- **Revoked** (`true -> false`): `Log.error("accessibility revoked mid-session...")` (always-visible, matching the severity of the activation-time refusal logs), then `CurtainController.setInputBlocked(false)` — which already drives every active cover's existing `CoverContentView` warning banner ("Desk input not blocked — grant Accessibility in System Settings"). No new UI was added; this reuses the banner mechanism already wired for the activation-time case.
- **Re-granted** (`false -> true`): `Log.event(...)` (routine, not an error) then `CurtainController.setInputBlocked(true)`, clearing the banner.

The latch resets to `nil` in `enterIdle()` so each new session starts with a clean baseline rather than comparing against a stale reading from a previous session's last check. This is an orthogonal, always-needed defense — it does not depend on or change the activation-time (`enterActive`) or arm-time (`setArmed`) Accessibility gates, and remains relevant even after T-P1-E02's notarization work removes the signing-instability trigger, since a user or admin profile can revoke Accessibility directly at any time.

### Hard-kill persistence + away-for-months verification (T-P1-E10-03)

E-10's framing: "Curtain is protecting me" must always be either true, or loudly and visibly false — never silently false. This section documents two things verified for real, not just read from source: that a `kill -9` mid-session cannot silently revert `armed` (or any other setting) to a stale value on relaunch, and how far Curtain's software-only guarantees reach when the user is away for an extended period.

**Hard-kill persistence — verified on-device, not just by code inspection.** Every `Settings` accessor (`Settings.swift`) is a plain computed property over `UserDefaults.standard` — `get { d.bool(forKey:) }` / `set { d.set(newValue, forKey:) }` — with no caching layer, no batching, and no flush-on-quit step. `SessionCoordinator.setArmed(_:)` (~line 362) writes `Settings.armed = on` synchronously on every arm/disarm; there is no code path that stages the value in memory first. This was proven with a real `kill -9` against the built `Curtain.app`, not simulated:

1. Launched the real `dist/Curtain.app/Contents/MacOS/Curtain` binary as a background process and confirmed its PID.
2. While it was running, wrote `armed = false` plus `idle.minutes = 91` and `cover.style = "aerial"` via `defaults write io.acamarata.curtain ...` — the same `CFPreferences`-backed path `Settings`'s setters use, from a value opposite the registered default so a no-op write couldn't masquerade as success.
3. Confirmed the process was still alive (write did not crash it), then `kill -9 <pid>` and confirmed the process was actually dead (`kill -0` failed).
4. Relaunched the same binary fresh and read `~/Library/Application Support/Curtain/heartbeat.json` (T-P1-E10-01's liveness file, written by the app's own in-process `Settings.armed` read at first tick) — `armed: false` matched exactly, and `idle.minutes`/`cover.style` (read via `defaults read`) also matched. Repeated in the opposite direction (`armed = true` from a `false` starting point, alongside different `idle.minutes`/`cover.style` values) to rule out the registered default masking a real bug in either direction.

No gap was found — this is genuinely the "already true by construction" case the ticket anticipated. `Tests/CurtainCoreTests/SettingsHardKillPersistenceTests.swift` captures this as an automated regression: it writes through `Settings`'s real setters (and through `SessionCoordinator.setArmed`) into an isolated `UserDefaults(suiteName:)` (the existing T-P1-E05-03 seam), then reads back through a **second, independent** `UserDefaults` instance constructed against the same suite name — never the handle `Settings` itself holds — so a future regression that introduced in-memory staging would fail this test even though it can't spawn/kill a real process in CI.

**Unattended-reboot relaunch.** Two independent, non-overlapping mechanisms cover "Curtain comes back after the process goes away":

- **Crash / `kill -9` mid-session:** `AppSupervisor` registers a separate `SMAppService.agent` (`io.acamarata.curtain.supervisor.plist`) with `KeepAlive.SuccessfulExit = false` and `RunAtLoad` deliberately omitted — launchd relaunches Curtain itself, immediately, only when the prior exit was not clean (status 0). This is what would catch a real `kill -9` on a live system in seconds, not on next login.
- **Reboot:** `LoginItem` registers `SMAppService.mainApp`, which launches Curtain at the next login — the mechanism a macOS-security-update-triggered restart relies on.

Verified: force-quit (`SIGTERM`, not `kill -9`, to exercise the documented clean-shutdown path) the running `dist/Curtain.app`, confirmed it exited, relaunched the same binary, and confirmed `heartbeat.json`'s `timestamp` resumed advancing across ticks within ~2s of relaunch — the monitor's tick loop comes back cleanly with no stale state. This simulates "does it come back and resume working," not the full OS reboot path itself (no fast-forward seam for an actual restart exists in this environment); the login-item and supervisor registrations themselves were confirmed by reading `LoginItem.swift`/`AppSupervisor.swift` rather than by rebooting this Mac.

**The FileVault/KVM boundary — explicitly out of this ticket's fix scope.** If the Mac reboots (e.g. an automatic macOS security update) while the user is away, and FileVault's pre-boot full-disk-encryption login is required, Curtain cannot run — no process runs at all — between the reboot and the pre-boot unlock, no matter how the login item or supervisor is configured. This is a firmware/EFI-level gate that exists before macOS itself, let alone any user-space LaunchAgent, ever starts. **This is not a gap this ticket fixes**, and it is not attempted here: it is the documented, correct boundary between E-10 (this epic, software-only reliability) and the KVM Bridge epics (E-11 through E-13), which exist specifically to cover the physical-hardware path a software agent structurally cannot reach. Once past pre-boot unlock and into a logged-in session, the login item takes over exactly as described above.

**Multi-week idle-drift review.** Reviewed for state that could accumulate or desync over weeks of continuous unattended uptime, beyond the existing 30-minute idle-timeout window:

- **Menu-bar state (`MenuBarController`):** `lastActive`/`lastArmed` are two plain `Bool`s, always overwritten (never accumulated) by `reflect(active:)`/`reflect(armed:)`, which are driven exclusively by `SessionCoordinator.onStateChange`/`onArmedChange` callbacks — there is no independent polling or cached copy that could drift from the coordinator's actual state. `show()` also re-syncs both from the coordinator's live `isActive`/`isArmed` the moment the status item is created, so even a rebuild of the menu bar itself can't reintroduce a stale read.
- **Cached session flags outside `UserDefaults`:** `SessionCoordinator`'s only non-persisted state (`state`, `currentEpisodeID`, `lastKnownAXTrusted`, `tickTimer`, `connectGrace`/`testTeardown` work items) are all simple scalars/optionals that reset to a clean baseline on every fresh launch and are reassigned (never appended to) during a run — none of them is a collection that can grow. This is correct, not a gap: a freshly-launched process should start idle rather than resume a "session" from a process that no longer exists.
- **heartbeat.json growth:** re-verified independently of T-P1-E10-01's own claim (not just trusted) by reading `SessionMonitor.writeHeartbeatFile` directly — it writes via `Data.write(to:options:.atomic)`, which replaces the file's contents in place rather than appending, and `Tests/CurtainCoreTests/SessionMonitorHeartbeatTests.swift`'s `testHeartbeatOverwritesRatherThanAppends` already asserts file size stays roughly constant across multiple tick cycles. No growth risk found.
- **`Log.event`/`Log.error`:** both are thin wrappers over `os.Logger` (`Log.swift`) — there is no app-managed log file on disk at all. Log retention/rotation is entirely macOS's unified logging system's responsibility (its own system-wide size/age-based purging), not something Curtain's own code could leak or grow unbounded.

No concrete defensive gap was found in this review. One risk cannot be substantiated without literal weeks of continuous wall-clock runtime: a slow memory leak or resource exhaustion (file descriptors, timers) that only manifests after sustained uptime is not something a short-duration test can rule out. **Documented plainly rather than fabricated a fix for**: the monitoring signal already exists — `heartbeat.json`'s `timestamp` field. If it goes stale (no update for more than a few multiples of the 2s tick interval — e.g. flagged past 30-60s) while the process still shows up in `ps`, that is the concrete, actionable signal that the tick loop has wedged, exactly the scenario T-P1-E10-01 built this file to catch. The future E-14 `curtain_status` MCP tool is the intended consumer of that staleness check.

**Explicitly out of scope, not re-tested here:** rapid connect/disconnect cycling. `SessionMonitor`'s 3-signal detection (`CGSSessionScreenIsCaptured`, ESTABLISHED TCP on 5900, peered UDP on 5900-5902) plus its debounce (`missLimit = 3` at the ~2s poll interval, ~6s total) was confirmed handled during this epic's planning session; re-testing it is outside this ticket's scope per its `out_of_scope` list.

## Data flow: connect through end

```
1. CaptureProbe: CGSSessionScreenIsCaptured == true, on console
   (corroborated by ScreenSharingAgent/Subscriber/screensharingd + widened netstat)
        |
        v
2. SessionCoordinator: idle -> active
   ActionRunner.activateCover():
     - CurtainController.show()           per-display covers, keyed by UUID
     - System.preventDisplaySleep()       IOPMAssertion held
     - InputFilter.start()                CGEventTap installed (retries on grant)
        |
        v
3. Session active.
   Physical input (incl. media/brightness keys) blocked at tap. Remote input passes.
   Physical keyDown -> InputFilter.onPhysicalKey -> CurtainController.physicalKey -> PasswordBox (on chosen display)
   Every tick: SessionCoordinator re-verifies AXIsProcessTrusted() (edge-triggered;
     see "Mid-session Accessibility re-check" above) -> CurtainController.setInputBlocked(_:)
        |
        +-- Correct password (coordinator: active -> unlocking)
        |     ActionRunner.deactivateCover()
        |       - InputFilter.stop()
        |       - CurtainController.hide()
        |       - System.allowDisplaySleep()
        |     Optional disconnect -> DisconnectClient -> CurtainHelper (XPC, root)
        |
        +-- Idle timeout (SessionMonitor, CGEventSource idle)
        |     ActionRunner.run(Settings.onIdle):
        |       DisconnectClient.disconnect()  (if daemon installed)
        |       CurtainController.hide() + InputFilter.stop()
        |       System.lockScreen()
        |       System.sleepDisplays()   (after 1s delay)
        |
        +-- Disconnect (3 consecutive misses of the combined signal)
              ActionRunner.run(Settings.onEnd):
                CurtainController.hide() + InputFilter.stop()
                System.lockScreen()
                System.sleepDisplays()  (after 1s delay)
```

Actions within each `ActionSet` run in a fixed order: disconnect first (so the operator is gone before the screen changes), then deactivate the curtain, then lock, then sleep the displays last so the lock is in place before the panels go dark.
