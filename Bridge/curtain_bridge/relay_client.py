"""
Purpose: HTTP client for a Tasmota-style local smart-plug relay's documented
         "Console command" REST API, used by `curtain_kvm_power`
         (mcp_server.py, T-P1-E14-02) to power-cycle the machine the KVM
         targets. Tasmota (https://tasmota.github.io/docs/Commands/#power) is
         the interface documented here because it is the most common
         open-firmware smart-plug REST API and requires no cloud account, no
         vendor app, and no outbound internet dependency -- a plug flashed
         with Tasmota (or a compatible clone, e.g. many ESP8266/ESP32-based
         plugs) exposes `GET /cm?cmnd=Power<On|Off|Toggle>` on its own local
         IP and responds with a small JSON body, e.g. `{"POWER":"ON"}`. A
         GPIO-wired relay (direct Pi pin control via RPi.GPIO/gpiozero) was
         considered and rejected for this ticket: it would require this
         Python process to run with GPIO access on the exact Pi wired to the
         relay, coupling curtain-bridge's process identity to a specific
         piece of physical wiring, whereas a local-HTTP relay is reachable
         from wherever curtain-bridge happens to run on the LAN and matches
         the existing httpx-client style already used for
         tinypilot_client.py and telegram_client.py.
Inputs: a relay base URL (e.g. "http://192.168.1.60") supplied at
        construction, read from `BridgeConfig.extra["relay_url"]` by the MCP
        server layer -- see mcp_server.py's `curtain_kvm_power` tool.
Outputs: `power_on()`/`power_off()`/`power_cycle()` return the relay's
         reported POWER state ("ON"/"OFF") on success, or raise
         `RelayNotConfiguredError`/`RelayUnreachableError` on failure -- never
         a silent/fake success.
Constraints: this client intentionally does NOT catch-and-swallow connection
             failures: `curtain_kvm_power` (mcp_server.py) is REQUIRED by this
             ticket's acceptance bar to fail explicitly when no physical relay
             is attached, so every failure mode here is a typed exception, not
             a logged-and-ignored no-op. Zero relationship to
             tinypilot_client.py's TinyPilotClient -- a relay and a KVM device
             are different hardware with different owners on the network,
             deliberately not unified into one client class.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E14-02)
"""

from __future__ import annotations

import logging
import time

import httpx

logger = logging.getLogger("curtain_bridge.relay_client")


class RelayNotConfiguredError(Exception):
    """
    Purpose: raised when `curtain_kvm_power` is invoked but no relay base URL
             has been configured (`BridgeConfig.extra["relay_url"]` absent or
             empty) -- distinct from `RelayUnreachableError` so callers (and
             the MCP tool's returned error text) can tell "you haven't set
             this up yet" apart from "it's configured but not responding."
    Inputs: none beyond the standard Exception message.
    Outputs: a message stating no relay is configured and pointing at the
             config key to set.
    Constraints: this is the expected, documented, non-buggy outcome for any
                 Bridge install that has no physical relay hardware attached
                 -- see relay_client.py's module docstring and
                 Bridge/README.md's "Power relay" section.
    """

    def __init__(self) -> None:
        super().__init__(
            "no relay configured (set \"relay_url\" in the Bridge config JSON "
            "to a Tasmota-compatible relay's base URL, e.g. "
            '"http://192.168.1.60") -- curtain_kvm_power is non-functional '
            "without physical relay hardware attached; this is expected, not a bug"
        )


class RelayUnreachableError(Exception):
    """
    Purpose: raised when a relay URL IS configured but the HTTP request to it
             fails (connection refused/timeout/non-2xx/unexpected body shape)
             -- distinct from RelayNotConfiguredError, see that class's
             docstring.
    Inputs: relay_url (the configured base URL), detail (str describing the
            underlying failure).
    Outputs: a message combining both for logs/errors.
    Constraints: raised for any response that isn't a well-formed Tasmota
                 `{"POWER": "ON"|"OFF"}` JSON body, not just network-level
                 failures -- an unexpected body shape means this isn't
                 actually a Tasmota-compatible relay, which is just as much a
                 "can't confirm the action happened" case as unreachable.
    """

    def __init__(self, relay_url: str, detail: str) -> None:
        self.relay_url = relay_url
        self.detail = detail
        super().__init__(f"relay at {relay_url!r} unreachable or returned an unexpected response: {detail}")


