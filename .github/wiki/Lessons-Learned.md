# Lessons Learned

This page records what was discovered building Curtain. The goal is to explain the constraints behind several non-obvious design choices.

## The hard constraint: one shared session

Standard macOS Screen Sharing shares the console session. The remote operator and the person at the desk are looking at the same desktop and using the same input system.

This rules out window-level input separation. There is no such thing as a window that blocks the desk keyboard but not the remote keyboard, because both appear identical at the window level. Several approaches broke against this constraint:

- A click-through cover window (ignores mouse and keyboard): the curtain renders, but desk key presses reach the running apps. Input blocking is not there.
- An input-blocking, key window: desk input is blocked, but so is remote input. Remote control stops working.
- The screensaver: it draws on the real display output, so the remote operator also sees the screensaver and cannot work. And `open -a ScreenSaverEngine` returns 0 on recent macOS but does not reliably run the screensaver from a script context.

The solution is to work at the event tap level, below the window system, and to classify events by their source rather than by the window they target.

## Event source IDs distinguish physical from remote

A `CGEventTap` callback can read each event's source state ID:

```
event.getIntegerValueField(.eventSourceStateID)
```

Physical hardware events consistently report source state ID `1` (`kCGEventSourceStateHIDSystemState`). Screen Sharing injects synthetic events with a large, arbitrary ID that is different for each connection (observed values: 294702567, 1726956429, 336465782).

The rule is: block events where the source ID is `1`; pass everything else. This was verified empirically by typing from the remote (events came with a large ID) and from the desk (events came with ID `1`).

The tap must be created as an active tap (`.defaultTap`, head-insert) so it can block events by returning `nil`. The tap also handles `.tapDisabledByTimeout` and `.tapDisabledByUserInput` by re-enabling itself, because macOS disables a tap that takes too long to respond.

Physical key-downs are routed to the password box through the `onPhysicalKey` callback. The password box reads keystrokes this way because the curtain window is non-key and click-through — normal text input via the responder chain would never reach it.

## Accessibility permission and the app bundle

The event tap requires Accessibility permission. When Curtain runs as a loose process or unsigned binary, the Accessibility grant is unstable — granting it mid-run changed tap behavior between attempts, causing "it worked, then broke" confusion.

The fix: `install.sh` creates a proper app bundle and ad-hoc codesigns it. TCC (the Transparency, Consent, and Control system) grants Accessibility to the bundle identifier, which is stable across relaunches. After granting Accessibility, relaunch via `launchctl kickstart` so the new permission takes effect cleanly.

## Session detection: netstat, not lsof

The first approach used `lsof -i :5900` to detect an active Screen Sharing connection. This returned nothing at all, not even the listener socket. The Screen Sharing processes run under the `_rmd` system account, and their sockets are not visible to a user-context `lsof` call. This silently broke connection detection.

The working approach:

```
netstat -an | grep '.5900 ' | grep ESTABLISHED
```

`netstat` does not filter by process owner and sees all connections.

**Debounce disconnect:** a single missed netstat poll is not a real disconnect. Without debouncing, a transient network blip fires a false disconnect that kills a live session. The fix is to require three consecutive misses (~6 seconds at a 2-second poll interval) before treating it as a real disconnect.

## Screen lock

Three approaches were tried:

| Approach | Result |
|---|---|
| `CGSession -suspend` | Removed in recent macOS. Not available. |
| `osascript` Ctrl+Cmd+Q | Requires Accessibility and a GUI context. Unreliable from a LaunchAgent. |
| `SACLockScreenImmediate` (private symbol in `login.framework`) | Locks immediately. No Accessibility needed. No GUI context needed. Works from a LaunchAgent. |

`SACLockScreenImmediate` is a private API, accessed via `dlopen`/`dlsym`. It is what several other third-party lock tools use. Display sleep after locking uses `pmset displaysleepnow`.

## Preventing display sleep during a session

The initial approach used `caffeinate -d`. The problem: when the Curtain LaunchAgent was reloaded (not just the process), the previous `caffeinate` PID became orphaned and kept the displays awake after the session ended.

The fix is an in-process IOKit assertion:

```swift
IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, ...)
```

The assertion is tied to the process lifetime and is released explicitly when the session ends. No PID tracking needed.

## Ending the remote session needs a root helper

The Screen Sharing connection processes (`screensharingd`, `ScreenSharingSubscriber`) are owned by `_rmd`/root. A user process cannot kill them. `install.sh` solves this by dropping a small helper binary at `/usr/local/bin/curtain-endsession` with a NOPASSWD sudoers rule. The helper calls `pkill` on the session processes. macOS respawns the listener, so Screen Sharing stays available for the next connection.

## DisplayLink monitors and sharingType

`sharingType = .none` on a window excludes it from screen capture. On a native display, this means the curtain is invisible to the remote operator while remaining fully visible at the desk. The remote sees the real desktop.

DisplayLink displays are a special case. They do not have a native framebuffer connection — they exist entirely through screen capture. A window with `sharingType = .none` is excluded from screen capture, which also excludes it from the DisplayLink output. The cover does not appear on the DisplayLink monitor.

For those monitors, `sharingType = .readOnly` is required. The cover is capturable, so the DisplayLink monitor shows it. The trade-off: it also shows in the remote view for those displays.

Identifying DisplayLink displays by USB vendor ID via IOKit is unreliable because EDID passthrough makes all monitors report the same vendor and model strings. The chosen approach is to identify displays by their stable serial number (`CGDisplaySerialNumber`) and let the user mark them manually via the "Mark Current Externals as DisplayLink" menu item.

## Things that did not work

Do not re-attempt these:

- **Click-through cover with no event tap.** Remote works but desk keyboard reaches apps.
- **Input-blocking key window.** Blocks desk and remote both. Unusable.
- **Native screensaver as cover.** Shows on the remote view. Cannot be reliably started via script on recent macOS.
- **Virtual display (same-user) approach.** Depends on macOS version behavior and did not work in the target setup.
- **lsof for session detection.** Returns nothing for Screen Sharing sockets (wrong process owner).
- **CGSession -suspend for lock.** Removed from macOS.
- **caffeinate for display sleep prevention.** Orphaned PIDs kept displays awake after daemon reload.
