# Security

This page describes what Curtain protects against, what it does not, and how its sensitive pieces work. Read it before you rely on Curtain for anything that matters to you.

## Threat model

Curtain is built for one situation: you own a Mac, you are remoting into it from your own laptop, and someone is physically sitting at that Mac's desk. Curtain hides your screen from that person and stops the desk keyboard and mouse from reaching your apps while you keep full control from the remote side.

That is the whole scope. Curtain is **not** a defense against malicious software already running on the Mac. If an attacker can run code on your machine, they can read your screen, log your keys, and bypass Curtain directly. Treat Curtain as a privacy curtain against a person at the desk, not as a security product against software.

## Input filtering is a convenience filter, not a security boundary

Curtain blocks desk input with a `CGEventTap` that classifies each event as physical or remote. The test is `eventSourceStateID == 1`, which macOS sets for real hardware events. Curtain drops those and passes everything else.

This works against a person typing on the desk keyboard. It does not stop a local program. Any process with the right APIs can post synthetic events and choose which classification they carry, so it could spoof an event as either physical or remote. A malicious local process is therefore out of scope by design. The filter is a convenience that ignores the desk's hardware, not a wall that a determined program cannot climb over.

## Password storage

The desk-unlock password (the one that reveals the desktop when someone presses a key at the desk) is never stored in plaintext. Curtain keeps a PBKDF2-HMAC-SHA256 hash, salted, run at roughly 200,000 iterations, in the app's UserDefaults plist. Wrong guesses trigger a repeated-attempt backoff that slows brute forcing.

If you never set a password, the default is `curtain`. That default exists so you can never lock yourself out of your own Mac. It is an unlock convenience, not full-disk security. Anyone who reads this page knows the default, so set your own password if the desk is not trusted, and remember that this protects the curtain reveal, not your data at rest. For data at rest, use FileVault.

## Emergency unlock and no-Accessibility safety

Three design choices make sure you can never be trapped behind the curtain, and never silently unprotected while it looks active:

- **Emergency hotkey.** Pressing **Control + Option + Command + U** at the desk force-deactivates the curtain. It is registered as a Carbon hotkey, so it fires even when Accessibility has not been granted. This is the guaranteed escape regardless of state.
- **No cover without Accessibility.** The input block depends on the Accessibility grant. If Accessibility is not granted, Curtain refuses to show the cover at all and notifies you, rather than putting up a screen it cannot unlock. You get a passive, clearly flagged state instead of a locked-out one.
- **Mid-session revocation is caught, not silent.** The two checks above only run at activation time. If Accessibility is revoked while a cover is already up, either by direct user action in System Settings or by a signature change dropping the grant, as a local ad-hoc rebuild does, the checks above alone would leave the cover visually up while the desk was silently unblocked. Curtain closes that gap: `SessionCoordinator` re-verifies `AXIsProcessTrusted()` every tick (about once a second) while a session is active. The check is edge-triggered, so it only acts on an actual change. The moment revocation is detected, Curtain logs it and shows the same warning banner already used for the not-granted case ("Desk input not blocked — grant Accessibility in System Settings"), directly on the cover. Re-granting Accessibility clears the banner on the next tick. "Curtain is protecting me" stays either true, or loudly and visibly false, for the whole session, not just at the moment it started.

## The optional disconnect helper

Ending the remote Screen Sharing session from the Mac side needs elevated rights. This is **off by default**, and most people never turn it on or see an admin prompt.

When you enable it, Curtain installs a privileged helper. On a notarized or Developer-ID build it registers a daemon through `SMAppService.daemon`, the current Apple API for this. The app talks to the helper over XPC, and the helper checks the caller's code signature before doing anything. On a local ad-hoc or dev build, which cannot register an `SMAppService` daemon, Curtain falls back to a small privileged helper installed with one admin prompt, scoped to the current user. A public notarized build never installs a sudoers rule. The older approach of dropping a NOPASSWD entry into sudoers for everyone is gone.

The helper resolves each connecting caller's identity from the XPC connection's kernel-issued audit token (not the process ID), so the check is bound to the exact peer that opened the connection rather than a PID that could, in principle, be reused by a different process between being reported and being checked. On a signed build the caller's Team ID must match the helper's; on an unsigned ad-hoc/dev build there is no Team ID to check against, so the helper falls back to identifier-and-anchor validation only and logs that relaxation loudly. Since v2.0.3 released builds are Developer-ID signed, so the full Team ID check applies to them; the relaxed fallback now only affects local ad-hoc and source builds.

When the helper ends a Screen Sharing session, it does not match target processes by scanning command-line text. It enumerates every running process, resolves each one's real executable path, and only signals a process whose path is an exact match for one of the fixed system locations of the screen-sharing session binaries — an attacker-named-alike process cannot be caught by, or dodge, a broad text pattern this way, because none of its command-line arguments are ever inspected.

The one-time admin prompt itself runs the requested command through `osascript` with a fixed, static `on run argv` script, passing the command as a plain process argument rather than splicing it into the AppleScript source text. The command string is never parsed as AppleScript, so there is no AppleScript-string-escaping step that a future change could get subtly wrong. Today, the only values that path ever runs are fixed install/remove commands built from constant paths and base64-encoded content — nothing user-controlled reaches it.

## Private API for locking

Locking the Mac calls `SACLockScreenImmediate` from Apple's `login.framework`, loaded at runtime with `dlopen`. This is a private symbol, so a documented fallback path exists in case it is unavailable. All of this runs on your own machine against your own login session.

## Permissions

Curtain needs exactly one TCC permission: Accessibility, granted once after install, so it can run the event tap that blocks desk input. It does not run in the App Sandbox, because a sandbox is incompatible with a global event tap. It requests no network access.

The activation trigger is deliberately narrow. Curtain raises the cover only when one of three signals fires: `CGSSessionScreenIsCaptured` (primary), a genuinely ESTABLISHED inbound TCP connection on port 5900, or a peered UDP socket on ports 5900-5902. A lingering Screen Sharing process, an idle `:5900` LISTEN socket, or a wildcard UDP socket does not activate it, which prevents false activation while the machine is simply listening for connections.

## Distribution trust

`Scripts/release.sh` supports two build paths. Without signing credentials set (`SIGN_IDENTITY` and a notary credential source), it produces an ad-hoc-signed build: verify the published SHA-256 of the `.dmg`, then strip the quarantine flag once (see Installation). With `SIGN_IDENTITY` and a notary credential source set — a notarytool keychain profile, an App Store Connect API key (`CURTAIN_NOTARY_KEY` + `CURTAIN_NOTARY_KEY_ID` + `CURTAIN_NOTARY_ISSUER`), or an Apple ID with an app-specific password — it produces a Developer-ID-signed, notarized build instead.

**v2.0.3 is the first published notarized release.** Both the `.dmg` and the app inside it are signed, notarized and stapled, so Gatekeeper accepts a download directly with no quarantine strip, and the stapled ticket means the check succeeds offline. v1.0.0 through v2.0.2 shipped ad-hoc.

The SHA-256 check and the notarization check are independent guarantees and neither substitutes for the other: the checksum proves you got the bytes that were published, notarization proves Apple scanned and the signature is a real Developer ID. Do both — see the README's Install section for the exact wording.

## Multi-display behavior

Curtain never leaves a display exposed at the desk. Native displays are hidden from the remote viewer with `sharingType = .none`, so the remote session does not even see them. DisplayLink displays cannot be hidden that way, so Curtain covers them with a visible cover (`.readOnly`). Either way the desk sees a cover, not your work. A display Curtain does not recognize is covered by default rather than left open.
