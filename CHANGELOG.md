# Changelog

All notable changes to Curtain are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Three-signal session detection: the `CGSSessionScreenIsCaptured` capture key
  (primary, transport-independent), an ESTABLISHED inbound TCP connection on
  port 5900 (standard Screen Sharing), and a peered UDP socket on 5900-5902
  (High-Performance Screen Sharing).
- Diagnostic probe (`Scripts/probe-detection.swift`) that reports every raw
  detection signal once per second and diffs the full CGSession dictionary.
- Per-signal diagnostic logging on every detection transition.
- Password box placement on a specific display, chosen from a picker of
  connected displays.
- Activation notification: a real notification banner when the curtain rises.
- Emergency escape: Control + Option + Command + U force-deactivates without
  Accessibility.

### Changed
- Idle detection honors its source setting; the default is now remote session
  activity, so the idle timer tracks the remote operator rather than the desk.
- Cover scope is a two-mode model: all displays (default) or per-display Cover
  toggles. Legacy scope values migrate automatically.
- The aerial cover style shares one video decoder across all displays.
- "Refuse to arm" (Accessibility missing) is enforced at the master switch.
- Release script: signing failures abort the build; the bundle version number
  increases monotonically with the repository history.

### Fixed
- Session detection: the network probe pointed at a nonexistent netstat path,
  which silently disabled the TCP activator.
- The per-display Cover toggle had no effect in the default scope and inverted
  meaning in one legacy scope.
- A curtain preview test could drop the cover of a live session after the
  preview delay.
- The desk password buffer is zeroed on successful unlock and on dismissal.
- A stale aerial playability check could tear down a rebuilt video player.
- The menu deactivate no longer refuses when the input tap is unavailable and
  the on-cover password box cannot receive keys.

## [1.0.0] — unreleased (pending live verification and notarization)

Initial release: menu-bar privacy curtain for macOS Screen Sharing hosts.
Covers all displays and blocks physical input during an inbound session;
desk password reveal; idle and end-of-session actions (disconnect, lock,
displays off, deactivate); configurable cover styles; optional privileged
disconnect helper; open-at-login.
