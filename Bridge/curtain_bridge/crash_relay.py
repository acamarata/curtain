"""
Purpose: Minimal HTTP POST /crash-report relay so Curtain.app (running on the
         protected Mac) can hand off a human-readable crash-cause summary to
         the Bridge for delivery via Telegram, once the Mac is back online
         after an unexpected-reboot recovery launch (T-P1-E12-04). Mirrors
         health.py's stdlib-http.server pattern exactly -- same threading
         model, same BridgeModule-registration shape -- rather than inventing
         a second HTTP server style in this package.
Inputs: `CrashRelayModule` is constructed with a `TelegramClient` and a
        `get_chat_id: Callable[[], int | None]` accessor (injected by
        `service.py`'s registration point, reading the SAME `TelegramLoginModule`
        instance's pinned `_chat_id` this process already tracks -- no second
        chat_id source, no new persistence). `start(config)` reads
        `config.extra["crash_relay_port"]`, falling back to
        `DEFAULT_CRASH_RELAY_PORT`. Each POST body is JSON:
        `{"summary": "<human-readable text>"}`.
Outputs: on a valid POST with a known chat_id, relays the summary via
         `TelegramClient.send_message` and responds 200
         `{"status": "sent", "message_id": <int>}`. Responds 503
         `{"status": "no_chat_id"}` if no human has ever messaged the bot yet
         (nowhere safe to send). Responds 400 for a malformed/empty body, 404
         for any other path/method.
Constraints: ARCHITECTURAL DECISION (T-P1-E12-04, decided on the Mac side,
             implemented here as its Bridge-side half): Curtain.app sends the
             crash summary to the Bridge rather than calling Telegram's Bot
             API directly from the Mac, because E-11-02's `KVMBridgeDeployer`
             established a hard boundary that the Telegram bot token is NEVER
             persisted anywhere on the Mac (SSH-stdin-piped straight to the
             Pi, never Keychain/UserDefaults/disk). A direct-send architecture
             would require the Mac to hold a durable copy of that same token
             to call `sendMessage` on every future launch -- reintroducing
             exactly the credential-on-the-protected-machine risk E-11-02
             deliberately avoided. Relaying through the Bridge (which already
             owns the token and the pinned chat_id) needs no new credential
             anywhere and reuses this Bridge's existing outbound Telegram
             path verbatim. Binds to a THIRD distinct local port (not
             TinyPilot's 80, not health.py's 8642) -- see
             DEFAULT_CRASH_RELAY_PORT below.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-04)
"""

from __future__ import annotations

import json
import logging
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from typing import TYPE_CHECKING, Callable

if TYPE_CHECKING:
    from curtain_bridge.telegram_client import TelegramClient

logger = logging.getLogger("curtain_bridge.crash_relay")

# Distinct from TinyPilot's port 80 and health.py's DEFAULT_HEALTH_PORT
# (8642) -- documented alongside both in Bridge/README.md's "Crash-report
# relay" section.
DEFAULT_CRASH_RELAY_PORT = 8643

# Same length ceiling telegram_client.py's sendMessage is bound by
# (Telegram's documented per-message text limit); truncated defensively here
# too so a pathological summary can't produce a confusing 400 from Telegram
# itself instead of a clear local one.
_MAX_SUMMARY_LENGTH = 4096


