# Troubleshooting

## Curtain covers the screen but desk keyboard input still reaches apps

Accessibility permission is not granted, or the tap is not active.

1. Open System Settings > Privacy & Security > Accessibility.
2. Find **Curtain** in the list and make sure it is enabled.
3. If it is not in the list, run `open -a Curtain` once to force a registration attempt.
4. After granting, relaunch Curtain: `launchctl kickstart -k gui/$(id -u)/com.acamarata.curtain`

If the app is not properly code-signed (e.g. you compiled it yourself outside `install.sh`), TCC may not give it a stable identity. Run `install.sh` to ensure the bundle is ad-hoc signed.

## The curtain shows but the remote operator's mouse/keyboard stops working

This should not happen if the event tap is working correctly. The tap only blocks events with source state ID `1` (physical hardware). Remote events have a different source ID and are passed through.

Check that Curtain is not the key window and not blocking mouse events at the window level. The cover window should have `ignoresMouseEvents = true`. If you built Curtain from source outside the normal build, verify these properties are set.

## DisplayLink monitor is not covered

This is expected if the monitor has not been marked.

From the menu-bar icon, choose **Mark Current Externals as DisplayLink**. If you have multiple external monitors and only some are DisplayLink, use **Identify Displays** first to flash each display's index and serial number, then verify the serials in `~/Library/Application Support/Curtain/config.json`.

Note: on a DisplayLink monitor, the curtain shows in your remote view too. That is by design. See [How It Works — DisplayLink](How-It-Works#displaylink) for the technical reason.

## The session keeps dropping every ~30-60 seconds

This is the debounce not triggering correctly, or a network issue causing repeated transient disconnects.

Curtain requires three consecutive netstat misses (~6 seconds) before declaring a disconnect. If the network is unstable enough to miss three consecutive polls, the session may drop. Check your network connection.

If this happens even on a stable network, check whether another process is interfering with port 5900 or restarting Screen Sharing.

## The Mac does not lock when the session ends

The lock function uses `SACLockScreenImmediate` from `login.framework`. If this symbol is unavailable (unlikely but possible after a major macOS update), it falls back to an `osascript` Ctrl+Cmd+Q shortcut, which requires Accessibility.

Check that the lock screen is enabled: System Settings > Lock Screen > Require password. If the lock screen is disabled at the OS level, `SACLockScreenImmediate` has nothing to lock to.

## I forgot my password

The default password is `curtain`. If you set a custom password and forgot it, delete the config file to reset:

```bash
rm ~/Library/Application\ Support/Curtain/config.json
```

Curtain recreates it with a fresh salt and no password hash on next launch, and `curtain` becomes the password again. Set a new password from the menu.

## The curtain does not appear when Screen Sharing connects

Check that Curtain is armed. The menu-bar icon shows `👁` when armed and `○` when disarmed. If it shows `○`, choose **Armed** from the menu to re-enable.

Also confirm the menu-bar icon is present. If Curtain is not running:

```bash
launchctl list | grep curtain
```

If the LaunchAgent is not loaded:

```bash
launchctl load ~/Library/LaunchAgents/com.acamarata.curtain.plist
```

## How to check if the LaunchAgent is running

```bash
launchctl list | grep curtain
```

A running agent shows its PID in the first column. An exit code in the third column means it crashed or exited.

To see the last exit reason:

```bash
launchctl print gui/$(id -u)/com.acamarata.curtain
```

To restart:

```bash
launchctl kickstart -k gui/$(id -u)/com.acamarata.curtain
```

## How to check Accessibility permission status

```bash
# Prints 1 if trusted, 0 if not
/usr/bin/swift -e 'import Cocoa; print(AXIsProcessTrusted() ? 1 : 0)'
```

Or open System Settings > Privacy & Security > Accessibility and look for Curtain in the list.

## The install script fails asking for a password

The script needs admin rights once to install the root helper and sudoers rule. This is expected. Enter your admin password when prompted. After that, no further sudo prompts should appear during normal use.

## The "end session" helper is missing

If `System.endScreenShareSession()` silently does nothing, the helper may not be installed:

```bash
ls -la /usr/local/bin/curtain-endsession
cat /etc/sudoers.d/curtain-endsession
```

If either is missing, re-run `install.sh`. This step requires one admin prompt.

## Screen Sharing stops working after a disconnect

The helper kills the active session processes. macOS respawns the listener automatically. If Screen Sharing does not accept new connections after a Curtain-initiated disconnect, try:

```bash
sudo launchctl kickstart -k system/com.apple.screensharing
```

Or toggle Screen Sharing off and on in System Settings > General > Sharing.
