"""
Purpose: Tests for curtain_bridge.auth -- the shared-secret bearer-token
         gate protecting crash_relay.py's /crash-report and health.py's
         /health from any unauthenticated LAN host (both bind to 0.0.0.0
         by deliberate design; see auth.py's own doc comment for the full
         attack framing this closes).
Inputs: none (each test uses a tmp_path fixture file standing in for
        /etc/curtain-bridge/auth-token, and a minimal fake
        BaseHTTPRequestHandler-shaped object for require_auth).
Outputs: pytest test functions.
Constraints: covers both load_bridge_auth_token's file-read behavior and
             require_auth's fail-closed / constant-time-comparison
             behavior directly (unit-level), separate from
             test_crash_relay.py/test_health.py's end-to-end HTTP-level
             adversarial tests, which exercise the same fail-closed
             behavior through the real handlers.
SPORT: MASTER-APPS (Bridge/ deployment artifact, security follow-up)
"""

from __future__ import annotations

import io
from email.message import Message

import pytest

from curtain_bridge.auth import load_bridge_auth_token, require_auth


class _FakeHandler:
    """Minimal stand-in for BaseHTTPRequestHandler -- require_auth only
    reads `.headers` (an email.message.Message-like mapping) and calls
    `send_response`/`send_header`/`end_headers`/`wfile.write`, so this
    fake records exactly those calls without needing a real socket."""

    def __init__(self, authorization: str | None) -> None:
        self.headers = Message()
        if authorization is not None:
            self.headers["Authorization"] = authorization
        self.wfile = io.BytesIO()
        self.sent_status: int | None = None
        self.sent_headers: list[tuple[str, str]] = []

    def send_response(self, status: int) -> None:
        self.sent_status = status

    def send_header(self, key: str, value: str) -> None:
        self.sent_headers.append((key, value))

    def end_headers(self) -> None:
        pass


# -- load_bridge_auth_token --------------------------------------------------


def test_load_bridge_auth_token_reads_and_strips_file(tmp_path):
    token_path = tmp_path / "auth-token"
    token_path.write_text("s3cr3t-token\n", encoding="utf-8")

    assert load_bridge_auth_token(token_path) == "s3cr3t-token"


def test_load_bridge_auth_token_returns_none_when_file_missing(tmp_path):
    missing_path = tmp_path / "does-not-exist"

    assert load_bridge_auth_token(missing_path) is None


def test_load_bridge_auth_token_returns_none_for_empty_file(tmp_path):
    token_path = tmp_path / "auth-token"
    token_path.write_text("   \n", encoding="utf-8")

    assert load_bridge_auth_token(token_path) is None


# -- require_auth: fail-closed when no token provisioned --------------------


def test_require_auth_rejects_everything_when_expected_token_is_none():
    # The hard-fail-closed case: even a request that presents SOME bearer
    # value must still be rejected when no token has ever been provisioned
    # -- there is no "no token configured means open" fallback anywhere.
    handler = _FakeHandler(authorization="Bearer anything-at-all")
    assert require_auth(handler, expected_token=None) is False
    assert handler.sent_status == 401


def test_require_auth_rejects_when_expected_token_is_none_and_no_header_at_all():
    handler = _FakeHandler(authorization=None)
    assert require_auth(handler, expected_token=None) is False
    assert handler.sent_status == 401


# -- require_auth: normal matching behavior ----------------------------------


def test_require_auth_accepts_matching_bearer_token():
    handler = _FakeHandler(authorization="Bearer correct-token")
    assert require_auth(handler, expected_token="correct-token") is True
    # No response should have been written on the success path -- that's the
    # caller's job to do once it proceeds.
    assert handler.sent_status is None


def test_require_auth_rejects_wrong_token():
    handler = _FakeHandler(authorization="Bearer wrong-token")
    assert require_auth(handler, expected_token="correct-token") is False
    assert handler.sent_status == 401


def test_require_auth_rejects_missing_authorization_header():
    handler = _FakeHandler(authorization=None)
    assert require_auth(handler, expected_token="correct-token") is False
    assert handler.sent_status == 401


def test_require_auth_rejects_non_bearer_scheme():
    handler = _FakeHandler(authorization="Basic correct-token")
    assert require_auth(handler, expected_token="correct-token") is False
    assert handler.sent_status == 401


def test_require_auth_rejects_empty_bearer_value():
    handler = _FakeHandler(authorization="Bearer ")
    assert require_auth(handler, expected_token="correct-token") is False
    assert handler.sent_status == 401


@pytest.mark.parametrize(
    "presented",
    [
        "correct-tok",  # prefix of the real token
        "correct-token-extra",  # real token plus trailing junk
        "CORRECT-TOKEN",  # case mismatch
    ],
)
def test_require_auth_rejects_near_miss_tokens(presented: str):
    handler = _FakeHandler(authorization=f"Bearer {presented}")
    assert require_auth(handler, expected_token="correct-token") is False
    assert handler.sent_status == 401
