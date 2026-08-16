"""
Purpose: Tests for curtain_bridge.crash_relay's POST /crash-report endpoint --
         confirms the real HTTP server (not a mock) relays a summary via an
         injected TelegramClient stand-in when a chat_id is known, returns
         503 when it is not, and validates malformed/empty request bodies.
Inputs: none (each test starts/stops its own CrashRelayModule instance on an
        ephemeral port, matching test_health.py's port-0 pattern).
Outputs: pytest test functions.
Constraints: uses real sockets (127.0.0.1, OS-assigned ephemeral port) for the
             HTTP layer under test; the TelegramClient dependency itself is a
             lightweight fake (no real network call to Telegram), since this
             module's own responsibility -- HTTP request handling, chat_id
             gating, response shaping -- is what's under test here, not
             TelegramClient's own API contract (already covered by
             test_telegram_client.py).
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-04)
"""

from __future__ import annotations

import json
import socket
import urllib.error
import urllib.request

import pytest

from curtain_bridge.crash_relay import DEFAULT_CRASH_RELAY_PORT, CrashRelayModule


class _FakeConfig:
    """Minimal stand-in for service.BridgeConfig -- only `.extra` is read by
    CrashRelayModule.start(), matching test_health.py's _FakeConfig."""

    def __init__(self, extra: dict[str, object] | None = None) -> None:
        self.extra = extra or {}


class _FakeTelegramClient:
    """Records every send_message call instead of hitting the real Telegram
    API -- this module's job (HTTP handling, chat_id gating) is under test,
    not TelegramClient's own request/response contract."""

    def __init__(self, *, raise_on_send: bool = False) -> None:
        self.sent: list[tuple[int, str]] = []
        self._raise_on_send = raise_on_send

    def send_message(self, chat_id: int, text: str) -> int:
        if self._raise_on_send:
            raise RuntimeError("simulated Telegram API failure")
        self.sent.append((chat_id, text))
        return 42


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


async def _start_module(client: _FakeTelegramClient, chat_id: int | None) -> tuple[CrashRelayModule, int]:
    port = _free_port()
    module = CrashRelayModule(client, lambda: chat_id)
    await module.start(_FakeConfig(extra={"crash_relay_port": port}))
    return module, port


def _post(port: int, body: dict[str, object] | bytes) -> tuple[int, dict[str, object]]:
    return _post_raw(port, "/crash-report", body)


def _post_raw(port: int, path: str, body: dict[str, object] | bytes) -> tuple[int, dict[str, object]]:
    payload = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


@pytest.mark.asyncio
async def test_crash_report_relays_when_chat_id_known():
    client = _FakeTelegramClient()
    module, port = await _start_module(client, chat_id=555)
    try:
        status, body = _post(port, {"summary": "Curtain.app crashed: SIGABRT"})
    finally:
        await module.stop()

    assert status == 200
    assert body["status"] == "sent"
    assert body["message_id"] == 42
    assert client.sent == [(555, "Crash report from Curtain's Mac:\n\nCurtain.app crashed: SIGABRT")]


@pytest.mark.asyncio
async def test_crash_report_returns_503_when_chat_id_unknown():
    client = _FakeTelegramClient()
    module, port = await _start_module(client, chat_id=None)
    try:
        status, body = _post(port, {"summary": "Curtain.app crashed: SIGABRT"})
    finally:
        await module.stop()

    assert status == 503
    assert body["status"] == "no_chat_id"
    assert client.sent == []


@pytest.mark.asyncio
async def test_crash_report_returns_400_for_empty_summary():
    client = _FakeTelegramClient()
    module, port = await _start_module(client, chat_id=555)
    try:
        status, body = _post(port, {"summary": "   "})
    finally:
        await module.stop()

    assert status == 400
    assert body["status"] == "empty_summary"
    assert client.sent == []


@pytest.mark.asyncio
async def test_crash_report_returns_400_for_invalid_json():
    client = _FakeTelegramClient()
    module, port = await _start_module(client, chat_id=555)
    try:
        status, body = _post(port, b"not json")
    finally:
        await module.stop()

    assert status == 400
    assert body["status"] == "invalid_json"


@pytest.mark.asyncio
async def test_crash_report_returns_502_when_send_fails():
    client = _FakeTelegramClient(raise_on_send=True)
    module, port = await _start_module(client, chat_id=555)
    try:
        status, body = _post(port, {"summary": "Curtain.app crashed: SIGABRT"})
    finally:
        await module.stop()

    assert status == 502
    assert body["status"] == "send_failed"


@pytest.mark.asyncio
async def test_crash_report_404s_unknown_path():
    # POST (not GET) to a wrong path -- this handler only implements do_POST
    # (matching health.py's GET-only shape, mirrored for POST), so a GET
    # request itself 501s via BaseHTTPRequestHandler's default "Unsupported
    # method" response before ever reaching this module's own routing; the
    # 404 case this module is actually responsible for is a POST to any path
    # other than /crash-report.
    client = _FakeTelegramClient()
    module, port = await _start_module(client, chat_id=555)
    try:
        status, _ = _post_raw(port, "/nope", b'{"summary": "x"}')
        assert status == 404
    finally:
        await module.stop()


@pytest.mark.asyncio
async def test_crash_relay_module_defaults_to_documented_port_when_unspecified():
    client = _FakeTelegramClient()
    module = CrashRelayModule(client, lambda: 555)
    await module.start(_FakeConfig(extra={}))
    try:
        status, body = _post(DEFAULT_CRASH_RELAY_PORT, {"summary": "test"})
    finally:
        await module.stop()

    assert status == 200
    assert body["status"] == "sent"
