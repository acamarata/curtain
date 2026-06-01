# Curtain

A privacy curtain for macOS Screen Sharing. When you remote into your Mac, Curtain hides the screen from anyone sitting at it and makes the local keyboard and mouse do nothing — while you keep full control from your laptop. When the session ends or goes idle, it locks the Mac and sleeps the displays.

macOS already does Screen Sharing well. Curtain is *only* the missing privacy layer around it — a lightweight menu-bar agent, in the spirit of Caffeine.

## What it does

| Event | Behavior |
|---|---|
| **Screen Sharing connects** | Curtain covers every physical display. The local keyboard/mouse are blocked from the apps; your remote keyboard/mouse work normally. A password box appears if someone presses a key at the desk. |
| **Password entered at the desk** | Ends the remote session and reveals the desktop (asks first). |
| **Session idle ~30 min** | Disconnects the remote session, locks the Mac, sleeps the displays. |
| **You disconnect** | Locks the Mac, sleeps the displays. |

The key trick: macOS tags real hardware input differently from injected remote input, so Curtain blocks the desk's keyboard/mouse while letting your remote control pass through — on the same login session, no virtual display needed.

## Install

```bash
git clone https://github.com/acamarata/curtain.git
cd curtain
./Scripts/install.sh
```

Then grant **Accessibility** to Curtain in System Settings → Privacy & Security → Accessibility (required so it can block desk input). From the menu-bar icon: **Set Password…** and, if you use DisplayLink monitors, **Mark Current Externals as DisplayLink**.

Uninstall: `./Scripts/uninstall.sh`

## Requirements

- macOS 13 (Ventura) or later — built and used on macOS 26 / Apple Silicon
- Screen Sharing enabled (System Settings → General → Sharing → Screen Sharing)

## A note on DisplayLink monitors

DisplayLink displays exist only through screen capture, so they can't be hidden invisibly the way native displays can. On those monitors the curtain also shows in your remote view. Native (directly-attached) displays are hidden from onlookers while staying clear in your remote session.

## How it works / lessons

See the [wiki](../../wiki) for the architecture, the macOS APIs involved, and the (many) lessons learned building this.

## License

MIT © Aric Camarata
