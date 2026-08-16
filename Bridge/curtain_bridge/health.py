"""
Purpose: Minimal HTTP /health endpoint exposing this Bridge install's live
         status, installed-package version, and process uptime, so both
         Curtain.app's setup wizard (T-P1-E11-02's `KVMBridgeDeployer`) and,
         later, E-14's `curtain_kvm_*` MCP tools can confirm the Bridge is
         reachable and at an expected version before attempting an action.
Inputs: none at import time. `HealthModule` is constructed with no arguments
        and registered into `BridgeService` (see service.py) like any other
        `BridgeModule`; its `start(config)` reads `config.extra["health_port"]`
        (falling back to `DEFAULT_HEALTH_PORT`) for the port to bind.
Outputs: a background HTTP server (via stdlib `http.server` +
         `socketserver.ThreadingMixIn`, run in a daemon thread so it never
         blocks the asyncio event loop) that responds to `GET /health` with
         `{"status": "ok", "version": "<installed package version>",
         "uptime_seconds": <int>}` as JSON. `/` and any other path return 404.
Constraints: uses only the standard library -- no new dependency is added for
             something this small (per the ticket's guide). The version is
             ALWAYS read live via `importlib.metadata.version("curtain-bridge")`
             on every request, never hardcoded or cached at import time, so a
             hot-swapped install (see updater.py) is reflected immediately
             without a service restart being required just to report the new
             version. Binds to a distinct local port from TinyPilot's own API
             port (see DEFAULT_HEALTH_PORT's doc comment and Bridge/README.md's
             "Health endpoint" section for the port-choice rationale).

             SECURITY (auth follow-up): like crash_relay.py, this binds to
             0.0.0.0 for deliberate LAN reachability. /health leaks only
             read-only status/version info (lower severity than the
             crash-report relay), but the SAME shared-secret auth is applied
             here too for consistency rather than carving out a documented
             exception -- see `auth.py`. `do_GET` calls `require_auth` as
             its first statement.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E11-03)
"""

from __future__ import annotations

import json
import logging
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from importlib.metadata import PackageNotFoundError, version
from socketserver import ThreadingMixIn

from curtain_bridge.auth import load_bridge_auth_token, require_auth

logger = logging.getLogger("curtain_bridge.health")

# The installed distribution name, as declared in pyproject.toml's
# [project].name -- never hardcode a version string; always resolve through
# importlib.metadata against this name.
PACKAGE_NAME = "curtain-bridge"

# TinyPilot's own web UI/API listens on port 80 by default (see
# BridgeConfig.tinypilot_port's default in service.py). 8642 is chosen as the
# Bridge health port specifically to avoid any collision with TinyPilot's
# port or other common services (80/443/8080/8000); documented in
# Bridge/README.md's "Health endpoint" section alongside this same rationale.
DEFAULT_HEALTH_PORT = 8642


def get_installed_version() -> str:
    """
    Purpose: resolve curtain-bridge's installed package version live.
    Inputs: none.
    Outputs: the version string from package metadata, or "0.0.0-unknown" if
             the package is not installed as a distribution (e.g. running
             directly from a source checkout without `pip install .` having
             been run) -- this fallback exists so /health never 500s in a dev
             environment, but is intentionally an obviously-not-a-real-version
             sentinel rather than a plausible-looking fake value.
    Constraints: never caches -- called fresh on every /health request so a
                 just-completed hot-swap update (updater.py) is reflected
                 without requiring a process restart.
    """
    try:
        return version(PACKAGE_NAME)
    except PackageNotFoundError:
        return "0.0.0-unknown"


class _HealthRequestHandler(BaseHTTPRequestHandler):
    """
    Purpose: Serves GET /health; every other path/method gets 404. Reads
             `started_at` off the owning `_HealthHTTPServer` instance
             (`self.server`) to compute uptime.
    Inputs: standard BaseHTTPRequestHandler request state.
    Outputs: JSON response body on success; empty 404 body otherwise.
    Constraints: `log_message` is overridden to route through this module's
                 own logger instead of stderr, matching the rest of the
                 Bridge's logging setup (service.py's configure_logging()).
    """

    server_version = "curtain-bridge-health/1.0"

    def do_GET(self) -> None:  # noqa: N802 (stdlib-mandated method name)
        # Auth check first, before path routing -- matches crash_relay.py's
        # do_POST ordering. /health has no body to protect from being
        # buffered, but the ordering is kept identical across both handlers
        # so there is exactly one place a reviewer needs to check for "does
        # auth run before anything else."
        expected_token: str | None = self.server.auth_token  # type: ignore[attr-defined]
        if not require_auth(self, expected_token):
            return

        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return

        started_at: float = self.server.started_at  # type: ignore[attr-defined]
        payload = {
            "status": "ok",
            "version": get_installed_version(),
            "uptime_seconds": int(time.monotonic() - started_at),
        }
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        logger.debug("health: %s", format % args)


class _HealthHTTPServer(ThreadingMixIn, HTTPServer):
    """
    Purpose: HTTPServer variant that serves each request on its own thread
             (ThreadingMixIn) so a slow/misbehaving client can't stall other
             requests, and stamps `started_at` for uptime computation.
    Inputs: standard HTTPServer constructor args.
    Outputs: none (server instance).
    Constraints: `daemon_threads = True` so worker threads never block process
                 shutdown.
    """

    daemon_threads = True

    def __init__(self, *args: object, auth_token: str | None = None, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)  # type: ignore[arg-type]
        self.started_at = time.monotonic()
        self.auth_token = auth_token


class HealthModule:
    """
    Purpose: `BridgeModule`-conformant wrapper that runs `_HealthHTTPServer`
             in a background daemon thread for the lifetime of the Bridge
             service, registered via `service.py`'s module-registration point
             like any other module (E-12/E-13's future modules included).
    Inputs: none at construction; `start(config)` reads the port from
            `config.extra.get("health_port", DEFAULT_HEALTH_PORT)`.
    Outputs: none directly -- side effect is the running HTTP server.
    Constraints: `stop()` calls `shutdown()` + `server_close()` and joins the
                 serving thread with a bounded timeout, so BridgeService's
                 reverse-order shutdown (see service.py's `stop_all`) never
                 hangs indefinitely on a wedged health server.
    """

    name = "health"

    def __init__(self) -> None:
        self._server: _HealthHTTPServer | None = None
        self._thread: threading.Thread | None = None

    async def start(self, config: "object") -> None:
        # `config` is a service.BridgeConfig; typed as object here to avoid a
        # circular import (service.py imports this module to register it).
        port = int(getattr(config, "extra", {}).get("health_port", DEFAULT_HEALTH_PORT))  # type: ignore[union-attr]
        # Auth token path override, matching crash_relay.py's own
        # config.extra["bridge_auth_token_path"] escape hatch for tests.
        token_path = getattr(config, "extra", {}).get(  # type: ignore[union-attr]
            "bridge_auth_token_path", None
        )
        auth_token = load_bridge_auth_token(token_path) if token_path else load_bridge_auth_token()
        if auth_token is None:
            logger.warning(
                "health: no Bridge auth token provisioned yet -- ALL requests will be "
                "rejected with 401 until the setup wizard delivers one"
            )
        self._server = _HealthHTTPServer(("0.0.0.0", port), _HealthRequestHandler, auth_token=auth_token)
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            name="curtain-bridge-health",
            daemon=True,
        )
        self._thread.start()
        logger.info("health: listening on 0.0.0.0:%d", port)

    async def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
        logger.info("health: stopped")
