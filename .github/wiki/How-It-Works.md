# How It Works

## The hard constraint

When you use macOS Screen Sharing, your laptop and the physical Mac share one login session. There is no separate "remote session" at the OS level. It is the same desktop, the same running apps, the same input system.

That creates a real problem: you cannot put up a window that blocks input from the desk, because that would also block your remote input. And you cannot put up a click-through window (one that ignores the desk), because then desk keyboard and mouse still reach your apps. Several approaches hit this wall. See [Lessons Learned](Lessons-Learned) for the full list.

The solution is to work below the window system. Curtain inspects every input event before any app sees it, and classifies each one by where it came from.

## Physical vs remote input

macOS tags every input event with a source state ID. Events from physical hardware (keyboard, trackpad, mouse) consistently report source state ID `1` (`kCGEventSourceStateHIDSystemState`). Events injected by Screen Sharing carry a large, arbitrary number that is different from `1` and changes with each connection.

Curtain installs a `CGEventTap` at the session level, in head-insert active mode, so it runs before any app sees the event. The rule: if source ID is `1`, the event came from the desk, so return `nil` to block it. Anything else, pass it through. The tap also masks `.systemDefined` events, so the desk cannot reach media or brightness keys.

This is what lets you type and click freely from your laptop while the desk keyboard and mouse do nothing. No virtual display, no second user account. It is a convenience filter that keeps desk input out of your session, not a hardened security boundary, and it depends on the Accessibility grant.

Because the cover is useless without the input block, Curtain refuses to raise the cover at all when Accessibility has not been granted, notifying you instead. And independent of all of this, a Carbon hotkey, **Control + Option + Command + U**, force-deactivates the curtain. Carbon hotkeys do not need Accessibility, so this escape works in every state.

Physical key presses are not simply discarded. When a physical `keyDown` arrives, Curtain reads it and feeds it to the on-curtain password box so the person at the desk can type a password to reclaim the machine.

## The lifecycle

```
Screen Sharing connects (CGSSessionScreenIsCaptured == true, local console)
  |
  +-- Cover windows appear on every physical display
  |     Configurable: solid, message, blur, lock logo, Curtain logo, or aerial video,
  |     with an optional clock (default: lock logo)
  +-- Input tap activates (physical input blocked, remote input passes)
  +-- IOKit display-sleep assertion held (displays stay on for the remote view)
  |
  While connected:
    |
    +-- Reveal trigger at the desk (any key, or a user-defined combo)
    |     Password box appears
    |     Correct password: curtain drops; remote stays connected or disconnects per On Curtain Unlock
    |     Wrong password: box clears, try again
    |     Esc, or no key for the box timeout: box hides
    |
    +-- Emergency hotkey (Control + Option + Command + U)
    |     Force-deactivate the curtain, even without Accessibility
    |
    +-- No physical input for N minutes (idle timeout, default 30 min)
    |     Disconnect remote (via the helper daemon, if installed)
    |     Lock Mac (SACLockScreenImmediate)
    |     Sleep displays
    |     Deactivate curtain
    |
    +-- Remote disconnects (3 consecutive misses of the capture signal, ~6 seconds)
          Lock Mac
          Sleep displays
          Deactivate curtain
```

All the actions at idle and on disconnect are individually toggleable in settings.

## Session detection

Curtain uses three signals to detect an active session. The signals are evaluated together; any one of them activates the curtain.

**1. `CGSSessionScreenIsCaptured` (primary)**

```swift
let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
let captured = dict?["CGSSessionScreenIsCaptured"] as? Bool ?? false
```

This is the transport-independent primary signal. It is true whenever the local screen is being captured, over any transport: classic TCP or the macOS 14+ high-performance UDP mode on Apple Silicon. The same session dictionary tells Curtain whether the capture is the local console (apply the curtain) or a different user's virtual session (stand down and do nothing).

**2. Established inbound TCP on port 5900**

An `ESTABLISHED` connection on port 5900 catches a classic Screen Sharing session in the brief window before the capture flag settles. The socket must be `ESTABLISHED`; a `:5900` socket in `LISTEN` state (the machine idle and waiting) does not activate the curtain.

**3. Peered UDP on ports 5900-5902**

macOS 14+ High-Performance Screen Sharing on Apple Silicon streams over UDP rather than TCP. The corroborating signal for this path is a bound, peered UDP socket on ports 5900-5902. A LISTEN-state or wildcard UDP socket does not activate.

