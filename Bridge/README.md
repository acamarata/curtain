# curtain-bridge

KVM automation bridge for Curtain's opt-in dogfood track. Runs as a standalone
`systemd` service on a Raspberry Pi driving a [TinyPilot](https://tinypilotkvm.com)
KVM-over-IP device, entirely independent of the protected Mac's own power and
network path. This is a **separate deployment artifact** from Curtain.app — it
lives in this repo for shared versioning/release process, but nothing here is
bundled into the macOS app, and Curtain.app never imports this code directly.

This directory is off by default and irrelevant unless you own TinyPilot-class
hardware. Most Curtain users can ignore it entirely.

## What it does (today)

This ticket (`T-P1-E11-01`) shipped the foundation:

- `curtain_bridge.tinypilot_client.TinyPilotClient` — a typed REST client for
  TinyPilot's documented API (auth, screenshot, keystroke, paste).
- `curtain_bridge.service.BridgeService` — a minimal asyncio daemon skeleton
  with config loading and a module-registration point.

`T-P1-E12-01` added the first real module on top of that skeleton:

- `curtain_bridge.detection.VideoMonitorModule` — polls
  `TinyPilotClient.get_screenshot()` on a fixed cadence and classifies each
  frame via `curtain_bridge.detection.detect_state()` as `NO_MATCH`,
  `FILEVAULT_PROMPT`, or `LOGIN_WINDOW` using OpenCV template matching
  (**not** a vision-model/LLM call — see "Video detection" below). This
  ticket is **detection-only**: no Telegram notification, no HID keystroke
  injection, no auto-unlock path exists anywhere in this codebase.

`T-P1-E12-02` added the human-in-the-loop Telegram confirmation channel on
top of that detection:

- `curtain_bridge.telegram_client.TelegramLoginModule` — on a
  `FILEVAULT_PROMPT`/`LOGIN_WINDOW` detection, sends a Telegram message
  asking the human to reply with the password; long-polls (`getUpdates`) for
  that reply in the same private chat, deletes the incoming reply message
  immediately after reading it (`deleteMessage`), and hands the plaintext
  password to an ephemeral in-process handoff callback — never to disk, never
  to a log line (see "Telegram integration" below). **Hard security
  boundary, unchanged by this ticket:** a human must send the password reply
  themselves, every single time; there is no auto-unlock path, no standing
  credential beyond the bot token itself, and no skip-confirmation toggle
  anywhere in this codebase. HID keystroke injection (actually typing the
  password into the Mac) is `T-P1-E12-03`'s scope, not this ticket's.

`T-P1-E12-03` completed the unlock flow by adding the HID-typing/re-lock step
on top of that Telegram channel:

- `curtain_bridge.hid_typing.HidUnlockModule` — wired as `TelegramLoginModule`'s
  `on_password` callback: types the human-confirmed password via HID exactly
  once, polls for a new, distinct `LOGGED_IN_DESKTOP` detection state, and on
  success re-locks the screen and sends `"ready for screen share"`; on
  timeout, sends a failure message and stops. **Hard security boundary,
  unchanged and most load-bearing in this ticket:** no auto-unlock path, no
  standing credential, and no retry loop exist anywhere — every attempt
  requires a fresh human-confirmed Telegram reply, and a second reply
  arriving mid-attempt is rejected, never queued or merged (see "HID typing
  and unlock flow" below).

`T-P1-E14-02` added an MCP (Model Context Protocol) server on top of the
TinyPilot client, entirely separate from the daemon above:

- `curtain_bridge.mcp_server` — a stdio MCP server (`curtain-bridge-mcp`
  console script) exposing exactly three tools: `curtain_kvm_screenshot`,
  `curtain_kvm_type`, and `curtain_kvm_power`. See "KVM Bridge MCP server"
  below for the full contract and the hard security boundary it maintains.

Later tickets (E-13: video monitoring extensions) build on `detection.py` and
`service.py` — they do not fork them.

## Requirements

- A Raspberry Pi running Raspberry Pi OS (Trixie or later recommended),
  Python **3.11+** (already present on Raspberry Pi OS Trixie by default).
- A TinyPilot device on the same network, reachable by hostname or IP, with
  its **Automation License** activated (see "Automation License" below — this
  is a TinyPilot prerequisite, not something curtain-bridge can do for you).

## Install (on the Pi, via SSH)

```bash
# From a checkout of this repo on the Pi:
cd Bridge
python3 -m venv /opt/curtain-bridge/venv
/opt/curtain-bridge/venv/bin/pip install .
```

This installs the `curtain-bridge` console script into the venv.

## Configure

Create a JSON config file, e.g. `/etc/curtain-bridge/config.json`:

```json
{
  "tinypilot_host": "tinypilot.local",
  "tinypilot_port": 80,
  "token_cache_path": "/var/lib/curtain-bridge/token",
  "relay_url": "http://192.168.1.60"
}
```

Only `tinypilot_host` is required. `tinypilot_port` and `token_cache_path`
fall back to the defaults shown above. `relay_url` is optional — set it only
if you have a Tasmota-compatible smart-plug relay wired to the KVM target's
power; omitting it means `curtain_kvm_power` (see "KVM Bridge MCP server"
below) fails explicitly rather than silently doing nothing. Unrecognized keys
are preserved and passed through for future modules (E-12/E-13) to read.

## Run directly (foreground, for testing)

```bash
/opt/curtain-bridge/venv/bin/curtain-bridge --config /etc/curtain-bridge/config.json
```

Or set `CURTAIN_BRIDGE_CONFIG` instead of passing `--config`. Press Ctrl+C to
stop; the service shuts down any registered modules cleanly.

## Run as a systemd service (production)

```bash
sudo cp systemd/curtain-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now curtain-bridge
```

Check status/logs:

```bash
sudo systemctl status curtain-bridge
sudo journalctl -u curtain-bridge -f
```

The unit file assumes the venv lives at `/opt/curtain-bridge/venv` and the
config at `/etc/curtain-bridge/config.json` — edit `systemd/curtain-bridge.service`
first if your paths differ. `T-P1-E11-02` (Curtain.app's SSH deploy wizard)
automates this install/configure/enable sequence end-to-end; this manual path
is for direct SSH operation or troubleshooting.

## Health endpoint

The Bridge exposes a `GET /health` endpoint on **port 8642** (distinct from
TinyPilot's own web UI/API, which defaults to port 80 — see
`tinypilot_port` above), returning:

```json
{"status": "ok", "version": "0.1.0", "uptime_seconds": 42}
```

`version` is always read live from the installed package's metadata
(`importlib.metadata.version("curtain-bridge")`) — never hardcoded — so it
reflects the actual running install, including immediately after an update
mechanism swap (see "Updating" below). Port 8642 was chosen specifically to
avoid colliding with TinyPilot's own port or other common service ports
(80/443/8080/8000); override it by setting `"health_port"` in the config
JSON if 8642 conflicts with something else on your network. Curtain.app's
setup wizard (`KVMBridgeDeployer.checkHealth`) calls this endpoint directly
over the LAN to verify the Bridge is reachable and to detect version skew,
falling back to an SSH-tunneled call if a direct connection isn't reachable
(see that file's doc comment for the reasoning).

## KVM Bridge MCP server

`curtain_bridge.mcp_server` hosts an MCP (Model Context Protocol) server
exposing exactly three tools for an MCP-capable agent to operate the KVM when
the Mac is not reachable by any software means at all (powered off, hung, or
its own login/FileVault/app-UI safeguards are up). This is deliberately
**not** a general "let an agent see the screen" mechanism — when the Mac is
up and logged in, existing computer-use-class agent tooling (native macOS
Accessibility APIs) already covers that better. These tools exist for exactly
one situation: total software unreachability.

**Hard security boundary, non-negotiable:** neither this server nor
Curtain.app's own Mac-side MCP server (`curtain_status`, T-P1-E14-01) may
ever expose the ability to change Curtain's own privacy/security settings
(arm state, password, cover appearance, or any `Settings.swift`-backed key).
This is the higher-risk of the two MCP surfaces, since it is reachable
*exactly* when the Mac's own login/FileVault/app-UI safeguards are bypassed —
so its test suite (`Bridge/tests/test_mcp_server.py`) is more exhaustive than
the baseline: it enumerates the exact tool list, inspects every tool's
parameter schema for anything Settings-shaped, greps (AST-scoped, excluding
doc-comment prose) for any reference to password-storage or the E-12
Telegram-flow code, and attempts misuse against `curtain_kvm_type` with
probe strings crafted to look like password-retrieval attempts. This process
runs on the Pi, in a separate OS process on separate hardware from
Curtain.app — there is no shared memory, IPC channel, or callback of any
kind back to the Mac's `Settings`/`SessionCoordinator` state, verified by the
test suite rather than merely assumed.

The three tools:

- **`curtain_kvm_screenshot`** — wraps `TinyPilotClient.get_screenshot()`.
  Takes no parameters. Returns base64-encoded JPEG image data, or a
  `no_signal` status if the target has no video output.
- **`curtain_kvm_type`** — a generic HID-typing tool wrapping
  `TinyPilotClient.send_keystroke()`, one call per character, resolved via
  the same `hid_keymap.keystroke_for_char()` table `HidUnlockModule` uses for
  password entry — reused ONLY for its stateless character-to-HID-keycode
  mapping, not for any password-flow logic. Takes one parameter, `text` (the
  literal string to type — nothing else). It types exactly what it is given,
  sourced only from the MCP call's own argument, never from local storage, a
  file, an environment variable, or any other persisted value, and has zero
  code path to Curtain's stored password or the Telegram-confirmed unlock
  flow (`telegram_client.py`, `hid_typing.py`'s `HidUnlockModule`) — those
  modules are never imported by `mcp_server.py`.
- **`curtain_kvm_power`** — power-cycles the KVM target machine via a
  [Tasmota](https://tasmota.github.io/docs/Commands/#power)-compatible
  smart-plug relay's local HTTP "Console command" API
  (`GET /cm?cmnd=Power<On|Off|Toggle>`), implemented in
  `curtain_bridge.relay_client.RelayClient`. Direct Pi-GPIO relay control was
  considered and rejected (see `relay_client.py`'s module doc comment): a
  local-HTTP relay is reachable from wherever `curtain-bridge` happens to
  run, rather than coupling this process's identity to specific physical
  wiring. Takes one parameter, `action` (`"on"` / `"off"` / `"cycle"`).
  **Requires physical relay hardware** — set `"relay_url"` (e.g.
  `"http://192.168.1.60"`) in the Bridge config JSON. Without a configured or
  reachable relay, this tool fails explicitly (`{"status": "error", ...}`),
  never a fake success — this is documented, intentional behavior for any
  install with no relay attached, not a stub awaiting completion.

**Transport:** stdio, via the official
[MCP Python SDK](https://pypi.org/project/mcp/) (`mcp>=1.28,<2`, pinned to
the stable v1.x line since v2 is a documented breaking rework), using its
high-level `FastMCP` API. Run it directly (typically spawned by whatever MCP
client you configure to point at it):

```bash
/opt/curtain-bridge/venv/bin/curtain-bridge-mcp --config /etc/curtain-bridge/config.json
```

This is a **separate process** from the `curtain-bridge` daemon above, not a
`BridgeModule` registered into it — an MCP stdio server owns stdin/stdout for
the lifetime of one client connection and is spawned per-connection by the
MCP client itself, the standard deployment shape for a stdio MCP server. It
introduces zero new network exposure: stdio has no network surface at all,
narrower than `health.py`'s and `crash_relay.py`'s loopback-bound HTTP
listeners. It reads the same config JSON as `curtain-bridge` (`tinypilot_host`
plus the new optional `relay_url` key) — one config file, one source of
truth for both processes.

## Video detection (FileVault / login-window / logged-in desktop)

`curtain_bridge.detection` recognizes three Mac boot/login/unlocked states
purely from TinyPilot screenshot captures, using OpenCV template matching
(`cv2.matchTemplate`, normalized cross-correlation) against three checked-in
reference images — **never** a vision-model/LLM API call, both because
macOS's login/FileVault/desktop screens are visually consistent enough that
template matching is sufficient, and because sending login-screen video to
any third-party AI service is unacceptable given what this Mac protects.

- `detect_state(screenshot_bytes) -> DetectionResult` returns a typed
  `DetectionState` (`NO_MATCH` / `FILEVAULT_PROMPT` / `LOGIN_WINDOW` /
  `LOGGED_IN_DESKTOP`) plus a confidence score, gated by
  `CONFIDENCE_THRESHOLD = 0.8`. Ties resolve in the fixed order
  `FILEVAULT_PROMPT` → `LOGIN_WINDOW` → `LOGGED_IN_DESKTOP`.
- `VideoMonitorModule` is a `BridgeModule` that polls
  `TinyPilotClient.get_screenshot()` every `POLL_INTERVAL_SECONDS = 3.0`
  seconds and invokes a caller-supplied callback with each result.
- Reference templates live at
  `curtain_bridge/fixtures/templates/{filevault_prompt,login_window,logged_in_desktop}.png`.
  **These are synthetic composites** (a generated padlock/password-field
  crop, a generated avatar/password-field crop, and a generated
  Control-Center-pill + battery-glyph menu-bar crop for the logged-in-desktop
  state), not real macOS screenshots — see "What is NOT verified yet" below.

**Hard security boundary:** this module only classifies frames. It does not
send a Telegram message, does not inject a keystroke, and does not cache or
act on a credential — no auto-unlock path exists anywhere in this repo. A
human must confirm every unlock action via the Telegram flow (T-P1-E12-02)
before `HidUnlockModule` (T-P1-E12-03) acts on a detection result.

## HID typing and unlock flow

`curtain_bridge.hid_typing.HidUnlockModule` is the orchestrator that
completes the unlock flow, wired as `TelegramLoginModule`'s `on_password`
callback (see `service.py`'s registration-point comment for the exact wiring):

1. **Type once.** `handle_password(password)` sends the password through
   `curtain_bridge.hid_keymap.keystroke_for_char()` one character at a time,
   each resolved to a real US-QWERTY HID keystroke (`TinyPilotClient.
   send_keystroke`) — bare key for lowercase/digits, `shiftLeft` for
   uppercase/shifted symbols. A character with no US-QWERTY representation
   raises `UnsupportedCharacterError` and the flow stops immediately (no
   partial-guessing, no substitution).
2. **Poll for confirmed success.** After typing, it polls a `DetectionPoller`
   (a `LatestStateTracker`, fed by `VideoMonitorModule`'s `on_detection`
   callback) for up to `POST_TYPE_TIMEOUT_SECONDS = 45.0` seconds, watching
   specifically for `LOGGED_IN_DESKTOP` — never assuming success just because
   typing finished.
3. **Success:** injects the standard macOS lock-screen combo
   (`RELOCK_KEYSTROKE` — Control+Command+Q) via HID, then sends
   `"ready for screen share"` over Telegram.
4. **Failure/timeout:** sends a Telegram failure message and stops — no
   retype, no loop, no guessing. The only way to try again is a fresh
   Telegram reply that restarts the whole flow via T-P1-E12-02 independently.

**Hard security boundary, non-negotiable — this is the ticket where it
matters most:** no auto-unlock path, no standing/cached credential, and no
retry loop exist anywhere in this module. `_typing_in_progress` guards the
**entire** attempt (typing, the detection poll, and the re-lock/failure
step) — a second Telegram reply arriving at any point during an in-flight
attempt is rejected with a Telegram message telling the human to wait, never
queued, merged, or allowed to type a second time concurrently. The `finally`
block resetting that guard runs unconditionally, so an exception mid-flow
(e.g. an unsupported character) can never leave the module stuck refusing
all future legitimate attempts. The password value is never assigned to
`self`, never logged, and goes out of scope at the end of `handle_password`'s
call frame.

## Updating

`curtain_bridge.updater.apply_update(new_package_path)` implements a
stage-validate-swap-confirm update mechanism, triggered by Curtain.app's
deployer over SSH once it detects a genuine version mismatch via `/health`:

1. **Stage** — installs the new version into a fresh venv under
   `/opt/curtain-bridge/staged/`, entirely separate from the currently-running
   install.
2. **Validate** — imports the staged package, runs a lightweight self-check,
   and confirms `curtain-bridge --version` responds — all against the staged
   venv only.
3. **Swap** — only if validation passes: flips the `/opt/curtain-bridge/venv`
   symlink to the new staged venv and restarts the `curtain-bridge` systemd
   service.
4. **Confirm** — polls `/health` to confirm the restarted service is
   genuinely serving the new version.
5. **Rollback** — if step 3 or 4 fails, the symlink is reverted to the
   previous install and the service is restarted again, so the Pi is never
   left with a broken or absent Bridge. This requires the `pilot` user to
   have passwordless `sudo` for `systemctl restart curtain-bridge` (the same
   assumption `KVMBridgeDeployer.swift`'s existing SSH deploy script already
   makes for `systemctl enable --now`).

If step 5's rollback itself cannot restore a running service (e.g. systemd
is broken for an unrelated reason), `apply_update` reports this explicitly
as requiring manual intervention rather than silently claiming success —
see `updater.py`'s module doc comment and `Bridge/tests/test_updater.py`
for the exact guarantees this is tested against.

## Automation License

TinyPilot requires a paid, per-device "Automation License" to be activated on
the Pi itself before any REST API call (auth, screenshot, keystroke, paste)
will succeed. Activate it once, on the Pi:

```bash
sudo su tinypilot bash -c "/opt/tinypilot/scripts/activate-license $LICENSE_KEY"
```

See <https://tinypilotkvm.com/pages/automation> for how to obtain a license
key. If the license is not active, `TinyPilotClient` raises a
`TinyPilotLicenseError` (rather than a generic HTTP error) — see the docstring
on that exception in `curtain_bridge/tinypilot_client.py` for the current
detection heuristic and its known limitation.

## Telegram integration

`curtain_bridge.telegram_client` implements the human-in-the-loop
confirmation channel that fires when `detection.py` classifies a frame as
`FILEVAULT_PROMPT` or `LOGIN_WINDOW`:

- `TelegramClient` — a typed wrapper around Telegram's documented
  [Bot API](https://core.telegram.org/bots/api): `sendMessage`, `getUpdates`
  (long-polling), and `deleteMessage`, against the real
  `{"ok", "result"/"error_code"/"description"/"parameters"}` response
  envelope, with typed exceptions for rate-limiting (429, honors
  `retry_after`) and an invalid/revoked token (401).
- `TelegramLoginModule` — a `BridgeModule` that sends the prompt on
  detection and long-polls for the reply. **Long-polling, not a webhook**:
  the Pi has no public inbound port, reverse proxy, or TLS termination (see
  "Requirements" above — it's reached by hostname/IP on the local network
  only), so a webhook would require exposing a certificate-bearing HTTPS
  endpoint on the user's home network for no real benefit over one held-open
  outbound long-poll connection.
- `load_bot_token()` reads the bot token from
  `/etc/curtain-bridge/telegram-token` — the exact path Curtain.app's setup
  wizard (`KVMBridgeDeployer.sendTelegramToken`) already delivers it to over
  SSH stdin (never a shell-interpolated argument, never persisted on the
  Mac). This is the same token-only credential the wizard's "Create a
  Telegram bot" step (Preferences → Advanced → "Set Up KVM Bridge…") walks
  you through obtaining from `@BotFather`.
- **Chat-id discovery:** the setup wizard only captures the bot token, not
  who talks to it. `TelegramLoginModule` learns and pins the `chat_id` from
  the first message the human sends their new bot (e.g. `/start`) — that
  first message is deleted for hygiene but never treated as a password.
  Every message after that must come from the exact pinned `chat_id`; a
  message from any other chat is logged and ignored, never re-pinned.

**Hard security boundary, non-negotiable:** this module never unlocks
anything on its own. It only ever sends a prompt and waits for a human to
type a reply into Telegram. The password value is read into a local
variable, its source message is deleted via the Bot API, the value is
handed to a single ephemeral callback (`HidUnlockModule.handle_password`,
T-P1-E12-03, consumes it — see "HID typing and unlock flow" above), and the
local reference is dropped immediately — it is never written to disk, never
logged at any level, and never cached anywhere. No auto-unlock path,
standing credential, or skip-confirmation toggle exists anywhere in this
codebase.

## Development / running tests

```bash
cd Bridge
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
.venv/bin/pytest
```

All tests mock TinyPilot's and Telegram's HTTP responses — no real hardware,
network access, or live bot token is required to run the suite.

## What is NOT verified yet (flagged for live-hardware verification)

This ticket was built and tested entirely against TinyPilot's **documented**
REST contract, without physical hardware in hand. The following are
explicitly unverified until a real TinyPilot device is available:

- The exact response shape when the Automation License is inactive/expired
  (the docs don't fully specify this; see `TinyPilotLicenseError`'s docstring).
- Real-world screenshot JPEG byte validity against an actual video feed.
- Real keystroke/paste forwarding latency and behavior against a live target
  machine.
- The `systemd` unit's correctness when actually executed on Raspberry Pi OS
  Trixie (it has only been syntax-checked, not run, on real hardware).
- Real FileVault/login-window/logged-in-desktop template-matching accuracy
  against an actual TinyPilot HDMI capture (`curtain_bridge.detection`,
  T-P1-E12-01, extended T-P1-E12-03) — the reference templates and test
  fixtures are synthetic Pillow-generated composites, not real captures.
  Specifically unverified until hardware is in hand: real HDMI capture
  resolution/scaling, color-profile variance versus the synthetic fixtures'
  flat RGB, and the actual frame rate/JPEG compression the Pi delivers.
  `CONFIDENCE_THRESHOLD` may need retuning once real captures are available
  to test against. This applies to `logged_in_desktop.png` specifically as
  much as to the original two templates — it has not been validated against
  a real macOS menu bar's actual Control Center/battery icon rendering.
- Real end-to-end Telegram flow against a live bot token and a real Telegram
  chat (`curtain_bridge.telegram_client`, T-P1-E12-02) — no bot token was
  available this session, so every test runs against a mocked API surface
  matching Telegram's documented contract. Provisioning a real bot via
  `@BotFather`, running the setup wizard's Telegram step against live
  hardware, and confirming a real send → reply → delete round trip remains
  the required last step before this integration is considered fully
  verified.
- Real HID password typing and re-lock against an actual TinyPilot device
  and a real Mac (`curtain_bridge.hid_typing`, T-P1-E12-03) — the
  character-to-HID-keycode mapping in `hid_keymap.py` is built directly from
  TinyPilot's documented `/api/v1/keystroke` contract and standard
  US-QWERTY layout knowledge, but has never been exercised against a real
  KVM-emulated USB keyboard or a real macOS password field; real keystroke
  forwarding latency (each password character is one full HTTP round trip)
  could plausibly matter for longer passwords and is unverified. The
  `POST_TYPE_TIMEOUT_SECONDS = 45.0` bound is reasoned from typical macOS
  login-animation duration, not measured against a real device. The
  Control+Command+Q re-lock combo's real-world reliability (whether macOS
  always honors it from every possible post-login focus state) is likewise
  unverified until hardware is in hand.
