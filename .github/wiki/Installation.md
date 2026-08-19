# Installation

## Prerequisites

- macOS 13 (Ventura) or later. Apple Silicon recommended.
- Screen Sharing enabled: System Settings → General → Sharing → Screen Sharing.

## Install

1. Download the latest `Curtain-X.Y.Z.dmg` from the [GitHub Releases page](https://github.com/acamarata/curtain/releases).
2. Open the DMG.
3. Drag `Curtain.app` into the `Applications` folder.
4. Launch Curtain from `/Applications`.

On first launch an onboarding flow walks you through setup: Welcome → grant Accessibility → optional disconnect helper → optional password → finish. When it completes, the curtains icon appears in the menu bar.

## Verify your download

```bash
shasum -a 256 -c Curtain-X.Y.Z.dmg.sha256
```

Run it from the directory holding both the `.dmg` and its `.sha256` sidecar; it prints `Curtain-X.Y.Z.dmg: OK`. Sidecars from v2.0.2 onward use the standard two-field format `-c` expects. For v1.0.0 through v2.0.1 the sidecar is a bare hash, so compare it by eye against `shasum -a 256 Curtain-X.Y.Z.dmg` instead.

## First launch: Gatekeeper

Releases from **v2.0.3 onward are signed with a Developer ID and notarized by Apple**, and both the `.dmg` and the app inside it carry a stapled notarization ticket. Gatekeeper accepts them on first open with nothing extra to do, and because the ticket is stapled the check also works offline. Download, open, drag, launch.

Two cases still need the quarantine flag cleared once:

- A release **before v2.0.3** (v1.0.0 through v2.0.2), which was ad-hoc signed.
- Anything you **built from source**, which is ad-hoc signed by default.

```bash
xattr -dr com.apple.quarantine /Applications/Curtain.app
```

Then double-click `Curtain.app`. Right-clicking and choosing Open is no longer enough on recent macOS, so use the command above. This is the expected step for a build without a Developer ID, not a workaround to avoid — and upgrading to a current release removes it entirely.

## Grant Accessibility

Curtain needs Accessibility permission to block the desk keyboard and mouse. Without it, Curtain refuses to show the cover at all and posts a notification instead. This prevents putting up a screen that cannot be unlocked. The emergency hotkey **Control + Option + Command + U** always works regardless.

The onboarding flow deep-links you straight to the right pane. You can also open it yourself:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Find **Curtain** in the list and turn it on.
3. Relaunch Curtain so the new permission takes effect.

If Curtain does not appear in the Accessibility list, launch it once from `/Applications`, then check again.

macOS ties the Accessibility grant to an app's code signature, so it does not survive a signature change. In practice:

- **Upgrading to v2.0.3 from v2.0.2 or earlier clears the grant once**, because the signature changes from ad-hoc to a real Developer ID. Re-enable Curtain in the Accessibility list afterwards (remove the stale entry with the minus button first), then use **Activate Now** from the menu-bar icon to confirm the cover actually rises.
- **Updates from v2.0.3 onward keep the grant**, because the Developer ID identity is stable.
- **Local source builds need re-granting after every rebuild**, since each rebuild produces a new ad-hoc signature.

This matters because the loss is silent: Curtain still reports itself as armed, since by default it arms and warns at connect time rather than refusing to arm. If you would rather it fail loudly, set **Settings → Security → "If Accessibility is missing"** to **Refuse to arm**.

## Open at login

Curtain manages login startup itself with SMAppService. Turn on **Open at login** in the settings window. macOS tracks this under **System Settings → General → Login Items**, where you can also toggle it off. There is no LaunchAgent and no plist to manage by hand.

## Set a password

Open the settings window (click the menu-bar icon) and type a password in the **Security** section. This is what someone at the desk types to get past the curtain.

If you never set a password, the default is `curtain`. The password is stored as a salted PBKDF2-HMAC-SHA256 hash in UserDefaults. The plaintext is never saved.

## Disconnect helper (optional)

The optional "disconnect the remote session" feature is off by default. When you enable it (in settings or during onboarding), Curtain registers a privileged helper through SMAppService and asks for one approval in System Settings. There is no sudoers rule.

On a released build (v2.0.3 onward, Developer ID signed and notarized) the helper registers through `SMAppService.daemon` and needs one approval in System Settings. On a local ad-hoc or source build, which cannot register an `SMAppService` daemon, Curtain falls back to a small privileged helper installed with one admin prompt, scoped to the current user. A public notarized build never installs a sudoers rule.

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