Lingering `ScreenSharingAgent`, `ScreenSharingSubscriber`, or `screensharingd` processes do **not** activate the curtain on their own. Treating those as a session was an earlier false-activation bug.

Disconnect is debounced: three consecutive misses of all three signals (~6 seconds) are required before declaring the session gone. Without this, a transient blip fires a false disconnect and kills a live session.

**Idle time** comes from the event system, using the source configured in Settings:

```swift
// "Remote session activity" (default) — idle = remote operator stopped interacting
CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)

// "This Mac's physical input only" — idle = desk stopped being used
CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
```

## The cover window

One borderless window per display, placed at the maximum window level, keyed by the display's UUID. Two properties matter:

- `ignoresMouseEvents = true`, so the window never intercepts the remote cursor.
- `canBecomeKey = false`, so the window never steals keyboard focus from the remote session.

The set of covers rebuilds on `didChangeScreenParametersNotification`. Plug in a monitor, change a resolution, or rearrange displays mid-session, and every panel stays covered. Input blocking is done entirely by the event tap. The window just hides the screen. Its look is configurable: a solid color, a message, a blur, the lock logo, the Curtain logo, or a muted looping system aerial video, with an optional clock. The aerial style falls back to the lock logo when no system aerial `.mov` is available, and the lock logo is the default cover. When the aerial style is active, one shared video decoder feeds every display, rather than a separate decoder per display.

**Cover scope** is a two-mode setting in Settings → Displays:

- **All displays** (default) — every display is covered, no per-display toggle needed. The fail-safe choice.
- **Per-display Cover toggles** — the Cover toggle on each display in Settings decides whether that display is covered.

A display that Curtain does not recognize is covered by default under either mode, so a newly attached monitor never shows the desktop.

## What the desk sees vs what the remote sees

On native (directly attached) displays, the cover window has `sharingType = .none`. This flag excludes the window from screen capture entirely. The remote operator's view shows the real desktop behind the cover. The cover is physically opaque at the desk and invisible to the remote. A `ScreenCaptureKit` self-test verifies that `.none` covers really are excluded from capture before relying on them.

## DisplayLink

DisplayLink monitors work differently. A DisplayLink display has no direct framebuffer connection. The DisplayLink driver captures the framebuffer over screen capture and sends the image over USB. A window with `sharingType = .none` is excluded from screen capture, which means it is also excluded from the DisplayLink output. The cover does not appear on the DisplayLink monitor at all.

For those monitors, Curtain uses `sharingType = .readOnly`. The window is capturable, so it appears on the DisplayLink monitor. The trade-off: it also shows in your remote view for those displays.

Mark your DisplayLink monitors in settings (Displays, then Mark Externals as DisplayLink). Native displays remain invisible to the remote. DisplayLink displays show the cover in both views, which keeps the desk covered.

Identifying DisplayLink displays by USB vendor ID is unreliable because EDID passthrough makes all monitors report the same vendor and model. Identical monitors also report serial `0`, so Curtain keys covers by `CGDisplayCreateUUIDFromDisplayID`, which is stable. The Identify Displays button flashes each monitor's index so you can match them up.

## Ending the remote session

The Screen Sharing connection process is owned by `_rmd`/root. A user process cannot kill it. Curtain ships an optional privileged helper, `CurtainHelper`. On a notarized or Developer-ID build it registers through `SMAppService.daemon`; the app talks to it over XPC using a shared `DisconnectXPC` protocol, and the daemon ends the session processes as root. A local ad-hoc or dev build cannot register an `SMAppService` daemon, so it falls back to a small privileged helper installed with one admin prompt, scoped to the current user. Either way macOS respawns the listener, so Screen Sharing remains available for new connections, and a public notarized build never installs a sudoers rule. If no helper is installed, disconnect actions are simply unavailable and the other actions still run.

## Screen lock

`CGSession -suspend` was removed from macOS. Calling `osascript` to send Ctrl+Cmd+Q requires Accessibility and a GUI context, and is unreliable from a background agent. Curtain uses `SACLockScreenImmediate`, a private symbol in `login.framework`, accessed via `dlopen`/`dlsym`. It locks immediately with no extra permission and works from a background process, with a scripted fallback if the symbol is unavailable.

## Display sleep prevention

While a session is active, Curtain holds an IOKit assertion:

```swift
IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, ...)
```

This keeps displays on for the remote view. The assertion is released when the session ends. Using an in-process assertion avoids the orphaned-PID problem that comes with external `caffeinate` processes.
