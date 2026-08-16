"""
Purpose: Bridge-side MCP server exposing exactly three tools --
         `curtain_kvm_screenshot`, `curtain_kvm_type`, `curtain_kvm_power` --
         so an MCP-capable agent can operate the KVM when the protected Mac
         is not reachable by any software means at all (the Mac is powered
         off, hung, or its own login/FileVault/app-UI safeguards are up).
         This is the HIGHER-RISK of the two MCP surfaces in E-14 (the other
         being T-P1-E14-01's Mac-side, read-only `curtain_status`), precisely
         because it is reachable exactly when the Mac's own safeguards are
         bypassed -- see the HARD SECURITY BOUNDARY below, which this
         module's adversarial test suite (tests/test_mcp_server.py) verifies
         more exhaustively than T-P1-E14-01's baseline.
Inputs: constructed from a `TinyPilotClient` (E-11) and an optional relay
        base URL string (from `BridgeConfig.extra["relay_url"]`, see
        service.py) via `build_server()`. Each tool call's arguments come
        from whatever MCP client invokes them over stdio.
Outputs: `build_server()` returns a configured `FastMCP` instance; `main()`
         runs it over stdio as a standalone process (its own console script,
         `curtain-bridge-mcp` -- see pyproject.toml), NOT a `BridgeModule`
         registered into `BridgeService`'s asyncio daemon, because an MCP
         stdio server owns stdin/stdout for the lifetime of one client
         connection and is spawned per-connection by the MCP client itself --
         exactly the same "client spawns the process" pattern this ticket's
         own guide (step 3) anticipated, and the standard deployment shape
         for every stdio MCP server. This also satisfies the "do not widen
         network exposure" requirement about as narrowly as possible: stdio
         has zero network surface at all, strictly narrower than health.py's
         and crash_relay.py's loopback-bound-but-still-TCP HTTP listeners.
Constraints: HARD SECURITY BOUNDARY, non-negotiable -- neither MCP surface
             (Mac-side or Bridge-side) may EVER expose the ability to change
             Curtain's own privacy/security settings (arm state, password,
             cover appearance, or any Settings.swift-backed key). This
             process runs entirely on the Pi, in a separate OS process on
             separate hardware from Curtain.app -- there is no shared memory,
             no IPC channel, no callback, and no import anywhere in this file
             or its dependencies (tinypilot_client.py, hid_keymap.py,
             relay_client.py) that reaches Settings.swift, SessionCoordinator,
             or any password-storage/E-12-Telegram-password-flow code
             (telegram_client.py's TelegramLoginModule, hid_typing.py's
             HidUnlockModule). `curtain_kvm_type` is a separate, generic
             typing tool: it types exactly the text the MCP caller supplies,
             sourced only from that call's arguments, never from local
             storage, a file, an environment variable, or any other
             persisted value -- see `_type_text()`'s docstring.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E14-02)
"""

from __future__ import annotations

import base64
import logging
import os
from typing import Any

from mcp.server.fastmcp import FastMCP

from curtain_bridge.hid_keymap import UnsupportedCharacterError, keystroke_for_char
from curtain_bridge.relay_client import (
    RelayClient,
    RelayNotConfiguredError,
    RelayUnreachableError,
)
from curtain_bridge.tinypilot_client import TinyPilotClient

logger = logging.getLogger("curtain_bridge.mcp_server")

# The exact, closed set of tools this server may ever expose. Enumerated as a
# module-level constant (not just implied by the @tool() decorators below) so
# the adversarial test suite has one canonical list to assert against without
# needing to introspect decorator call order.
EXPOSED_TOOL_NAMES = frozenset(
    {"curtain_kvm_screenshot", "curtain_kvm_type", "curtain_kvm_power"}
)


