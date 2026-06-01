# Curtain

A privacy curtain for macOS Screen Sharing. When you remote into your Mac, Curtain hides the screen from anyone sitting at it and makes the local keyboard and mouse do nothing to your apps, while you keep full control from your laptop. When the session goes idle or ends, it can lock the Mac and sleep the displays.

macOS already does Screen Sharing well. Curtain is the missing privacy layer around it: a lightweight menu-bar agent with a simple settings window, in the spirit of Caffeine.

<p align="center"><em>Connect → screen covered, desk input dead, you control remotely. Idle/disconnect → lock + displays off.</em></p>

## Why it works (the one hard part)

Your laptop and the desk share one login session, so a window that blocks input would block you too. Curtain instead filters input by **source**: macOS tags real hardware events differently from injected remote events, so Curtain blocks the desk's keyboard/mouse while letting your remote control pass through. No virtual display, no second account.

## What it does

| Event | Default behavior (all configurable) |
|---|---|
| **Remote session starts** | Curtain covers every physical display; desk keyboard/mouse are blocked from apps; your remote input works; displays kept awake. |
| **Key pressed at the desk** | A password box appears (on the desk only). Correct password reveals the desktop and offers to disconnect the remote. |
| **Session idle (default 30 min)** | Disconnect remote · lock Mac · sleep displays · deactivate curtain. |
| **Session ends (disconnect)** | Lock Mac · sleep displays · deactivate curtain. |

## Install

```bash
git clone https://github.com/acamarata/curtain.git
cd curtain
./Scripts/install.sh
```

The installer builds the app to `/Applications/Curtain.app`, generates the curtains icon, registers a login agent, and sets up a small root helper (one admin prompt) used to disconnect a Screen Sharing session.

Then, **once**:
1. Grant **Accessibility** to Curtain: System Settings → Privacy & Security → Accessibility. This lets it block desk input. (Curtain prompts you on first launch.)
2. Open Curtain (menu-bar icon, or launch the app) → **Set a password** and, if you use DisplayLink monitors, **Mark Externals as DisplayLink**.

Uninstall: `./Scripts/uninstall.sh`

## The settings window

Open it from the menu-bar curtains icon, or by launching Curtain.app. Everything is a toggle; changes take effect immediately.

### Application
- **Open at login** — run Curtain automatically (via `SMAppService`).
- **Show in menu bar** — show or hide the curtains icon. Hidden still runs in the background; reopen the app to get settings back.
- **Activate Now** / **Test (10s)** — show the curtain on demand.

### On session start
- **Activate curtain when a remote session begins** — the core behavior. Turn off to leave Curtain armed but passive.

### On session idle
- **Act after the session is idle** + **Idle timeout** (1–240 min).
- Independent toggles for what happens at idle: **Disconnect the remote session**, **Lock the Mac**, **Turn off the displays**, **Deactivate the curtain**.

### On session end (disconnect)
- Independent toggles: **Lock the Mac**, **Turn off the displays**, **Deactivate the curtain**.

### Security
- **Disconnect remote when password is entered at the desk** — on unlock, offer to kick the remote operator.
- **Set password** — typed at the desk to get past the curtain. Stored as a salted SHA256 hash. If unset, the default is `curtain` so you are never locked out.

### Displays
- **Identify Displays** — flashes each display's index and serial.
- **Mark Externals as DisplayLink** — marks every external monitor as DisplayLink.

## DisplayLink monitors

DisplayLink displays exist only through screen capture, so they can't be hidden invisibly the way directly-attached displays can. On those monitors the curtain also appears in your remote view. Native displays stay clear in your session while hidden at the desk. Mark your DisplayLink monitors in settings so they get covered correctly.

## Requirements

- macOS 13 (Ventura) or later. Built and used on macOS 26 / Apple Silicon.
- Screen Sharing enabled: System Settings → General → Sharing → Screen Sharing.
- Accessibility permission for Curtain (to block desk input).

## How it works / architecture / lessons

Full detail in the [wiki](../../wiki): architecture, the macOS APIs involved, and the lessons learned (including the things that did not work).

## License

MIT © Aric Camarata
