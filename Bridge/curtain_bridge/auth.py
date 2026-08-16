"""
Purpose: Shared-secret authentication for this Bridge's own local HTTP
         endpoints (`health.py`'s /health and `crash_relay.py`'s
         /crash-report). Both endpoints are bound to `0.0.0.0` (see each
         module's own doc comment for why the direct-LAN-reachability
         architecture is deliberate and not being changed here) — anyone on
         the same LAN as the TinyPilot can otherwise reach them with zero
         credential. `crash_relay.py` in particular relays attacker-supplied
         text verbatim into the SAME trusted Telegram chat
         `telegram_client.py`'s `TelegramLoginModule` uses for the
         FileVault-unlock password-reply flow, so an unauthenticated POST is
         a real social-engineering path to the user's Mac password, not just
         log spam. This module closes that gap with a single shared bearer
         token, mirroring `telegram_client.py`'s `load_bot_token()` file-read
         pattern exactly rather than inventing a second credential-loading
         style in this package.
Inputs: `load_bridge_auth_token()` reads `/etc/curtain-bridge/auth-token`
        (an optional `path` override for tests, matching
        `load_bot_token(path=...)`). `require_auth()` reads the incoming
        request's `Authorization` header off a `BaseHTTPRequestHandler`.
Outputs: `load_bridge_auth_token()` returns the token string, or `None` if
         the file does not exist yet (an already-deployed Bridge from before
         this fix, or a fresh install whose setup wizard hasn't reached the
         auth-token step yet). `require_auth()` returns `True`/`False` and,
         on `False`, has already written a 401 JSON response to the handler.
Constraints: FAIL CLOSED, always. `require_auth()` rejects EVERY request
             with 401 when `expected_token` is `None` — a missing token file
             must never be silently treated as "no auth required," which
             would reintroduce exactly the open-relay bug this module exists
             to close. Comparison uses `hmac.compare_digest`, never `==`, to
             avoid a timing side-channel that could let an attacker recover
             the token byte-by-byte. The token itself is never logged, at
             any level, on either the success or failure path.
SPORT: MASTER-APPS (Bridge/ deployment artifact, security follow-up)
"""

from __future__ import annotations

import hmac
import json
import logging
from http.server import BaseHTTPRequestHandler
from pathlib import Path

logger = logging.getLogger("curtain_bridge.auth")

# Same directory E-11-02's `KVMBridgeDeployer.sendTelegramToken` already
# writes `/etc/curtain-bridge/telegram-token` into -- one credential
# directory on the Pi, not a second one invented for this token.
DEFAULT_AUTH_TOKEN_PATH = "/etc/curtain-bridge/auth-token"


def load_bridge_auth_token(path: str | Path = DEFAULT_AUTH_TOKEN_PATH) -> str | None:
    """
    Purpose: read the shared bearer token from the file
             `KVMBridgeDeployer.sendBridgeAuthToken` delivers it to over SSH,
             mirroring `telegram_client.py`'s `load_bot_token()` read style
             (strip trailing whitespace/newline defensively, same as that
             function's own doc comment reasons for its strip()).
    Inputs: path (defaults to DEFAULT_AUTH_TOKEN_PATH; overridable for tests
            and non-standard installs, matching load_bot_token's own
            override parameter).
    Outputs: the token string, or None if the file does not exist.
    Constraints: unlike `load_bot_token` (which raises FileNotFoundError,
                 intentionally uncaught, because a missing bot token means a
                 whole module has nothing useful to do), a missing auth
                 token here is NOT re-raised -- callers must treat `None` as
                 "reject every request" (see `require_auth` below), not as
                 an unhandled startup crash, since crash_relay/health still
                 need to run and respond (with 401s) even before the token
                 has ever been provisioned. Never logs the token value
                 itself.
    """
    token_path = Path(path)
    if not token_path.exists():
        return None
    token = token_path.read_text(encoding="utf-8").strip()
    return token or None


def require_auth(handler: BaseHTTPRequestHandler, expected_token: str | None) -> bool:
    """
    Purpose: gate a single incoming request on a matching
             `Authorization: Bearer <token>` header. Callers (crash_relay.py's
             do_POST, health.py's do_GET) MUST call this as the very first
             thing in their handler, before reading Content-Length or the
             request body at all -- an unauthorized caller must never cause
             this process to buffer or parse a body it has no right to
             submit.
    Inputs: handler (the live BaseHTTPRequestHandler, read for its headers
            and used to write the 401 response on failure), expected_token
            (the value `load_bridge_auth_token()` returned at module
            start/construction time -- passed in rather than re-read from
            disk on every request, matching this package's existing
            once-at-construction credential-loading style, e.g.
            CrashRelayModule's constructor-injected TelegramClient).
    Outputs: True if the request is authorized (caller proceeds normally).
             False if not -- a 401 JSON response has already been written to
             the handler's wfile; the caller must return immediately without
             any further processing.
    Constraints: FAIL CLOSED -- if expected_token is None (no token
                 provisioned yet), this ALWAYS returns False; there is no
                 code path in this function that grants access without a
                 real, matching token. Uses hmac.compare_digest (constant-
                 time) rather than `==` for the actual comparison, since a
                 short-circuiting `==` on a string leaks timing information
                 proportional to the length of the matching prefix. Never
                 logs the presented or expected token value.
    """
    if expected_token is None:
        logger.warning(
            "auth: rejecting request -- no Bridge auth token has been provisioned yet "
            "(re-run Curtain.app's KVM Bridge setup wizard to deliver one)"
        )
        _respond_401(handler)
        return False

    presented = handler.headers.get("Authorization", "")
    prefix = "Bearer "
    if not presented.startswith(prefix):
        _respond_401(handler)
        return False

    presented_token = presented[len(prefix) :]
    if not hmac.compare_digest(presented_token, expected_token):
        _respond_401(handler)
        return False

    return True


def _respond_401(handler: BaseHTTPRequestHandler) -> None:
    """Purpose: write a 401 JSON response in the same shape both
    crash_relay.py and health.py already use for their other error
    responses, so a caller can't tell auth failures apart from any other
    error by response shape alone."""
    body = json.dumps({"status": "unauthorized"}).encode("utf-8")
    handler.send_response(401)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
