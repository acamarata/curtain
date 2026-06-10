# Troubleshooting

## Emergency unlock (always works)

If you are stuck behind the curtain for any reason, press **Control + Option + Command + U** at the desk. This force-deactivates the curtain immediately. It is a Carbon hotkey, so it works even when Accessibility has not been granted. This is your guaranteed escape.

## The curtain will not appear / Curtain refuses to cover

Accessibility permission is not granted. Curtain will not put up a cover it cannot unlock, so when the permission is missing it refuses to show the cover and posts a notification instead.

1. Open System Settings → Privacy & Security → Accessibility.
2. Find **Curtain** in the list and make sure it is enabled.
3. If it is not in the list, launch Curtain from `/Applications` once to force a registration attempt.
4. After granting, relaunch Curtain so the permission takes effect.

## macOS blocks the app on first launch (Gatekeeper)

Curtain is ad-hoc signed and not yet notarized, so a clean download is quarantined. Clear the flag once, then open normally:

```bash
xattr -dr com.apple.quarantine /Applications/Curtain.app
```

This is a current limitation that goes away once a notarized build ships.

## The app will not launch

Confirm whether the process is running:

```bash
pgrep -fl Curtain
```

If nothing prints, launch Curtain from `/Applications`. If it launches and immediately exits, open Console.app and filter for `Curtain` to see the crash or exit reason. The Gatekeeper quarantine flag above is the most common cause of a silent first-launch failure.

## The curtain does not arm when Screen Sharing connects

First confirm Accessibility is granted (see above) and that Curtain is armed. The menu-bar icon is the curtains glyph; it tints red while the curtain is active. Open the menu and confirm **Armed** has a checkmark. If it does not, choose **Armed** to re-enable.

If the menu-bar icon is missing entirely, Curtain is not running. Launch it from `/Applications` and check `pgrep -fl Curtain`.

### Use the probe script to verify detection

Run the included probe while a Screen Sharing session is active:

```bash
swift Scripts/probe-detection.swift
```

It prints the live values of all three detection signals:

| Line | Meaning |
|---|---|
| `captured=true` | `CGSSessionScreenIsCaptured` is true. Curtain should activate. |
| `tcp_estab=true` | An ESTABLISHED inbound TCP connection exists on port 5900. |
| `udp_peered=true` | A peered UDP socket exists on ports 5900-5902. |
| `tcp_listen=true` | A LISTEN socket on 5900 exists. This does NOT activate the curtain. |
| `udp=true` | A UDP socket on 5900-5902 exists but is not peered. This does NOT activate. |
| `DICT …` | A key in the CGSession dictionary that appeared or changed since last poll. |

If `captured=false` and both `tcp_estab` and `udp_peered` are also false while a session is clearly running, there is a detection gap. Note the DICT output and file an issue with the output attached.

### Re-grant Accessibility after every rebuild of an ad-hoc build

Rebuilding the app from source produces a new binary with a new code signature. macOS TCC ties the Accessibility grant to the code signature, so the old grant no longer applies. After rebuilding:

1. Open System Settings → Privacy & Security → Accessibility.
2. Remove the old Curtain entry if present, then re-add it.
3. Relaunch Curtain.

## The curtain activates when no one is connected

The three activation signals are: `CGSSessionScreenIsCaptured`, an ESTABLISHED TCP connection on port 5900, and a peered UDP socket on ports 5900-5902. A lingering Screen Sharing process, an idle `:5900` LISTEN socket, or a wildcard UDP socket does **not** activate the curtain. If it arms with no session, run the probe (`swift Scripts/probe-detection.swift`) to see which signal is true, and check whether something on the machine is capturing the console screen.

## DisplayLink monitor is not covered

This is expected if the monitor has not been marked.

Open **Settings → Displays** and mark the monitor as DisplayLink. Each display is identified by a stable UUID, so the marking persists. On a DisplayLink monitor the curtain also shows in the remote view. That is by design. See [How It Works — DisplayLink](How-It-Works#displaylink) for the technical reason.

## Multiple displays: the remote view only shows one screen

The Apple Screen Sharing app shows one host display at a time. Switch between them from its **View** menu. This is normal Screen Sharing behavior, not a Curtain bug.

## The session keeps dropping

Curtain debounces disconnect detection: it waits for three consecutive missed polls (about 6 seconds) before declaring the session ended. On a stable network this never trips by accident. If sessions drop on a reliable connection, check whether another process is interfering with port 5900 or restarting Screen Sharing.

## The remote operator's mouse and keyboard stop working

This should not happen when the event tap is working correctly. The tap only blocks events with source state ID `1` (physical hardware). Remote events have a different source ID and pass through untouched.

## The Mac does not lock when the session ends

The lock uses `SACLockScreenImmediate` from login.framework. Confirm the lock screen is enabled: System Settings → Lock Screen → Require password. If the OS lock screen is disabled, there is nothing for the lock call to fall back to.

## I forgot my password

Settings live in UserDefaults. Reset everything to defaults:

```bash
defaults delete io.acamarata.curtain
```

Relaunch Curtain. It starts fresh and the default password `curtain` applies again. Set a new one from the settings window.

## The disconnect helper is not working

The optional disconnect feature installs a privileged helper and needs one admin approval. On a notarized or Developer-ID build it registers a daemon through SMAppService.daemon, approved once in System Settings. On a local ad-hoc or dev build it falls back to a small current-user-scoped privileged helper installed with one admin prompt. If disconnect actions do nothing, confirm you approved the helper, and re-run **Settings → Disconnect → Enable disconnect-remote-on-end** to reinstall it.
