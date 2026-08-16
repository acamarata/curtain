"""
Purpose: Unit tests for curtain_bridge.relay_client's Tasmota-compatible
         RelayClient, mocking the relay's local HTTP command API via
         httpx.MockTransport -- no real network or hardware access, matching
         test_tinypilot_client.py's existing pattern.
Inputs: none (self-contained fixtures per test).
Outputs: pytest test functions.
Constraints: covers success (on/off/cycle) and failure (unreachable,
             malformed response, unrecognized POWER value) paths.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E14-02)
"""

from __future__ import annotations

import httpx
import pytest

from curtain_bridge.relay_client import (
    RelayClient,
    RelayNotConfiguredError,
    RelayUnreachableError,
)


def make_relay(handler) -> RelayClient:
    transport = httpx.MockTransport(handler)
    http_client = httpx.Client(base_url="http://relay.test", transport=transport)
    return RelayClient("http://relay.test", client=http_client)


def test_power_on_success():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/cm"
        assert request.url.params["cmnd"] == "Power On"
        return httpx.Response(200, json={"POWER": "ON"})

    relay = make_relay(handler)
    assert relay.power_on() == "ON"


def test_power_off_success():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.params["cmnd"] == "Power Off"
        return httpx.Response(200, json={"POWER": "OFF"})

    relay = make_relay(handler)
    assert relay.power_off() == "OFF"


def test_power_cycle_calls_off_then_on(monkeypatch):
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        cmnd = request.url.params["cmnd"]
        calls.append(cmnd)
        state = "OFF" if cmnd == "Power Off" else "ON"
        return httpx.Response(200, json={"POWER": state})

    relay = make_relay(handler)
    monkeypatch.setattr("curtain_bridge.relay_client.time.sleep", lambda _s: None)

    result = relay.power_cycle()

    assert result == "ON"
    assert calls == ["Power Off", "Power On"]


def test_connection_failure_raises_relay_unreachable_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    relay = make_relay(handler)
    with pytest.raises(RelayUnreachableError):
        relay.power_on()


def test_non_200_status_raises_relay_unreachable_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="internal error")

    relay = make_relay(handler)
    with pytest.raises(RelayUnreachableError):
        relay.power_on()


def test_malformed_json_body_raises_relay_unreachable_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text="not json at all")

    relay = make_relay(handler)
    with pytest.raises(RelayUnreachableError):
        relay.power_on()


def test_missing_power_key_raises_relay_unreachable_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"unexpected": "shape"})

    relay = make_relay(handler)
    with pytest.raises(RelayUnreachableError):
        relay.power_on()


def test_unrecognized_power_value_raises_relay_unreachable_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"POWER": "MAYBE"})

    relay = make_relay(handler)
    with pytest.raises(RelayUnreachableError):
        relay.power_on()


def test_relay_not_configured_error_message_names_the_config_key():
    error = RelayNotConfiguredError()
    assert "relay_url" in str(error)


def test_context_manager_closes_client():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"POWER": "ON"})

    transport = httpx.MockTransport(handler)
    http_client = httpx.Client(base_url="http://relay.test", transport=transport)
    with RelayClient("http://relay.test", client=http_client) as relay:
        relay.power_on()
    assert http_client.is_closed
