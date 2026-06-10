# Installation

## Prerequisites

- macOS 13 (Ventura) or later. Apple Silicon recommended.
- Screen Sharing enabled: System Settings → General → Sharing → Screen Sharing.

## Install

1. Download `Curtain-1.0.0.dmg` from the [GitHub Releases page](https://github.com/acamarata/curtain/releases).
2. Open the DMG.
3. Drag `Curtain.app` into the `Applications` folder.
4. Launch Curtain from `/Applications`.

On first launch an onboarding flow walks you through setup: Welcome → grant Accessibility → optional disconnect helper → optional password → finish. When it completes, the curtains icon appears in the menu bar.

## First launch: Gatekeeper

Curtain is currently ad-hoc signed, not yet notarized. On a clean download macOS Gatekeeper blocks the first launch and reports the app is damaged or from an unidentified developer. This is expected for now.

Clear the quarantine flag once, then open the app normally:

```bash
xattr -dr com.apple.quarantine /Applications/Curtain.app
```

Then double-click `Curtain.app`. Right-clicking and choosing Open is no longer enough on recent macOS, so use the command above. Once a notarized build ships, this step goes away and Curtain opens straight from the DMG.

## Grant Accessibility

Curtain needs Accessibility permission to block the desk keyboard and mouse. Without it, Curtain refuses to show the cover at all and posts a notification instead. This prevents putting up a screen that cannot be unlocked. The emergency hotkey **Control + Option + Command + U** always works regardless.

The onboarding flow deep-links you straight to the right pane. You can also open it yourself:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Find **Curtain** in the list and turn it on.
3. Relaunch Curtain so the new permission takes effect.

If Curtain does not appear in the Accessibility list, launch it once from `/Applications`, then check again.

After every rebuild of a local ad-hoc build, re-grant Accessibility. Rebuilding produces a new code signature and macOS does not carry over the old grant automatically.

## Open at login

Curtain manages login startup itself with SMAppService. Turn on **Open at login** in the settings window. macOS tracks this under **System Settings → General → Login Items**, where you can also toggle it off. There is no LaunchAgent and no plist to manage by hand.

## Set a password

Open the settings window (click the menu-bar icon) and type a password in the **Security** section. This is what someone at the desk types to get past the curtain.

If you never set a password, the default is `curtain`. The password is stored as a salted PBKDF2-HMAC-SHA256 hash in UserDefaults. The plaintext is never saved.

## Disconnect helper (optional)

The optional "disconnect the remote session" feature is off by default. When you enable it (in settings or during onboarding), Curtain registers a privileged helper through SMAppService and asks for one approval in System Settings. There is no sudoers rule.

Under the current ad-hoc build, this helper may fail to register. The privileged-helper path needs a notarized or Developer ID signed build to install cleanly. Until then, leave the feature off or expect the registration to be rejected.

## Mark DisplayLink monitors (if you have them)

If any external monitor is DisplayLink, open **Settings → Displays** and mark it as DisplayLink. This tells Curtain to use a capturable cover mode for that display.

Displays are identified by a stable UUID, so the marking survives reboots and reconnects. Detection works with both classic and high-performance Screen Sharing.

See [How It Works](How-It-Works#displaylink) for why this matters.

## Confirm Curtain is running

```bash
pgrep -fl Curtain
```

You can also open Activity Monitor and search for Curtain.

## Uninstall

Quit Curtain, then drag `Curtain.app` from `/Applications` to the Trash.

If you had an older script-based install on this machine, `Scripts/uninstall.sh` in the repo cleans up any legacy LaunchAgent, helper binary, or sudoers rule left behind.
