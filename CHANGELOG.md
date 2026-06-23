# Changelog

All notable changes to Curtain are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-06-10

First public release. Curtain is a menu-bar app for the host side of macOS
Screen Sharing: when a remote session is active it covers every display and
blocks physical input at the desk, so the screen you control remotely stays
private from anyone sitting in front of the Mac.

### Added
- Cover all displays and block desk keyboard and mouse while a remote Screen
  Sharing session is active, after an optional connect grace delay.
- Session detection on three independent signals: the `CGSSessionScreenIsCaptured`
  capture key (primary, transport-independent), an ESTABLISHED inbound TCP
  connection on port 5900 (standard Screen Sharing), and a peered UDP socket on
  5900-5902 (High-Performance Screen Sharing). Process presence and idle listen
  sockets never trigger activation, so an enabled-but-idle Mac is never covered.
- Desk password to reveal the screen, with a built-in `curtain` fallback so the
  Mac is never permanently locked. Password is stored as a salted
  PBKDF2-HMAC-SHA256 hash with attempt backoff.
- Idle actions: when the remote operator goes idle for a configurable time, run
  any of disconnect, lock, displays off, deactivate.
- End-of-session actions: when the remote session ends, run any of lock,
  displays off, deactivate.
- Cover styles: solid color, message, blur, logo, and an aerial video that
  shares one decoder across all displays. Optional clock overlay.
- Per-display cover control: choose all displays or per-display toggles, mark
  DisplayLink monitors, and place the password box on a specific display.
- Optional privileged helper to disconnect the remote session, off by default
  and installed only on explicit opt-in.
- Open at login via `SMAppService`, optional menu-bar item, and a first-run
  onboarding flow.
- Emergency escape: Control + Option + Command + U force-deactivates the curtain
  without Accessibility. When Accessibility is not granted, Curtain refuses to
  cover rather than putting up a screen it cannot unlock.
- Diagnostic probe (`Scripts/probe-detection.swift`) that prints every raw
  detection signal once per second and diffs the full CGSession dictionary.

### Known limitations
- Ad-hoc signed, not notarized. macOS Gatekeeper warns on first launch; clear
  the quarantine flag once with
  `xattr -dr com.apple.quarantine /Applications/Curtain.app`.
- The capture-key and High-Performance UDP detection paths are verified by unit
  tests and on-device probes but not yet against a second physical Mac. Standard
  (TCP) Screen Sharing detection is verified end-to-end.
- The physical-versus-remote input split is a convenience filter, not a security
  boundary. Curtain hides your screen from someone at the desk; it is not a
  defense against local malware.
