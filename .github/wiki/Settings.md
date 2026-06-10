# Settings

Open the settings window by clicking the curtains icon in the menu bar, or by reopening `Curtain.app` from Finder or Spotlight. Changes take effect immediately. The window is grouped into the sections below, matching the app's tabs.

---

## General

### Armed

The master switch. When Armed is off, Curtain ignores every session event: it will not cover, block input, disconnect, lock, or sleep displays no matter what happens. Nothing in the other sections fires while disarmed. Turn this off when you want Curtain installed but completely dormant.

Default: **on**.

### Open at login

Registers or unregisters Curtain as a login item using `SMAppService` (macOS 13+). When on, Curtain starts automatically after you log in. Requires the installed app bundle at `/Applications/Curtain.app`. Has no effect if you run the binary loose.

Default: **on**.

### Show in menu bar

Shows or hides the curtains icon in the menu bar. Turning this off does not stop Curtain from running. It keeps monitoring and reacting in the background. To get the settings window back after hiding the icon, reopen `Curtain.app` from Finder or Spotlight.

Default: **on**.

### Activate Now

Covers all displays and starts blocking physical input immediately, without waiting for a remote session. Useful for testing the curtain manually.

### Test (10s)

Same as Activate Now, but automatically deactivates after 10 seconds. A quick visual check that the cover and icon are working.

### Emergency unlock hotkey

Pressing **Control + Option + Command + U** at any time force-deactivates the curtain. It is registered as a Carbon hotkey, so it works even when Accessibility has not been granted. This is the guaranteed way to drop the cover from the desk.

### Reset to Defaults

Restores every setting on every tab to its shipped default. Your password is not changed by this.

### Export…

Writes all current settings to a `.json` file you choose. Useful for copying a known-good configuration to another Mac. The password hash is not included.

### Import…

Reads a settings file written by Export and applies it. Settings take effect immediately.

---

## Activation

Controls what happens when a remote session begins.

### Activate curtain when a remote session begins

When a remote session is detected, Curtain covers the displays and starts blocking physical input. Turn this off to leave Curtain running but passive: it still responds to idle and end events, but does not activate automatically on connect.

Default: **on**.

### Connect grace seconds

A debounce before covering. Curtain waits this many seconds after detecting a connection before it activates, so a brief blip or a probe that drops right away does not flash the cover. Range: 0 to 30 seconds.

Default: **2 seconds**.

### Notify on activate

Posts a macOS user notification when the curtain activates, so you have a record that a session started.

Default: **on**.

### Play sound on activate

Plays a short sound when the curtain activates.

Default: **off**.

---

## Appearance

What the person at the desk sees while the curtain is up.

### Cover style

Choose what the cover displays:

- **Solid color** — a flat fill in the chosen cover color.
- **Message** — the cover color with your text centered on it.
- **Blur** — a frosted blur over the desktop.
- **Lock logo** — a lock glyph centered on the cover color.
- **Curtain logo** — the Curtain logo centered on the cover color.
- **Aerial video** — plays a muted, looping system aerial `.mov` in the cover window. If no aerial video is found on the machine, it falls back to the lock logo.

Default: **lock logo**.

### Reveal trigger

What wakes the password box at the desk:

- **Any key** — any physical key press shows the box.
- **Key combo** — only a key combination you define shows the box.

Default: **any key**.

### Cover color

The fill color used by the solid, message, and logo styles.

### Cover message text

The text shown when Cover style is set to Message.

### Show clock

Overlays the current time on the cover. Lets the person at the desk see the machine is alive and on time.

Default: **on**.

---

## On session idle

### Act after idle

Enables the idle timeout feature. When on, Curtain watches for inactivity and fires the chosen actions once the threshold passes.

Default: **on**.

### Idle timeout

How many minutes of inactivity trigger the idle actions. Range: 1 to 240 minutes.

Default: **30 minutes**.

### Idle source

What counts as activity:

- **Remote session activity** — time since the last input event in the combined session (remote operator). Idle means the remote operator stopped interacting. This is the product default because it tracks whether the remote session itself is active.
- **This Mac's physical input only** — time since the last physical hardware event at the desk.

Default: **Remote session activity**.

### Idle actions

Any combination of the following fires when the idle timeout passes:

- **Disconnect** — ends the remote session.
- **Lock** — locks the Mac.
- **Turn off displays** — sleeps all displays.
- **Deactivate** — hides the cover and removes the input block.

Defaults: all **on**.

---

## On session end (disconnect)

These actions fire when a remote session is detected as dropped.

- **Lock** — locks the Mac when the session ends.
- **Turn off displays** — sleeps the displays after locking.
- **Deactivate** — hides the cover and removes the input block. If left off, the cover stays up after the remote disconnects.

Defaults: all **on**.

---

## Security

### On Curtain Unlock

What happens to the remote session when the correct password is entered at the desk:

- **Keep session active** — the curtain drops and the remote operator stays connected.
- **Disconnect remote** — the curtain drops and the active remote session is ended.

Default: **keep session active**.

### Password box timeout

How long the on-curtain password box stays visible after a physical key wakes it before it hides again. Range: 5 to 60 seconds.