def _type_text(tinypilot: TinyPilotClient, text: str) -> int:
    """
    Purpose: send `text` through TinyPilot's keystroke-injection endpoint one
             character at a time, via the same `hid_keymap.keystroke_for_char`
             table `HidUnlockModule` uses for password entry -- reused here
             ONLY for its character-to-HID-keycode mapping (a pure, stateless
             lookup function with no awareness of passwords, Telegram, or
             Settings), not for any password-flow logic.
    Inputs: tinypilot (a TinyPilotClient), text (the exact string the MCP
            caller supplied as `curtain_kvm_type`'s `text` argument -- this
            function has no other source for what it types).
    Outputs: the number of characters typed.
    Constraints: SECURITY-CRITICAL -- this is the ONLY function in this file
                 that calls `send_keystroke`, and its sole input is the
                 `text` parameter passed in by the caller. It never reads
                 from a file, an environment variable, a config value, or any
                 other persisted store. It does not call, import, or
                 reference `curtain_bridge.hid_typing` (HidUnlockModule) or
                 `curtain_bridge.telegram_client` (TelegramLoginModule) --
                 grep-verified zero references, see the adversarial test
                 suite's grep-based test. Raises UnsupportedCharacterError
                 (re-raised as a ValueError-shaped MCP tool error by the
                 caller) if any character has no US-QWERTY representation --
                 no partial-guessing, no substitution, matching
                 keystroke_for_char's own documented behavior.
    """
    count = 0
    for char in text:
        keystroke = keystroke_for_char(char)
        tinypilot.send_keystroke(**keystroke.as_kwargs())
        count += 1
    return count


def build_server(
    tinypilot: TinyPilotClient,
    *,
    relay_url: str | None = None,
) -> FastMCP:
    """
    Purpose: construct and return a fully-configured FastMCP server exposing
             exactly the three curtain_kvm_* tools, closing over the supplied
             TinyPilotClient and relay URL. Factored out of main() so tests
             can call tool functions directly (via the returned server's
             `list_tools()`/`call_tool()`) without spawning a stdio subprocess.
    Inputs: tinypilot (a TinyPilotClient, already constructed against the
            Bridge's configured TinyPilot target -- this function does not
            construct one itself, matching the ticket's "call into T-P1-E11-01's
            client, don't re-implement it" requirement). relay_url (optional
            str, e.g. "http://192.168.1.60" -- None if no relay is configured,
            the expected state for most installs per this ticket's scope).
    Outputs: a FastMCP instance with all three tools registered.
    Constraints: tool parameter schemas are derived by FastMCP directly from
                 each function's type-hinted signature below -- by
                 construction, none of the three tools below declares a
                 parameter named (or resembling) password/credential/secret,
                 and none accepts any Settings-shaped field (armed/disarmed/
                 coverAppearance/etc) -- verified by the adversarial test
                 suite's schema-inspection test, not just by this comment.
    """
    server = FastMCP(
        "curtain-kvm-bridge",
        instructions=(
            "KVM recovery tools for a Mac reachable only via TinyPilot "
            "hardware KVM (the Mac's own software, login, and FileVault "
            "safeguards are bypassed by design at this layer). Exactly "
            "three tools: screenshot, generic keystroke typing, and power "
            "control. None of these tools can read, view, or change "
            "Curtain.app's own security settings on the Mac -- there is no "
            "code path between this process and that app's state."
        ),
    )

    @server.tool()
    def curtain_kvm_screenshot() -> dict[str, Any]:
        """
        Take a screenshot of the KVM target machine's current display via
        TinyPilot. Returns base64-encoded JPEG image data, or a `no_signal`
        status if the target has no video output (e.g. powered off).

        Takes no parameters -- there is nothing for a caller to influence
        beyond "take a screenshot right now."
        """
        image_bytes = tinypilot.get_screenshot()
        if image_bytes is None:
            return {"status": "no_signal"}
        return {
            "status": "ok",
            "image_base64": base64.b64encode(image_bytes).decode("ascii"),
            "mime_type": "image/jpeg",
        }

    @server.tool()
    def curtain_kvm_type(text: str) -> dict[str, Any]:
        """
        Type arbitrary literal text on the KVM target machine via HID
        keystroke injection, one character per call to TinyPilot's keystroke
        endpoint, US-QWERTY layout. This is a generic typing tool: it types
        exactly the `text` string given to it, character for character --
        it has no access to, and no awareness of, any password stored by
        Curtain.app, and is entirely unrelated to Curtain's separate
        Telegram-confirmed unlock flow.

        Args:
            text: the literal string to type. Characters with no US-QWERTY
                physical-key representation cause this call to fail (no
                partial typing, no substitution).
        """
        try:
            typed_count = _type_text(tinypilot, text)
        except UnsupportedCharacterError as exc:
            return {"status": "error", "error": str(exc)}
        return {"status": "ok", "characters_typed": typed_count}

    @server.tool()
    def curtain_kvm_power(action: str) -> dict[str, Any]:
        """
        Control power to the KVM target machine via a Tasmota-compatible
        smart-plug relay's local HTTP API. Requires physical relay hardware
        to be attached and its URL configured (`relay_url` in the Bridge
        config) -- if no relay is configured or it is unreachable, this
        fails explicitly with an error status rather than pretending to
        succeed.

        Args:
            action: one of "on", "off", "cycle" (power off then back on --
                the normal "reboot a hung machine" operation).
        """
        if action not in ("on", "off", "cycle"):
            return {
                "status": "error",
                "error": f"unrecognized action {action!r}; expected one of: on, off, cycle",
            }
        if not relay_url:
            return {"status": "error", "error": str(RelayNotConfiguredError())}

        relay = RelayClient(relay_url)
        try:
            if action == "on":
                state = relay.power_on()
            elif action == "off":
                state = relay.power_off()
            else:
                state = relay.power_cycle()
        except RelayUnreachableError as exc:
            return {"status": "error", "error": str(exc)}
        finally:
            relay.close()
        return {"status": "ok", "power_state": state}

    return server


