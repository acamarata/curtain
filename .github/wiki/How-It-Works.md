# How It Works

## The core challenge

When you use macOS Screen Sharing, your laptop and the physical Mac share one login session. There is no separate "remote session" at the OS level — it is the same desktop, the same running apps, the same input system.

That creates a hard constraint: you cannot simply put up a window that blocks input, because that would block both the desk keyboard and your remote keyboard at the same time. You also cannot put up a click-through window (one that ignores mouse clicks and key presses), because then desk input still reaches your apps.

Curtain solves this by working at a lower level: it inspects every input event before it reaches any app and decides, for each event individually, whether it came from physical hardware or from the Screen Sharing connection.

## Physical vs remote input

macOS tags every input event with a source identifier. Events from real, physical hardware (keyboard, mouse, trackpad) consistently carry source ID `1`. Events injected by Screen Sharing carry a large, arbitrary number that is different from `1` and changes with each new connection.

Curtain installs a system-level event tap (a `CGEventTap`) that runs before any app sees the event. The rule is simple: if the source ID is `1`, the event came from the desk — block it. If the source ID is anything else, the event came from the remote operator — let it through.

This is what lets you type and click freely on your laptop while the desk keyboard and mouse do nothing.

Physical key presses are not completely ignored. When a key comes in from the desk, Curtain reads it and feeds it into the password box, so the person at the desk can type a password to reclaim the machine.

## The lifecycle

```
Screen Sharing connects
  |
  +-- Curtain covers all physical displays (black screen, "Remote Session Active")
  +-- Input tap activates (physical input blocked, remote input passes through)
  +-- Display sleep prevention starts (displays stay on for the remote view)
  |
  While connected:
    |
    +-- Someone at the desk presses a key
    |     -> Password box appears
    |     -> Correct password: remote session ends, curtain drops
    |     -> Wrong password: box clears, try again
    |     -> Esc or no key for 6 seconds: box hides
    |
    +-- No HID input for 30 minutes (idle timeout)
    |     -> Remote session is terminated
    |     -> Mac locks, displays sleep
    |
    +-- Remote operator disconnects
          -> Mac locks, displays sleep
```

## Ending the remote session

The Screen Sharing connection process (`screensharingd`) is owned by a system account, not your user. Curtain cannot kill it directly. During installation, a small helper binary is placed at `/usr/local/bin/curtain-endsession` with a sudoers rule that allows Curtain to run it without a password. The helper kills the session processes. macOS then respawns the listener automatically, so Screen Sharing remains available for the next connection.

## How the cover works

The cover is a full-screen, borderless window placed at the highest window level, covering each physical display. It has two properties that matter:

- `ignoresMouseEvents = true` — the window never intercepts the remote cursor.
- `canBecomeKey = false` — the window never steals keyboard focus from the remote session.

Input blocking is done entirely by the event tap, not the window itself.

## What the desk sees

The cover shows a black screen with a lock icon and the text "Remote Session Active". When a key is pressed, a small password panel appears centered on the primary display.

## What the remote sees

On native (directly attached) displays, the cover window is marked with `sharingType = .none`. That means it is excluded from screen capture entirely. Your remote view shows your actual desktop, not the black cover.

## DisplayLink

DisplayLink monitors work differently. A DisplayLink display only exists through screen capture — the DisplayLink driver captures the framebuffer and sends it over USB. A window marked `sharingType = .none` is invisible to screen capture, which means it is also invisible to the DisplayLink driver, and the cover does not appear on a DisplayLink monitor at all.

For those monitors, Curtain uses `sharingType = .readOnly` instead. The cover is visible to screen capture and therefore shows on the DisplayLink monitor. The trade-off: the cover also shows in your remote view for those displays.

This is why the install step includes **Mark Current Externals as DisplayLink** — Curtain needs to know which displays require the different cover mode.

## Idle detection

Curtain reads the system's HID idle time from IOKit (`ioreg -c IOHIDSystem`, `HIDIdleTime` field). This is the time since the last physical input event, in nanoseconds. When it exceeds the configured threshold (default 30 minutes), the idle timeout fires.

## Session detection

Curtain polls `netstat` every two seconds and looks for an ESTABLISHED connection on port 5900 (the VNC port used by Screen Sharing). `lsof` cannot be used here because the Screen Sharing sockets are owned by a system account and are invisible to a user-context `lsof`. The disconnect is debounced: three consecutive misses (~6 seconds) are required before a disconnect is reported, to avoid false disconnects from transient network blips.
