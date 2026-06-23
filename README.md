# Curtain

A menu-bar privacy layer for macOS Screen Sharing.

When you remote into your Mac, Curtain hides the screen from anyone sitting at the desk and makes the local keyboard and mouse do nothing to your apps, while your remote control keeps working normally. When the session goes idle or disconnects, it can lock the Mac and sleep the displays. It runs as a small menu-bar agent with a simple settings window, in the spirit of Caffeine.

## Why it works

Your laptop and the desk share one login session, so a window that blocks input would block you too. Curtain takes a different route. It detects sessions using three signals: a transport-independent macOS capture flag (works with both classic TCP and the high-performance UDP mode on macOS 14+ Apple Silicon), an established TCP connection on port 5900, and a peered UDP socket on ports 5900-5902. It then filters input by event source: physical hardware events from the desk are blocked, while your injected remote events pass through untouched. No virtual display, no second account.

## What it does

| Event | Behavior (all configurable) |
|---|---|
| **Remote session starts** | Covers every physical display, blocks desk keyboard and mouse, keeps the displays awake. Posts a notification. Your remote input works as usual. |
| **Reveal trigger at the desk** | A password box appears on the desk on any key, or on a key combo you define. The correct password reveals the desktop and can optionally keep or disconnect the remote operator. |
| **Session idle** (default 30 min) | Any of: disconnect the remote, lock the Mac, sleep the displays, deactivate the curtain. |
| **Disconnect** | Any of: lock the Mac, sleep the displays, deactivate the curtain. |

## Install

1. Download `Curtain-1.0.0.dmg` from the [Releases](../../releases) page.
2. Open the DMG and drag `Curtain.app` to Applications.
3. Launch Curtain. First launch walks you through granting Accessibility, setting an optional password, and installing an optional disconnect helper.

Curtain needs Accessibility permission to block desk input, so grant it when prompted (System Settings, Privacy & Security, Accessibility). If Accessibility is not granted, Curtain refuses to show the cover and notifies you, rather than putting up a screen it cannot unlock.

**Emergency unlock:** press **Control + Option + Command + U** at any time to force-deactivate the curtain. This works even without Accessibility granted (it uses a Carbon hotkey), so it is your guaranteed way out.

The current builds are ad-hoc signed, not yet notarized, so macOS Gatekeeper will refuse the first launch. Clear the quarantine flag once, then open the app:

```bash
xattr -dr com.apple.quarantine /Applications/Curtain.app
```

Notarized builds are planned, which will remove this step. To confirm your download is intact, verify the DMG against its published SHA-256 (the `.sha256` file is attached to the release):

```bash
shasum -a 256 Curtain-1.0.0.dmg
```

## Settings

Everything is a setting. Open the window from the menu-bar curtains icon or by reopening `Curtain.app`. Changes take effect immediately. You control arming, what the desk sees (solid color, message, blur, lock logo, Curtain logo, or aerial video), the reveal trigger, the idle and disconnect actions, the idle source (remote session activity or physical HID), the password and idle timeout, what happens to the remote session on unlock, per-display cover scope, password-box placement, and DisplayLink marking. See the [Settings](.github/wiki/Settings.md) page for the full reference.

## Multi-display note

Curtain covers every physical display. The Apple Screen Sharing app shows one host display at a time, so on a multi-monitor Mac you switch between them in its View menu. That is standard Screen Sharing behavior, not something Curtain changes.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon (built and tested on a Mac Mini M4 running macOS 26)
- Screen Sharing enabled (System Settings, General, Sharing, Screen Sharing)
- Accessibility permission for Curtain

## Documentation

The [documentation](.github/wiki/Home.md) covers everything in depth: [Installation](.github/wiki/Installation.md), [Settings](.github/wiki/Settings.md), [How It Works](.github/wiki/How-It-Works.md), [Architecture](.github/wiki/Architecture.md), [Security](.github/wiki/Security.md), [Lessons Learned](.github/wiki/Lessons-Learned.md), and [Troubleshooting](.github/wiki/Troubleshooting.md).

## License

MIT © Aric Camarata
