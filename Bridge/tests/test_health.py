"""
Purpose: Tests for curtain_bridge.health's /health endpoint -- confirms the
         real HTTP server (not a mock) starts, serves the documented JSON
         shape, resolves version via live package metadata (never hardcoded),
         reports advancing uptime, and 404s any other path.
Inputs: none (each test starts/stops its own HealthModule instance on an
        ephemeral port to avoid cross-test port collisions).
Outputs: pytest test functions.
Constraints: uses real sockets (127.0.0.1, OS-assigned ephemeral port via
             port 0) -- no mocking of http.server itself, since this endpoint
             IS the thing under test, matching the ticket's "GET the real
             registered health endpoint" instruction.

             Every module started by `_start_module_on_ephemeral_port`
             provisions a real auth-token fixture file (via `tmp_path`) and
             every non-auth-focused test presents it, matching production's
             fail-closed requirement -- see the dedicated "auth" test group
             below for the adversarial no-token/wrong-token/no-header cases
             this follow-up security fix specifically requires.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E11-03)
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from importlib.metadata import version as pkg_version

import pytest

from curtain_bridge.health import HealthModule, get_installed_version

AUTH_TOKEN = "test-health-token"
AUTH_HEADERS = {"Authorization": f"Bearer {AUTH_TOKEN}"}


class _FakeConfig:
    """Minimal stand-in for service.BridgeConfig -- only `.extra` is read by
    HealthModule.start(), so this avoids importing service.py (and its own
    HealthModule import) just for a test fixture type."""

    def __init__(self, extra: dict[str, object] | None = None) -> None:
        self.extra = extra or {}


async def _start_module_on_ephemeral_port(
    tmp_path, *, provision_token: bool = True
) -> tuple[HealthModule, int]:
    """Starts a HealthModule bound to an OS-assigned free port (port 0 trick:
    bind a throwaway socket to find a free port, close it, then start the
    real module on that port) -- avoids hardcoding a port that might collide
    across parallel test runs."""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        free_port = probe.getsockname()[1]

    extra: dict[str, object] = {"health_port": free_port}
    if provision_token:
        token_path = tmp_path / "auth-token"
        token_path.write_text(AUTH_TOKEN, encoding="utf-8")
        extra["bridge_auth_token_path"] = str(token_path)
    else:
        # Point at a path that deliberately does not exist -- exercises the
        # fail-closed "no token provisioned yet" case without touching the
        # real /etc/curtain-bridge/auth-token on the test runner's machine.
        extra["bridge_auth_token_path"] = str(tmp_path / "does-not-exist")

    module = HealthModule()
    await module.start(_FakeConfig(extra=extra))
    return module, free_port


def _get(port: int, path: str = "/health", *, token: str | None = AUTH_TOKEN) -> tuple[int, dict[str, object]]:
    headers = {}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:
        body = exc.read()
        return exc.code, json.loads(body) if body else {}


@pytest.mark.asyncio
async def test_health_endpoint_returns_documented_shape(tmp_path):
    module, port = await _start_module_on_ephemeral_port(tmp_path)
    try:
        status, body = _get(port)
    finally:
        await module.stop()

    assert status == 200
    assert body["status"] == "ok"
    assert body["version"] == pkg_version("curtain-bridge")
    assert isinstance(body["uptime_seconds"], int)
    assert body["uptime_seconds"] >= 0


@pytest.mark.asyncio
async def test_health_endpoint_version_matches_installed_package_metadata(tmp_path):
    # Regression guard against ever hardcoding a version string: this
    # confirms the served value is byte-identical to what
    # importlib.metadata independently reports for the installed
    # distribution.
    module, port = await _start_module_on_ephemeral_port(tmp_path)
    try:
        _, body = _get(port)
    finally:
        await module.stop()

    assert body["version"] == get_installed_version()
    assert body["version"] == pkg_version("curtain-bridge")


@pytest.mark.asyncio
async def test_health_endpoint_uptime_advances(tmp_path):
    module, port = await _start_module_on_ephemeral_port(tmp_path)
    try:
        _, first_body = _get(port)
        first = first_body["uptime_seconds"]
        time.sleep(1.1)
        _, second_body = _get(port)
        second = second_body["uptime_seconds"]
    finally:
        await module.stop()

    assert second > first


@pytest.mark.asyncio
async def test_health_endpoint_404s_unknown_path(tmp_path):
    module, port = await _start_module_on_ephemeral_port(tmp_path)
    try:
        status, _ = _get(port, "/nope")
        assert status == 404
    finally:
        await module.stop()


@pytest.mark.asyncio
async def test_health_module_defaults_to_documented_port_when_unspecified(tmp_path):
    from curtain_bridge.health import DEFAULT_HEALTH_PORT

    module = HealthModule()
    token_path = tmp_path / "auth-token"
    token_path.write_text(AUTH_TOKEN, encoding="utf-8")
    await module.start(_FakeConfig(extra={"bridge_auth_token_path": str(token_path)}))
    try:
        status, _ = _get(DEFAULT_HEALTH_PORT)
        assert status == 200
    finally:
        await module.stop()


def test_get_installed_version_never_hardcoded_matches_metadata():
    assert get_installed_version() == pkg_version("curtain-bridge")


# -- auth: adversarial coverage (this follow-up security fix's core requirement) --


@pytest.mark.asyncio
async def test_health_returns_401_with_no_authorization_header(tmp_path):
    module, port = await _start_module_on_ephemeral_port(tmp_path)
    try:
        status, body = _get(port, token=None)
    finally:
        await module.stop()

    assert status == 401
    assert body["status"] == "unauthorized"


@pytest.mark.asyncio
async def test_health_returns_401_with_wrong_token(tmp_path):
    module, port = await _start_module_on_ephemeral_port(tmp_path)
    try:
        status, body = _get(port, token="wrong-token")
    finally:
        await module.stop()

    assert status == 401
    assert body["status"] == "unauthorized"


@pytest.mark.asyncio
async def test_health_succeeds_with_correct_token(tmp_path):
    # Regression guard on the happy path.
    module, port = await _start_module_on_ephemeral_port(tmp_path)
    try:
        status, body = _get(port, token=AUTH_TOKEN)
    finally:
        await module.stop()

    assert status == 200
    assert body["status"] == "ok"


@pytest.mark.asyncio
async def test_health_rejects_all_requests_when_no_token_provisioned(tmp_path):
    # Fail-closed case: no token has ever been delivered to this Bridge.
    module, port = await _start_module_on_ephemeral_port(tmp_path, provision_token=False)
    try:
        status_no_header, body_no_header = _get(port, token=None)
        status_with_header, body_with_header = _get(port, token="some-guessed-token")
    finally:
        await module.stop()

    assert status_no_header == 401
    assert body_no_header["status"] == "unauthorized"
    assert status_with_header == 401
    assert body_with_header["status"] == "unauthorized"
