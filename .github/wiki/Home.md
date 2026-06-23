# Curtain

A privacy curtain for macOS Screen Sharing. When you remote into your Mac, Curtain hides the screen from anyone sitting at it and makes the local keyboard and mouse do nothing to your apps, while you keep full control from your laptop. When the session goes idle or ends, it can lock the Mac and sleep the displays.

macOS does Screen Sharing well. Curtain is the missing privacy layer around it: a lightweight menu-bar agent with a SwiftUI settings window, in the spirit of Caffeine.

## Behavior at a glance

| Event | Default (all configurable) |
|---|---|
| Remote session connects | Cover every physical display. Block desk keyboard and mouse from reaching apps. Keep displays awake. Remote input works normally. |
| Key pressed at the desk | A password box appears on the curtain. Correct password reveals the desktop and offers to disconnect the remote. |
| Session idle (default 30 min, tracks remote activity by default) | Disconnect remote, lock Mac, turn off displays, deactivate curtain. |
| Remote session disconnects | Lock Mac, turn off displays, deactivate curtain. |

## The key idea

Your laptop and the desk share one login session (standard Screen Sharing shares the console). A window that blocks input would block your remote too. Curtain detects sessions with three independent signals: a transport-independent macOS capture flag, an established TCP connection on port 5900, and a peered UDP socket on ports 5900-5902. It then filters input by **event source**: macOS tags real hardware events differently from injected remote events. Curtain blocks events with source ID `1` (physical hardware) and passes everything else. No virtual display, no second account.

**Emergency unlock:** press **Control + Option + Command + U** at the desk to force-deactivate at any time. It works even without Accessibility granted.

## Pages

| Page | What it covers |
|---|---|
| [Installation](Installation.md) | Clone, `install.sh`, Accessibility grant, password setup, DisplayLink, uninstall |
| [Settings](Settings.md) | Every option in the settings window explained |
| [How It Works](How-It-Works.md) | Lifecycle walkthrough, the physical-vs-remote trick, DisplayLink caveat |
| [Security](Security.md) | Threat model, input-filter limits, password storage, the optional helper, distribution trust |
| [Architecture](Architecture.md) | 12-module breakdown, macOS APIs, data flow |
| [Lessons Learned](Lessons-Learned.md) | What was discovered building this, including what did not work |
| [Troubleshooting](Troubleshooting.md) | Common problems and fixes |

## Requirements

- macOS 13 (Ventura) or later. Built and tested on macOS 26 / Apple Silicon.
- Screen Sharing enabled: System Settings → General → Sharing → Screen Sharing.
- Accessibility permission for Curtain, granted once after install.

## License

MIT © Aric Camarata
