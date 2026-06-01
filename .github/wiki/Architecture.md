# Architecture

## File and module overview

| File | Type | Responsibility |
|---|---|---|
| `main.swift` | Entry point | Creates `NSApplication`, sets `AppDelegate` as delegate, runs the run loop. |
| `AppDelegate.swift` | Coordinator | Wires the three subsystems together, owns the menu-bar item, handles lifecycle events (connect, disconnect, idle, password unlock). |
| `SessionMonitor.swift` | Detector | Polls for an active Screen Sharing connection and tracks idle time. Fires `onConnect`, `onDisconnect`, `onIdleTimeout` callbacks. |
| `InputFilter.swift` | Input blocker | Installs and manages a `CGEventTap`. Blocks physical hardware events; passes remote events. Routes physical key-downs to the password box. |
| `Curtain.swift` | Cover + password UI | Creates and manages the full-screen cover windows and the password box overlay. |
| `System.swift` | System calls | Thin wrappers over screen lock, display sleep, display-sleep prevention, session termination, and display serial lookup. |
| `Config.swift` | Persistent settings | Reads and writes `~/Library/Application Support/Curtain/config.json`. Stores enabled state, salted password hash, DisplayLink serials, idle timeout. |

## Key macOS APIs

### Session detection

`SessionMonitor` runs a two-second timer and shells out to check for an established VNC connection:

```
netstat -an | grep '.5900 ' | grep ESTABLISHED
```

`lsof` does not work here — Screen Sharing sockets are owned by the `_rmd` system account and are invisible to user-context `lsof`.

Idle time comes from IOKit:

```
ioreg -c IOHIDSystem  =>  HIDIdleTime  (nanoseconds)
```

### Physical vs remote input (`CGEventTap`)

`InputFilter` creates the tap with:

```swift
CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,        // active tap — can block events
    eventsOfInterest: <mask covering keyDown/keyUp/flagsChanged + all mouse + scroll>,
    callback: ...,
    userInfo: ...
)
```

Inside the callback, each event is classified by source:

```swift
let physical = (event.getIntegerValueField(.eventSourceStateID) == 1)
```

- Source state ID `1` = physical hardware (`kCGEventSourceStateHIDSystemState`). Block it (return `nil`).
- Any other ID = Screen Sharing injected. Pass it (return `Unmanaged.passUnretained(event)`).

The tap handles `.tapDisabledByTimeout` and `.tapDisabledByUserInput` by re-enabling itself.

### Cover window (`NSWindow.sharingType`)

The curtain window on each display is borderless, opaque, level `CGWindowLevelForKey(.maximumWindow)`, with:

- `ignoresMouseEvents = true` — never intercepts remote cursor.
- `canBecomeKey = false` — never steals keyboard focus.

For native displays: `sharingType = .none`. The window is excluded from screen capture, so the remote operator sees the real desktop behind it.

For DisplayLink displays: `sharingType = .readOnly`. The window is visible to screen capture, which is required because DisplayLink monitors only exist through screen capture.

### Screen lock (`SACLockScreenImmediate`)

`CGSession -suspend` was removed in recent macOS. `osascript` for Ctrl+Cmd+Q requires Accessibility and is unreliable from a LaunchAgent context. Curtain uses a private symbol in `login.framework`:

```swift
dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
dlsym(handle, "SACLockScreenImmediate")
```

This locks immediately with no additional permission and no GUI context requirement.

### Display sleep prevention (`IOPMAssertion`)

While a session is active, Curtain holds an IOKit power assertion to keep the displays on:

```swift
IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, ..., "Curtain active", &assertionID)
```

The assertion is released when the session ends. Using an in-process assertion avoids the PID-tracking issues that come with external `caffeinate` processes.

### Session termination (root helper)

The Screen Sharing connection is owned by `_rmd`/root. A user process cannot kill it. `install.sh` places `/usr/local/bin/curtain-endsession` and adds a NOPASSWD sudoers rule:

```
/etc/sudoers.d/curtain-endsession
```

The app calls:

```swift
Process() { launchPath = "/usr/bin/sudo"; arguments = ["-n", "/usr/local/bin/curtain-endsession"] }
```

macOS respawns the Screen Sharing listener automatically after the helper kills the session processes.

## Data flow: connect to end

```
1. SessionMonitor detects ESTABLISHED on :5900
        |
        v
2. AppDelegate.sessionStarted()
   - CurtainController.show()       => black cover windows appear on all displays
   - System.preventDisplaySleep()   => IOPMAssertion held
   - InputFilter.start()            => CGEventTap installed
        |
        v
3. Remote operator works normally. Physical input is dropped at the tap.
   Physical key-downs forwarded to PasswordBox via onPhysicalKey callback.
        |
        +-- Password correct
        |       => InputFilter.stop() + CurtainController.hide()
        |       => System.allowDisplaySleep()
        |       => Alert: "Disconnect remote?" => System.endScreenShareSession()
        |
        +-- Idle timeout fires (SessionMonitor)
        |       => System.endScreenShareSession()
        |       => sessionEnded(lock: true)
        |
        +-- Remote disconnects (SessionMonitor: 3 consecutive netstat misses)
                => sessionEnded(lock: true)
                        |
                        v
4. AppDelegate.sessionEnded(lock: true)
   - InputFilter.stop()             => tap removed
   - CurtainController.hide()       => cover windows removed
   - System.allowDisplaySleep()     => assertion released
   - System.lockScreen()            => SACLockScreenImmediate called
   - System.sleepDisplays()         => pmset displaysleepnow (after 1s delay)
```

## Configuration storage

`~/Library/Application Support/Curtain/config.json`:

| Field | Type | Default | Notes |
|---|---|---|---|
| `enabled` | bool | `true` | When false, no curtain shows on connect. |
| `passwordHash` | string | `""` | Salted SHA-256. Empty means use default password `curtain`. |
| `salt` | string | random | Per-install 16-byte hex salt. |
| `displayLinkSerials` | `[UInt32]` | `[]` | Serials of DisplayLink displays. |
| `idleMinutes` | int | `30` | Minutes of HID idle before forced disconnect + lock. |
