# Curtain

Curtain is a privacy layer for macOS Screen Sharing. When you connect remotely to your Mac, it covers the physical displays so no one at the desk can see what you're doing, and it makes the desk keyboard and mouse inert. When the session ends or goes idle, it locks the Mac and sleeps the displays.

It lives in the menu bar. It does one job.

## Behavior

| Event | What happens |
|---|---|
| **Screen Sharing connects** | Every physical display goes black. Desk keyboard and mouse are blocked from reaching apps. Remote keyboard and mouse work normally. |
| **Someone presses a key at the desk** | A password box appears over the curtain. |
| **Correct password entered at the desk** | Curtain drops, remote session ends (you're asked to confirm). |
| **Session idle for ~30 minutes** | Remote session is disconnected, Mac locks, displays sleep. |
| **Remote operator disconnects** | Mac locks, displays sleep. |

## Requirements

- macOS 13 (Ventura) or later. Built and used on macOS 26 / Apple Silicon.
- Screen Sharing enabled: System Settings > General > Sharing > Screen Sharing.
- Accessibility permission granted to Curtain (required for desk input blocking).

## Pages

- [Installation](Installation) — clone, run the install script, grant Accessibility, set a password.
- [How It Works](How-It-Works) — plain-language explanation of the lifecycle and the physical-vs-remote input trick.
- [Architecture](Architecture) — module breakdown, key APIs, and data flow.
- [Lessons Learned](Lessons-Learned) — what was discovered building this, including things that did not work.
- [Troubleshooting](Troubleshooting) — common issues and how to fix them.

## A note on DisplayLink monitors

DisplayLink displays exist only through screen capture. Because of how the curtain window hides itself from screen capture, those monitors cannot be hidden invisibly. On a DisplayLink monitor the curtain shows in your remote view too. Native (directly attached) displays are hidden from the desk while staying clear on your remote screen.

See [How It Works](How-It-Works#displaylink) for details.
