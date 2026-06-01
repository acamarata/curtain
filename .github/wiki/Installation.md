# Installation

## Prerequisites

- macOS 13 or later (Apple Silicon recommended).
- Screen Sharing enabled in System Settings > General > Sharing > Screen Sharing.
- Admin rights on the machine (the install script needs one sudo prompt).

## Install

```bash
git clone https://github.com/acamarata/curtain.git
cd curtain
./Scripts/install.sh
```

The script does the following in one go:

| What it sets up | Where | Why |
|---|---|---|
| `Curtain.app` bundle | `/Applications/Curtain.app` | Ad-hoc codesigns the bundle so TCC (Accessibility) grants a stable identity. |
| Login LaunchAgent | `~/Library/LaunchAgents/com.acamarata.curtain.plist` | Starts Curtain automatically when you log in. |
| Root helper | `/usr/local/bin/curtain-endsession` | Lets Curtain kill the Screen Sharing connection (owned by root) without a password prompt. |
| Sudoers rule | `/etc/sudoers.d/curtain-endsession` | NOPASSWD for the helper only. Requires one admin prompt during install. |

After the script finishes, Curtain starts automatically and a 👁 icon appears in the menu bar.

## Grant Accessibility

Curtain needs Accessibility permission to block physical keyboard and mouse input. Without it the curtain still covers the screen, but desk input reaches your apps.

1. Open **System Settings > Privacy & Security > Accessibility**.
2. Find **Curtain** in the list and turn it on.
3. Relaunch Curtain: `launchctl kickstart -k gui/$(id -u)/com.acamarata.curtain`

If Curtain does not appear in the Accessibility list, run:

```bash
open -a Curtain
```

Then check again.

## Set a password

From the menu-bar icon, choose **Set Password…** and type the password you want to use at the desk to end a remote session.

If you never set a password, the default is `curtain`.

Passwords are stored as a salted SHA-256 hash in `~/Library/Application Support/Curtain/config.json`. The plaintext is never saved.

## Mark DisplayLink monitors (if you use them)

If you have any DisplayLink USB monitors, choose **Mark Current Externals as DisplayLink** from the menu. This tells Curtain to use a different cover mode for those displays.

To see which display is which first, choose **Identify Displays** — each monitor flashes its index number and serial for six seconds.

See [How It Works — DisplayLink](How-It-Works#displaylink) for why this matters.

## Uninstall

```bash
./Scripts/uninstall.sh
```

This removes the app bundle, LaunchAgent, helper binary, and sudoers rule.

## Manual LaunchAgent management

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.acamarata.curtain.plist

# Start
launchctl load ~/Library/LaunchAgents/com.acamarata.curtain.plist

# Restart
launchctl kickstart -k gui/$(id -u)/com.acamarata.curtain
```
