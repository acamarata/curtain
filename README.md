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

**If your download is notarized** (a Developer-ID-signed release from the Releases page), Gatekeeper accepts it on first launch. No extra step needed.

**If you built from source, or your release predates notarization,** the app is ad-hoc signed and carries no Apple notarization ticket, so Gatekeeper refuses the first launch. Clear the quarantine flag once, then open the app:

```bash
xattr -dr com.apple.quarantine /Applications/Curtain.app
```

This is the expected, correct step for a source build without a Developer ID, not a workaround to avoid.

Either way, verify the DMG against its published SHA-256 before installing (the `.sha256` file is attached to the release):

```bash
shasum -a 256 Curtain-1.0.0.dmg
```

The checksum confirms the file you downloaded is byte-for-byte what was published; it protects against a corrupted download or a tampered mirror. It says nothing about whether Apple has scanned or signed the binary. Notarization is a separate, independent guarantee. When a notarized release is available, do both: check the SHA-256 and rely on Gatekeeper's notarization check. An ad-hoc build only has the checksum guarantee.

## Settings

Everything is a setting. Open the window from the menu-bar curtains icon or by reopening `Curtain.app`. Changes take effect immediately. You control arming, what the desk sees (solid color, message, blur, lock logo, Curtain logo, or aerial video), the reveal trigger, the idle and disconnect actions, the idle source (remote session activity or physical HID), the password and idle timeout, what happens to the remote session on unlock, per-display cover scope, password-box placement, and DisplayLink marking. See the [Settings](../../wiki/Settings) page for the full reference.

## MCP server (optional, off by default)

Curtain can host a local, loopback-only MCP server exposing one read-only tool, `curtain_status` (armed state, whether a remote session is active, last heartbeat timestamp). It is off by default and cannot mutate any setting — no arm/disarm, no password change, no screen viewing or remote control. A toggle for it lives in the hidden-by-default KVM section of Preferences (see below); see the [Settings](../../wiki/Settings) page's "MCP server" section for the exact protocol details.

## Multi-display note

Curtain covers every physical display. The Apple Screen Sharing app shows one host display at a time, so on a multi-monitor Mac you switch between them in its View menu. That is standard Screen Sharing behavior, not something Curtain changes.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon (built and tested on a Mac Mini M4 running macOS 26)
- Screen Sharing enabled (System Settings, General, Sharing, Screen Sharing)
- Accessibility permission for Curtain

## Documentation

The [wiki](../../wiki) covers everything in depth: [Installation](../../wiki/Installation), [Settings](../../wiki/Settings), [How It Works](../../wiki/How-It-Works), [Architecture](../../wiki/Architecture), [Security](../../wiki/Security), [Lessons Learned](../../wiki/Lessons-Learned), and [Troubleshooting](../../wiki/Troubleshooting).

## KVM Bridge (optional, off by default)

`Bridge/` is a separate, opt-in companion project for owners of TinyPilot-class KVM-over-IP hardware: a Python daemon that runs on the Pi itself (not on the Mac) to provide a network-independent recovery path when the Mac is unreachable. It is irrelevant to the Curtain.app experience above. See [`Bridge/README.md`](Bridge/README.md) for setup.

Curtain.app itself ships a setup wizard (Preferences → Advanced → "Set Up KVM Bridge…") that deploys `Bridge/` to a TinyPilot Pi over real SSH: it collects the Pi's address and SSH credentials, shows the Pi's host-key fingerprint for explicit confirmation before connecting, rsyncs the package and installs/starts its systemd service, and walks through creating a Telegram bot via [@BotFather](https://t.me/BotFather) to relay the resulting token straight to the Pi. The wizard runs entirely on the Mac but never executes any KVM-automation logic itself, and the Telegram token is never written to Mac-side storage (Keychain, UserDefaults, or disk) — it only ever passes through to the Pi over the same SSH channel. This is code-complete but hardware-unverified: it has been tested against mocked SSH invocations and is ready for a real TinyPilot Pi once one is available; see the wiki's Architecture page for the exact verification status.

Clicking that button also reveals a new, otherwise-hidden **KVM** section in the Preferences sidebar — invisible to the vast majority of users who don't own this hardware, and the only documented way to reveal it. It gathers the setup-wizard entry point, an honest status readout for Telegram login (there is genuinely no Mac-side switch for it — the token lives only on the Pi), a shortcut to the same per-display "never cover" list as the Displays tab, and the MCP-server toggle above, in one place. See the [Settings](../../wiki/Settings) page's "KVM (hidden by default)" section for the full breakdown.

After a Telegram-recovery unlock, Curtain.app also checks `/Library/Logs/DiagnosticReports/` on its next launch and — only when the launch looks like it followed an unattended crash/reboot (compared against E-10's heartbeat and the system's actual boot time, not an ordinary restart) — relays a short crash-cause summary to the Bridge, which forwards it to the same Telegram chat. This relays through the Bridge rather than sending from the Mac directly, so the bot token never needs a second, durable home on the protected Mac; see `CHANGELOG.md`'s Unreleased/Added entry for the full reasoning.

The Bridge can also host its own MCP server (`curtain-bridge-mcp`), separate from Curtain.app's own Mac-side one above: exactly three tools — `curtain_kvm_screenshot`, `curtain_kvm_type`, `curtain_kvm_power` — for KVM recovery when the Mac is unreachable by any software means. Same hard boundary as the Mac-side server, verified more exhaustively since this is the higher-risk surface: it can never touch Curtain's own settings, arm state, or password. See the [Settings](../../wiki/Settings) page's "KVM Bridge MCP server" section.

## Release process (maintainers)

Pushing a `v*` tag (or running the workflow manually via `workflow_dispatch`) triggers `.github/workflows/release.yml`, which builds, signs, notarizes (when the notary secrets are configured), and packages `Scripts/release.sh`'s output, then uploads `Curtain-*.dmg` and `Curtain-*.dmg.sha256` as a downloadable CI build artifact.

CI deliberately stops there — it does not publish a public GitHub Release. This is a first-run pipeline with no track record yet, and a bug in the tag trigger or a `workflow_dispatch` misfire publishing an unreviewed, possibly-broken signed build straight to end users is a real risk worth avoiding until the pipeline has proven itself across several runs. Publishing stays a deliberate, reviewed, manual step:

1. Download the artifact from the Actions run.
2. Verify the checksum: `shasum -a 256 Curtain-*.dmg` and compare against the `.sha256` file.
3. Publish it: `gh release create --generate-notes <tag> dist/Curtain-*.dmg dist/Curtain-*.dmg.sha256`.

Full automation (CI publishing the Release itself) is a candidate fast-follow once the tag-triggered workflow has run reliably several times.

## License

MIT © Aric Camarata
