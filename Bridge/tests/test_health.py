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


class _FakeConfig:
    """Minimal stand-in for service.BridgeConfig -- only `.extra` is read by
    HealthModule.start(), so this avoids importing service.py (and its own
    HealthModule import) just for a test fixture type."""

    def __init__(self, extra: dict[str, object] | None = None) -> None:
        self.extra = extra or {}


async def _start_module_on_ephemeral_port() -> tuple[HealthModule, int]:
    """Starts a HealthModule bound to an OS-assigned free port (port 0 trick:
    bind a throwaway socket to find a free port, close it, then start the
    real module on that port) -- avoids hardcoding a port that might collide
    across parallel test runs."""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        free_port = probe.getsockname()[1]

    module = HealthModule()
    await module.start(_FakeConfig(extra={"health_port": free_port}))
    return module, free_port


@pytest.mark.asyncio
async def test_health_endpoint_returns_documented_shape():
    module, port = await _start_module_on_ephemeral_port()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as response:
            assert response.status == 200
            assert response.headers["Content-Type"] == "application/json"
            body = json.loads(response.read())
    finally:
        await module.stop()

    assert body["status"] == "ok"
    assert body["version"] == pkg_version("curtain-bridge")
    assert isinstance(body["uptime_seconds"], int)
    assert body["uptime_seconds"] >= 0


@pytest.mark.asyncio
async def test_health_endpoint_version_matches_installed_package_metadata():
    # Regression guard against ever hardcoding a version string: this
    # confirms the served value is byte-identical to what
    # importlib.metadata independently reports for the installed
    # distribution.
    module, port = await _start_module_on_ephemeral_port()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as response:
            body = json.loads(response.read())
    finally:
        await module.stop()

    assert body["version"] == get_installed_version()
    assert body["version"] == pkg_version("curtain-bridge")


@pytest.mark.asyncio
async def test_health_endpoint_uptime_advances():
    module, port = await _start_module_on_ephemeral_port()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as response:
            first = json.loads(response.read())["uptime_seconds"]
        time.sleep(1.1)
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=5) as response:
            second = json.loads(response.read())["uptime_seconds"]
    finally:
        await module.stop()

    assert second > first


@pytest.mark.asyncio
async def test_health_endpoint_404s_unknown_path():
    module, port = await _start_module_on_ephemeral_port()
    try:
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/nope", timeout=5)
        assert exc_info.value.code == 404
    finally:
        await module.stop()


@pytest.mark.asyncio
async def test_health_module_defaults_to_documented_port_when_unspecified():
    from curtain_bridge.health import DEFAULT_HEALTH_PORT

    module = HealthModule()
    await module.start(_FakeConfig(extra={}))
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{DEFAULT_HEALTH_PORT}/health", timeout=5
        ) as response:
            assert response.status == 200
    finally:
        await module.stop()


def test_get_installed_version_never_hardcoded_matches_metadata():
    assert get_installed_version() == pkg_version("curtain-bridge")