class RelayClient:
    """
    Purpose: Thin, typed wrapper around a Tasmota-compatible smart-plug's
             local HTTP "Console command" API, covering exactly the power
             on/off/cycle operations `curtain_kvm_power` needs.
    Inputs: base_url (e.g. "http://192.168.1.60"), an optional httpx.Client
            for injection in tests, and an optional timeout in seconds.
    Outputs: see per-method docstrings.
    Constraints: unauthenticated by design -- Tasmota's local HTTP command API
                 has no built-in auth unless the device owner has separately
                 configured one (out of scope here; document this as a LAN-
                 trust assumption in README.md, matching TinyPilot's own
                 unauthenticated-until-token-issued local network posture).
    """

    def __init__(
        self,
        base_url: str,
        *,
        client: httpx.Client | None = None,
        timeout: float = 10.0,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = client or httpx.Client(base_url=self._base_url, timeout=timeout)

    def close(self) -> None:
        """Purpose: release the underlying HTTP connection pool. Inputs/Outputs: none."""
        self._client.close()

    def __enter__(self) -> "RelayClient":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def _power_command(self, command: str) -> str:
        """
        Purpose: shared implementation for power_on/power_off/power_cycle --
                 issues `GET /cm?cmnd=<command>` and parses the `POWER` field
                 out of Tasmota's JSON response.
        Inputs: command ("Power On" / "Power Off" / "Power Toggle" -- exact
                Tasmota command strings, URL-encoded by httpx's params kwarg).
        Outputs: the reported state, "ON" or "OFF".
        Constraints: raises RelayUnreachableError on any transport failure
                     (httpx.HTTPError), non-2xx status, or a response body
                     that doesn't parse as `{"POWER": "ON"|"OFF"}` JSON --
                     never returns a guessed/assumed state.
        """
        try:
            response = self._client.get("/cm", params={"cmnd": command})
        except httpx.HTTPError as exc:
            raise RelayUnreachableError(self._base_url, str(exc)) from exc

        if response.status_code != 200:
            raise RelayUnreachableError(
                self._base_url, f"HTTP {response.status_code}: {response.text}"
            )

        try:
            body = response.json()
            power_state = body["POWER"]
        except (ValueError, KeyError) as exc:
            raise RelayUnreachableError(
                self._base_url, f"unexpected response body: {response.text!r}"
            ) from exc

        if power_state not in ("ON", "OFF"):
            raise RelayUnreachableError(
                self._base_url, f"unrecognized POWER value: {power_state!r}"
            )

        logger.info("relay_client: %s -> POWER=%s", command, power_state)
        return power_state

    def power_on(self) -> str:
        """Purpose: GET /cm?cmnd=Power+On. Inputs: none. Outputs: "ON" on
        success. Constraints: see _power_command."""
        return self._power_command("Power On")

    def power_off(self) -> str:
        """Purpose: GET /cm?cmnd=Power+Off. Inputs: none. Outputs: "OFF" on
        success. Constraints: see _power_command."""
        return self._power_command("Power Off")

    def power_cycle(self) -> str:
        """
        Purpose: power the target off, briefly wait, then power it back on --
                 the actual "reboot a hung machine" operation `curtain_kvm_power`
                 exposes, rather than a bare toggle (whose effect depends on
                 unknown current state).
        Inputs: none.
        Outputs: "ON" (the state after the cycle completes).
        Constraints: NOT atomic against a concurrent external toggle of the
                     same plug -- acceptable for this single-operator KVM
                     recovery use case. Uses a fixed off-duration long enough
                     for the target machine's power supply to fully discharge
                     (5 seconds), not configurable in this ticket's scope.
                     Raises RelayUnreachableError from whichever half (off or
                     on) fails -- callers cannot distinguish "never powered
                     off" from "powered off but failed to power back on"
                     without catching and inspecting `.detail`, which is
                     acceptable since either case requires the same manual
                     recovery (check the relay directly).
        """
        self.power_off()
        time.sleep(5.0)
        return self.power_on()
