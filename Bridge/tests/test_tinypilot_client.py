"""
Purpose: Unit tests for curtain_bridge.tinypilot_client, mocking TinyPilot's
         documented REST responses via httpx.MockTransport -- no real network
         or hardware access.
Inputs: none (self-contained fixtures per test).
Outputs: pytest test functions.
Constraints: covers both success and failure (400/500/401-reauth/license)
             paths for every endpoint per the ticket's acceptance criteria.
SPORT: MASTER-APPS (Bridge/ deployment artifact)
"""

from __future__ import annotations

import json

import httpx
import pytest

from curtain_bridge.tinypilot_client import (
    TinyPilotAPIError,
    TinyPilotClient,
    TinyPilotLicenseError,
)

FAKE_JPEG = b"\xff\xd8\xff\xe0fake-jpeg-bytes\xff\xd9"


def make_client(handler) -> TinyPilotClient:
    transport = httpx.MockTransport(handler)
    http_client = httpx.Client(base_url="http://tinypilot.test", transport=transport)
    return TinyPilotClient("http://tinypilot.test", client=http_client)


# -- auth ---------------------------------------------------------------------


def test_authenticate_success_caches_token():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        assert request.method == "POST"
        assert request.url.path == "/api/v1/auth"
        assert "Origin" not in request.headers
        return httpx.Response(200, json={"token": "abc-123"})

    client = make_client(handler)
    token = client.authenticate()
    assert token == "abc-123"
    assert client._token == "abc-123"
    assert len(calls) == 1


def test_authenticate_failure_raises_api_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="internal error")

    client = make_client(handler)
    with pytest.raises(TinyPilotAPIError) as exc_info:
        client.authenticate()
    assert exc_info.value.status_code == 500
    assert exc_info.value.endpoint == "/api/v1/auth"


def test_authenticate_license_inactive_raises_license_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(403, text="Automation license is not active")

    client = make_client(handler)
    with pytest.raises(TinyPilotLicenseError) as exc_info:
        client.authenticate()
    assert exc_info.value.status_code == 403
    assert "activate-license" in str(exc_info.value)


# -- screenshot -----------------------------------------------------------------


def test_get_screenshot_200_returns_bytes():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok"})
        assert request.url.path == "/api/v1/screenshot"
        assert request.headers["Authorization"] == "Bearer tok"
        return httpx.Response(200, content=FAKE_JPEG, headers={"content-type": "image/jpeg"})

    client = make_client(handler)
    result = client.get_screenshot()
    assert result == FAKE_JPEG


def test_get_screenshot_204_returns_none():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok"})
        return httpx.Response(204)

    client = make_client(handler)
    result = client.get_screenshot()
    assert result is None


def test_get_screenshot_failure_raises_api_error():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok"})
        return httpx.Response(500, text="boom")

    client = make_client(handler)
    with pytest.raises(TinyPilotAPIError):
        client.get_screenshot()


# -- keystroke --------------------------------------------------------------------


def test_send_keystroke_success():
    seen_bodies = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok"})
        assert request.url.path == "/api/v1/keystroke"
        assert request.headers["Content-Type"] == "application/json"
        seen_bodies.append(json.loads(request.content))
        return httpx.Response(200)

    client = make_client(handler)
    client.send_keystroke("KeyA", shift_left=True)
    assert seen_bodies == [
        {
            "code": "KeyA",
            "shiftLeft": True,
            "shiftRight": False,
            "altLeft": False,
            "altRight": False,
            "ctrlLeft": False,
            "ctrlRight": False,
            "metaLeft": False,
            "metaRight": False,
        }
    ]


def test_send_keystroke_400_raises_api_error():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok"})
        return httpx.Response(400, text="malformed request")

    client = make_client(handler)
    with pytest.raises(TinyPilotAPIError) as exc_info:
        client.send_keystroke("KeyA")
    assert exc_info.value.status_code == 400


def test_send_keystroke_500_raises_api_error():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok"})
        return httpx.Response(500, text="failed to forward to target")

    client = make_client(handler)
    with pytest.raises(TinyPilotAPIError) as exc_info:
        client.send_keystroke("KeyA")
    assert exc_info.value.status_code == 500


def test_send_keystroke_401_triggers_single_reauth_then_succeeds():
    auth_calls = []
    keystroke_calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            auth_calls.append(1)
            return httpx.Response(200, json={"token": f"tok-{len(auth_calls)}"})
        if request.url.path == "/api/v1/keystroke":
            keystroke_calls.append(request.headers["Authorization"])
            if len(keystroke_calls) == 1:
                return httpx.Response(401, text="token invalid")
            return httpx.Response(200)
        raise AssertionError(f"unexpected path {request.url.path}")

    client = make_client(handler)
    client.send_keystroke("KeyA")
    assert auth_calls == [1, 1]  # authenticated twice: initial + after 401
    assert keystroke_calls == ["Bearer tok-1", "Bearer tok-2"]


# -- paste ------------------------------------------------------------------------


def test_paste_text_success():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok"})
        assert request.url.path == "/api/v1/paste"
        body = json.loads(request.content)
        assert body == {"text": "hello world", "language": "en-US"}
        return httpx.Response(200)

    client = make_client(handler)
    client.paste_text("hello world")


def test_paste_text_400_raises_api_error():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok"})
        return httpx.Response(400, text="unsupported characters")

    client = make_client(handler)
    with pytest.raises(TinyPilotAPIError) as exc_info:
        client.paste_text("some unsupported text", language="de-DE")
    assert exc_info.value.status_code == 400


def test_paste_text_unsupported_language_raises_value_error_locally():
    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("should not make a request for an invalid language")

    client = make_client(handler)
    with pytest.raises(ValueError):
        client.paste_text("hola", language="es-ES")


# -- context manager ----------------------------------------------------------------


def test_context_manager_closes_client():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"token": "tok"})

    transport = httpx.MockTransport(handler)
    http_client = httpx.Client(base_url="http://tinypilot.test", transport=transport)
    with TinyPilotClient("http://tinypilot.test", client=http_client) as client:
        client.authenticate()
    assert http_client.is_closed
