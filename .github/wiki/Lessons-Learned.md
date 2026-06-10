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
/usr/sbin/netstat -an | grep '.5900 ' | grep ESTABLISHED
```

`netstat` does not filter by process owner and sees all connections.

**Debounce disconnect:** a single missed netstat poll is not a real disconnect. Without debouncing, a transient network blip fires a false disconnect that kills a live session. The fix is to require three consecutive misses (~6 seconds at a 2-second poll interval) before treating it as a real disconnect.

## Probe tool paths must be verified on-device

`netstat` on macOS lives at `/usr/sbin/netstat`. There is no `/usr/bin/netstat`. A probe subprocess launched with the wrong absolute path fails silently: the process exits immediately with "no such file", the parser receives empty output, the probe returns zero results, and the detector never fires. No error surfaces anywhere unless the launch failure is logged explicitly.

The lesson: when shelling out to a system tool, use its verified on-device path, not a guessed or Unix-conventional one. Verify with `which netstat` or `xcrun -f netstat` on the actual target hardware before writing the path in code. Probe helpers must log launch failures loudly (path, error code) so a misconfigured path is visible in Console.app immediately rather than silently producing no detections.

This is the same class of bug as the `lsof` failure: a unit-tested parser that looked correct in isolation, fed by a subprocess that was silently dead.

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
- **`/usr/bin/netstat`.** Does not exist on macOS. Use `/usr/sbin/netstat`.
- **Three-mode cover scope (onlyMarked / allExceptMarked / all).** The "only marked" and "all except marked" modes were logically inverted in parts of the code, and the distinction confused settings. Replaced with a two-mode model: all displays, or per-display Cover toggles.

## v1.0 hardening (2026-06-02)

The v1.0 pass replaced or corrected several detection and distribution choices that did not survive contact with current macOS.

### netstat:5900 was not a reliable session signal, and the probe path was wrong

The `netstat | grep .5900 | grep ESTABLISHED` detector silently failed in two independent ways:

1. On macOS Sequoia, high-performance Screen Sharing moved to a UDP transport. There is no `ESTABLISHED` TCP state to match and the detector saw nothing, so the curtain never activated.
2. The probe helper was launched with the path `/usr/bin/netstat`, which does not exist on macOS. The real path is `/usr/sbin/netstat`. The launch failed silently every time. The unit-tested parser was correct, but the subprocess feeding it was dead. The ESTABLISHED-TCP activator was entirely non-functional until this was fixed.

Both were silent failures. No error was logged, no signal reached the detector.

The fixes: use `CGSessionScreenIsCaptured` as the primary signal (transport-independent, covers classic TCP and high-performance UDP); keep the TCP-ESTABLISHED and peered-UDP probes as secondary signals with the correct `/usr/sbin/netstat` path; and log every probe launch failure loudly so a path regression is visible immediately.

### The event-source filter is convenience, not security

The input split classifies events by `sourceStateID == 1` (physical HID). This is documented honestly as a convenience filter, not a security boundary. `sourceStateID` is spoofable by local code: a process running on the machine can inject events that claim any source ID. The filter is the right tool for keeping desk and remote input apart during normal use, but it is not a defense against a hostile local program, and the docs no longer imply otherwise.

### Mid-session display hotplug left monitors uncovered

There was no handler for `didChangeScreenParametersNotification`, so attaching a display during a session left that monitor showing the live desktop. v1.0 listens for that notification and reconciles the cover set on every change, applying the New-display policy (cover by default, fail-safe).

Display identity also moved. `CGDisplaySerialNumber` returns 0 for many monitors, and returns the same value for two identical monitors, so it could not key per-display settings reliably. Identity now uses `CGDisplayCreateUUIDFromDisplayID`, which is stable and unique per monitor across reconnects and reboots.

### Privileged disconnect moved off sudoers

The old approach dropped a root helper at `/usr/local/bin/curtain-endsession` with a NOPASSWD sudoers rule. That is replaced by an optional `SMAppService.daemon` plus an XPC connection, off by default. The user opts in, approves the helper once in System Settings, and the disconnect runs through XPC instead of a shell-out to sudo. Nothing privileged is installed unless the feature is enabled.

### Distribution: ad-hoc for v1.0, notarization next

v1.0 ships ad-hoc signed. Gatekeeper requires a one-time quarantine strip after download before the app will launch. The ad-hoc build also cannot register the `SMAppService.daemon`, which is why disconnect-remote-on-end is unavailable until a notarized or Developer-ID build exists. Notarization is planned and will remove both the quarantine step and the daemon limitation.