def main() -> None:
    """
    Purpose: console-script entry point (`curtain-bridge-mcp`), spawned by an
             MCP client over stdio -- the standard MCP deployment shape (the
             client process starts this one and speaks the MCP protocol over
             its stdin/stdout), matching T-P1-E14-01's Mac-side server's own
             documented transport choice.
    Inputs: reads the same config JSON `curtain-bridge` (service.py's main())
            reads, via --config or the CURTAIN_BRIDGE_CONFIG env var -- this
            keeps one config file and one `tinypilot_host`/`relay_url` source
            of truth for both the long-running daemon and this on-demand MCP
            process, rather than inventing a second config format.
    Outputs: blocks running the stdio MCP server loop until the client
             disconnects or the process is killed.
    Constraints: constructs its own TinyPilotClient (does not share one with
                 a running `curtain-bridge` daemon process, since this is a
                 separate OS process with its own lifecycle) -- if a
                 `curtain-bridge` daemon happens to be running concurrently,
                 both processes independently authenticate against TinyPilot;
                 this is the same "not thread/process-safe across concurrent
                 re-auth" tradeoff tinypilot_client.py's own docstring already
                 documents, not a new risk introduced here.
    """
    import argparse
    import json
    from pathlib import Path

    logging.basicConfig(level=os.environ.get("CURTAIN_BRIDGE_LOG_LEVEL", "INFO"))

    parser = argparse.ArgumentParser(prog="curtain-bridge-mcp")
    parser.add_argument("--config", default=os.environ.get("CURTAIN_BRIDGE_CONFIG"))
    args = parser.parse_args()
    if not args.config:
        raise SystemExit(
            "no config path supplied (use --config or CURTAIN_BRIDGE_CONFIG env var)"
        )

    raw = json.loads(Path(args.config).read_text())
    tinypilot_host = raw["tinypilot_host"]
    tinypilot_port = raw.get("tinypilot_port", 80)
    relay_url = raw.get("relay_url")

    tinypilot = TinyPilotClient(f"http://{tinypilot_host}:{tinypilot_port}")
    server = build_server(tinypilot, relay_url=relay_url)
    try:
        server.run(transport="stdio")
    finally:
        tinypilot.close()


if __name__ == "__main__":
    main()