Default: **15 seconds**.

### Require password to deactivate from the menu

When on, choosing Deactivate from the menu prompts for the password first. The fallback password `curtain` always works even when a custom password is set, so you can never lock yourself out from the menu.

Default: **off**.

### Accessibility-missing behavior

The input block cannot work without Accessibility. When the permission is not granted, Curtain never shows the cover: on connect it stays down and posts a notification instead. This prevents putting up a screen that cannot be unlocked. The picker controls what arming itself does in that state: **Warn** (default) lets the app arm and warns at connect time; **Refuse to arm** rejects the master switch outright with a notification until the permission is granted.

Grant Accessibility in System Settings → Privacy & Security → Accessibility, then relaunch Curtain. The emergency hotkey **Control + Option + Command + U** still works regardless of Accessibility state.

### Set password

Type a new password and click **Set**. The password is stored as a salted PBKDF2-HMAC-SHA256 hash in `UserDefaults`. The plaintext is never saved.

If no password has been set, the default password `curtain` is accepted. The window shows your current state ("A password is set." or "No password set (default: 'curtain')."). The `curtain` fallback always works regardless of any custom password.

---

## Disconnect

### Enable disconnect-remote-on-end

Lets Curtain end the remote session for the idle and session-end actions. This is **off by default** because it needs elevated rights.

Turning it on installs a privileged helper. On a notarized or Developer-ID-signed build, Curtain registers a daemon through `SMAppService.daemon`, which prompts for one approval in System Settings. On a local ad-hoc or dev build, Curtain falls back to a small privileged helper installed with one admin prompt, scoped to the current user. A public notarized build never installs a sudoers rule. The helper performs the disconnect; macOS respawns the listener so new connections stay possible. See [How It Works](How-It-Works).

Default: **off**.

---

## Displays

Per-display controls, keyed by each monitor's stable display UUID so they survive reboots and reconnection.

### Cover (per display)

Marks whether a given display participates in covering. Used with Cover scope below.

### DisplayLink (per display)

Marks a display as a DisplayLink monitor. Curtain uses a capturable cover (`sharingType = .readOnly`) for these instead of the invisible cover (`sharingType = .none`) it uses for native displays. The cover on a DisplayLink display is also visible in the remote view, a hardware constraint, not a bug.

### Cover scope

Which displays get covered when the curtain activates:

- **All displays** — cover every display. This is the fail-safe default. No per-display toggling needed.
- **Per-display Cover toggles** — each display's Cover switch in the list below decides whether it is covered.

Default: **All displays**.

### Password-box display

Which display shows the on-curtain password box when a physical key is pressed. Choose from the list of connected displays shown in the picker. The list updates when displays are added or removed.

Default: **Primary display**.

### New-display policy

What to do when a display is hotplugged mid-session:

- **Cover** — cover it immediately (fail-safe default).
- **Leave uncovered** — do not cover it.
- **Treat as DisplayLink** — cover it with the capturable cover.

Default: **cover**. Covering is the fail-safe so a newly attached monitor never leaks the desktop.

### Identify Displays

Flashes each connected display with a large label showing its index and identifier. Use this before marking displays.

### Mark Externals as DisplayLink

Records every external (non-built-in) display as a DisplayLink display in one step.

---

## Advanced

### Diagnostics logging

Enables verbose logging for troubleshooting. Off by default to keep logs quiet.

Default: **off**.

### Open Setup…

Re-runs the first-run onboarding flow (permission checks, display marking, password setup).

### Version footer

Shows the running version of Curtain.

---

## Safe first-run defaults

Curtain ships configured to fail safe:

- Armed on, activate-on-connect on, with a 2-second connect grace.
- Cover scope is All displays, so every display is covered without any per-display configuration.
- New displays are covered by default, so a mid-session hotplug never exposes the desktop.
- Idle source is Remote session activity, so idle detection tracks whether the remote operator is still present.
- The `curtain` fallback password always works, so you can always drop the cover at the desk.
- The Control + Option + Command + U emergency hotkey force-deactivates the curtain even without Accessibility.
- Disconnect-remote-on-end is off, so no privileged helper is installed until you opt in.
- Without Accessibility, Curtain never shows the cover and notifies you instead, rather than putting up a screen it cannot unlock.

## Dangerous-combination warnings

The settings window flags combinations that can leave you in a bad state:

- **Low idle timeout plus disconnect.** A short idle timeout combined with disconnect-on-idle can kill a live session during a normal pause in work. The window warns when the timeout is low and disconnect is on.
- **Screen off without deactivate.** Turning displays off without also deactivating leaves the cover up behind a black screen. When you wake the display you are still behind the curtain. The window warns on this pair.
- **"Dead but unlocked."** A configuration that turns displays off or deactivates on end without locking can leave the Mac reachable and unlocked once the cover is gone. The window warns when an end or idle action sleeps or deactivates but does not lock.
- **Accessibility not granted.** When the permission is missing, the window shows that Curtain will refuse to cover, so you are not surprised that nothing happens on connect. The Control + Option + Command + U hotkey still works as the escape.