class _CrashRelayRequestHandler(BaseHTTPRequestHandler):
    """
    Purpose: Serves POST /crash-report; every other path/method gets 404.
             Reads the owning `_CrashRelayHTTPServer`'s injected `client` and
             `get_chat_id` (set on the server instance, mirroring
             `_HealthRequestHandler`'s `self.server.started_at` pattern).
    Constraints: never logs the summary body's contents at any level other
                 than a length count -- a crash summary is not a secret on
                 the level the Telegram bot token or a password is, but there
                 is no reason to duplicate potentially sensitive process/
                 exception detail into the Bridge's own log stream twice.
    """

    server_version = "curtain-bridge-crash-relay/1.0"

    def do_POST(self) -> None:  # noqa: N802 (stdlib-mandated method name)
        if self.path != "/crash-report":
            self._respond(404, {"status": "not_found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            body = json.loads(raw) if raw else {}
        except ValueError:
            self._respond(400, {"status": "invalid_json"})
            return

        summary = str(body.get("summary", "")).strip()
        if not summary:
            self._respond(400, {"status": "empty_summary"})
            return
        summary = summary[:_MAX_SUMMARY_LENGTH]

        client: "TelegramClient" = self.server.client  # type: ignore[attr-defined]
        get_chat_id: Callable[[], int | None] = self.server.get_chat_id  # type: ignore[attr-defined]
        chat_id = get_chat_id()
        if chat_id is None:
            logger.warning(
                "crash_relay: received a %d-char summary but no chat_id is known yet "
                "(human must message the bot once first) -- not sent",
                len(summary),
            )
            self._respond(503, {"status": "no_chat_id"})
            return

        try:
            message_id = client.send_message(chat_id, f"Crash report from Curtain's Mac:\n\n{summary}")
        except Exception:
            logger.exception("crash_relay: send_message failed")
            self._respond(502, {"status": "send_failed"})
            return

        logger.info("crash_relay: relayed a %d-char summary, message_id=%d", len(summary), message_id)
        self._respond(200, {"status": "sent", "message_id": message_id})

    def _respond(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        logger.debug("crash_relay: %s", format % args)


class _CrashRelayHTTPServer(ThreadingMixIn, HTTPServer):
    """Purpose: HTTPServer variant carrying the injected TelegramClient +
    chat_id accessor for the handler above to read. Mirrors
    _HealthHTTPServer's constructor-injection shape."""

    daemon_threads = True

    def __init__(
        self, *args: object, client: "TelegramClient", get_chat_id: Callable[[], int | None], **kwargs: object
    ) -> None:
        super().__init__(*args, **kwargs)  # type: ignore[arg-type]
        self.client = client
        self.get_chat_id = get_chat_id


class CrashRelayModule:
    """
    Purpose: `BridgeModule`-conformant wrapper running `_CrashRelayHTTPServer`
             in a background daemon thread for the Bridge's lifetime.
    Inputs: `client` (a `TelegramClient`, normally the SAME instance
            `TelegramLoginModule` uses -- constructed once in service.py's
            `_async_main` and passed to both modules, per this ticket's
            relay-not-duplicate-credential decision) and `get_chat_id` (a
            zero-arg callable reading that module's live pinned chat_id,
            e.g. `lambda: telegram_login_module._chat_id`).
    Outputs: none directly -- side effect is the running HTTP server.
    Constraints: `stop()` mirrors `HealthModule.stop()`'s bounded-join
                 shutdown so BridgeService's reverse-order stop_all() never
                 hangs on a wedged relay server.
    """

    name = "crash_relay"

    def __init__(self, client: "TelegramClient", get_chat_id: Callable[[], int | None]) -> None:
        self._client = client
        self._get_chat_id = get_chat_id
        self._server: _CrashRelayHTTPServer | None = None
        self._thread: threading.Thread | None = None

    async def start(self, config: "object") -> None:
        # `config` is a service.BridgeConfig; typed as object here to avoid a
        # circular import, matching HealthModule.start's existing pattern.
        port = int(getattr(config, "extra", {}).get("crash_relay_port", DEFAULT_CRASH_RELAY_PORT))  # type: ignore[union-attr]
        self._server = _CrashRelayHTTPServer(
            ("0.0.0.0", port),
            _CrashRelayRequestHandler,
            client=self._client,
            get_chat_id=self._get_chat_id,
        )
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            name="curtain-bridge-crash-relay",
            daemon=True,
        )
        self._thread.start()
        logger.info("crash_relay: listening on 0.0.0.0:%d", port)

    async def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
        logger.info("crash_relay: stopped")
