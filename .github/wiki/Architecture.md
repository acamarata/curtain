# Architecture

## Module overview

All app source lives in `Sources/Curtain/`. A shared target `Sources/CurtainShared/` holds the XPC contract, and a second executable `Sources/CurtainHelper/` is the privileged disconnect daemon. Each file has a single responsibility.

### `Sources/Curtain/`

| File | Role |
|---|---|
| `main.swift` | Entry point. Sets `NSApplication` activation policy to `.accessory` (no Dock icon). Contains a hidden `--render-icon <dir>` build helper used by the release script to generate the app icon without shipping image assets. |
| `AppDelegate.swift` | Wires all pieces together. No logic of its own: it connects callbacks between the coordinator, the menu bar, and the settings window. Registers defaults, reconciles the login item state, and shows onboarding on first launch. |
| `SessionCoordinator.swift` | The brain. An explicit state machine (idle, active, unlocking) that owns the curtain, the input filter, and the monitor. Responds to connect/idle/end/password events and drives `ActionRunner`. Exposes `activateNow`, `deactivateNow`, and `testCurtain` for manual control. |
| `SessionMonitor.swift` | Combines the capture probe, process presence, and netstat into one connect/disconnect signal. Reads idle time. Fires `onConnect`, `onIdleTimeout`, and `onDisconnect`. Disconnect is debounced over 3 consecutive misses of the combined signal. |
| `CaptureProbe.swift` | The detection primitive. Reads `CGSessionScreenIsCaptured` from `CGSessionCopyCurrentDictionary()`. Transport-independent: true whether the remote streams over TCP or UDP. Also reports whether the captured session is the local console (curtain applies) or a different user's virtual session (Curtain stands down). |
| `InputFilter.swift` | Installs a `CGEventTap` covering keyboard, mouse, scroll, and `.systemDefined` (media and brightness keys) events. Blocks physical events (`sourceStateID == 1`), passes remote events. Routes physical `keyDown` events to `onPhysicalKey`. Re-enables the tap on timeout/disable, and retries automatically once Accessibility is granted. A convenience filter, not a security boundary. |
| `CurtainController.swift` | Manages the set of per-display cover windows (replaces the cover-management code that was in `Curtain.swift`). Creates, reconciles, and destroys `CoverWindow` instances keyed by display UUID. Handles hotplug via `didChangeScreenParametersNotification`. |
| `CoverContentView.swift` | SwiftUI view rendered inside each cover window. Draws the chosen cover style: solid, message, blur, logo, or aerial video. One shared `AVPlayer` decoder services all displays when the aerial style is active. |
| `PasswordBox.swift` | The on-curtain password entry UI. Appears on a chosen display when a physical key is pressed. Manages timeout, attempt backoff, and routing the result to the coordinator. |
| `Actions.swift` | `ActionSet` struct (activateCurtain, disconnect, lock, screenOff, deactivateCurtain) and `ActionRunner` that executes a set in a defined order: disconnect first, deactivate, lock, then sleep displays last. |
| `System.swift` | Thin wrappers: `lockScreen` (SACLockScreenImmediate via dlopen/dlsym + fallback), `sleepDisplays`, `preventDisplaySleep`/`allowDisplaySleep` (IOPMAssertion), display UUID/serial helpers, `isDisplayLink(_:)`. |
| `DisconnectClient.swift` | Client side of the disconnect XPC. Talks to `CurtainHelper` over the shared `DisconnectXPC` protocol when the optional disconnect daemon is installed. |
| `Settings.swift` | All preferences backed by `UserDefaults`. Defines `Key` constants shared with `@AppStorage`. Typed accessors for the coordinator. Password stored as a salted PBKDF2-HMAC-SHA256 hash. Default password `curtain` when no hash is set. |
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

Cover appearance is configurable: solid color, a message, a blur, or the logo, with an optional clock. When the aerial video style is selected, one shared `AVPlayer` decoder services all cover windows rather than one decoder per display. Windows are `ignoresMouseEvents = true` and `canBecomeKey = false`, so they never interfere with the remote cursor or steal focus. A `ScreenCaptureKit` self-test verifies that `.none` covers are excluded from capture.

Cover scope is a two-mode setting: **All displays** (default, fail-safe) or **Per-display Cover toggles** (each display's Cover switch in Settings determines whether it is covered). An unknown or newly attached display is covered under both modes.

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
