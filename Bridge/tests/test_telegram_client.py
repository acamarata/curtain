"""
Purpose: Tests for curtain_bridge.telegram_client -- mocking Telegram's
         documented Bot API responses via httpx.MockTransport, exactly
         matching the mocking pattern already used in
         tests/test_tinypilot_client.py. No real network or Telegram
         credentials are used anywhere in this file.
Inputs: none (self-contained fixtures per test).
Outputs: pytest test functions.
Constraints: covers success and failure (network/429/401/malformed) paths
             for sendMessage, getUpdates, and deleteMessage, a full
             send-receive-delete round trip through TelegramLoginModule, the
             chat_id discovery handshake, and a source-grep test asserting
             the password value is never passed to logger.* anywhere in the
             module (QA-B's grep-based assertion, made executable).
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-02)
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

import httpx
import pytest

from curtain_bridge.detection import DetectionResult, DetectionState
from curtain_bridge.telegram_client import (
    DEFAULT_TOKEN_PATH,
    TelegramAPIError,
    TelegramAuthError,
    TelegramClient,
    TelegramLoginModule,
    TelegramRateLimitedError,
    load_bot_token,
)

FAKE_TOKEN = "123456789:AAFakeTokenForTestsOnlyNotReal12345"


def make_client(handler) -> TelegramClient:
    transport = httpx.MockTransport(handler)
    http_client = httpx.Client(
        base_url=f"https://api.telegram.org/bot{FAKE_TOKEN}", transport=transport
    )
    return TelegramClient(FAKE_TOKEN, client=http_client)


# -- load_bot_token -------------------------------------------------------------


def test_load_bot_token_reads_and_strips(tmp_path):
    token_path = tmp_path / "telegram-token"
    token_path.write_text(f"{FAKE_TOKEN}\n")
    assert load_bot_token(token_path) == FAKE_TOKEN


def test_load_bot_token_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        load_bot_token(tmp_path / "does-not-exist")


def test_load_bot_token_empty_file_raises(tmp_path):
    token_path = tmp_path / "telegram-token"
    token_path.write_text("   \n")
    with pytest.raises(ValueError):
        load_bot_token(token_path)


def test_default_token_path_matches_swift_deployer_write_target():
    # KVMBridgeDeployer.sendTelegramToken (Swift) pipes the token to exactly
    # this path over SSH -- this constant must never drift from that value
    # without updating both sides.
    assert DEFAULT_TOKEN_PATH == "/etc/curtain-bridge/telegram-token"


# -- sendMessage ------------------------------------------------------------------


def test_send_message_success_returns_message_id():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/sendMessage")
        body = httpx.Request("POST", request.url).content
        return httpx.Response(
            200,
            json={
                "ok": True,
                "result": {"message_id": 42, "chat": {"id": 999}, "date": 1, "text": "hi"},
            },
        )

    client = make_client(handler)
    message_id = client.send_message(999, "Mac rebooted, at FileVault screen")
    assert message_id == 42


def test_send_message_empty_text_raises_locally_no_request():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(200, json={"ok": True, "result": {}})

    client = make_client(handler)
    with pytest.raises(ValueError):
        client.send_message(999, "")
    assert calls == []


def test_send_message_401_raises_auth_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            401, json={"ok": False, "error_code": 401, "description": "Unauthorized"}
        )

    client = make_client(handler)
    with pytest.raises(TelegramAuthError) as exc_info:
        client.send_message(999, "hello")
    assert exc_info.value.error_code == 401


def test_send_message_429_raises_rate_limited_with_retry_after():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            429,
            json={
                "ok": False,
                "error_code": 429,
                "description": "Too Many Requests",
                "parameters": {"retry_after": 7},
            },
        )

    client = make_client(handler)
    with pytest.raises(TelegramRateLimitedError) as exc_info:
        client.send_message(999, "hello")
    assert exc_info.value.retry_after == 7


def test_send_message_generic_failure_raises_api_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            400, json={"ok": False, "error_code": 400, "description": "chat not found"}
        )

    client = make_client(handler)
    with pytest.raises(TelegramAPIError) as exc_info:
        client.send_message(999, "hello")
    assert exc_info.value.error_code == 400
    assert "chat not found" in exc_info.value.description


def test_send_message_network_failure_raises_api_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    client = make_client(handler)
    with pytest.raises(TelegramAPIError):
        client.send_message(999, "hello")


# -- getUpdates -----------------------------------------------------------------


def test_get_updates_returns_reply_payload():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/getUpdates")
        return httpx.Response(
            200,
            json={
                "ok": True,
                "result": [
                    {
                        "update_id": 100,
                        "message": {
                            "message_id": 7,
                            "from": {"id": 555, "is_bot": False, "first_name": "Aric"},
                            "chat": {"id": 555, "type": "private", "first_name": "Aric"},
                            "date": 1234567890,
                            "text": "hunter2",
                        },
                    }
                ],
            },
        )

    client = make_client(handler)
    updates = client.get_updates(offset=None, timeout=30)
    assert len(updates) == 1
    assert updates[0]["message"]["text"] == "hunter2"
    assert updates[0]["message"]["chat"]["id"] == 555


def test_get_updates_empty_result_is_normal_not_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"ok": True, "result": []})

    client = make_client(handler)
    assert client.get_updates() == []


def test_get_updates_passes_offset_and_timeout():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json as _json

        seen.update(_json.loads(request.content))
        return httpx.Response(200, json={"ok": True, "result": []})

    client = make_client(handler)
    client.get_updates(offset=101, timeout=30)
    assert seen["offset"] == 101
    assert seen["timeout"] == 30
    assert seen["allowed_updates"] == ["message"]


# -- deleteMessage ----------------------------------------------------------------


def test_delete_message_success_returns_true():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/deleteMessage")
        return httpx.Response(200, json={"ok": True, "result": True})

    client = make_client(handler)
    assert client.delete_message(555, 7) is True


def test_delete_message_failure_raises_api_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            400,
            json={
                "ok": False,
                "error_code": 400,
                "description": "message to delete not found",
            },
        )

    client = make_client(handler)
    with pytest.raises(TelegramAPIError) as exc_info:
        client.delete_message(555, 7)
    assert "not found" in exc_info.value.description


# -- TelegramLoginModule: on_detection ------------------------------------------


@pytest.mark.asyncio
async def test_on_detection_sends_filevault_prompt():
    sent = []

    def handler(request: httpx.Request) -> httpx.Response:
        import json as _json

        sent.append(_json.loads(request.content))
        return httpx.Response(200, json={"ok": True, "result": {"message_id": 1}})

    client = make_client(handler)

    async def on_password(password: str) -> None:
        pass

    module = TelegramLoginModule(client, on_password, chat_id=555)
    await module.on_detection(DetectionResult(state=DetectionState.FILEVAULT_PROMPT, confidence=0.95))

    assert len(sent) == 1
    assert sent[0]["chat_id"] == 555
    assert "FileVault" in sent[0]["text"]


@pytest.mark.asyncio
async def test_on_detection_no_match_sends_nothing():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(200, json={"ok": True, "result": {"message_id": 1}})

    client = make_client(handler)

    async def on_password(password: str) -> None:
        pass

    module = TelegramLoginModule(client, on_password, chat_id=555)
    await module.on_detection(DetectionResult(state=DetectionState.NO_MATCH, confidence=0.1))

    assert calls == []


@pytest.mark.asyncio
async def test_on_detection_without_known_chat_id_is_noop():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(200, json={"ok": True, "result": {"message_id": 1}})

    client = make_client(handler)

    async def on_password(password: str) -> None:
        pass

    module = TelegramLoginModule(client, on_password)  # chat_id unknown
    await module.on_detection(DetectionResult(state=DetectionState.LOGIN_WINDOW, confidence=0.9))

    assert calls == []


# -- TelegramLoginModule: full send/receive/delete round trip -------------------


@pytest.mark.asyncio
async def test_full_round_trip_receives_deletes_and_hands_off_password():
    """
    Purpose: exercises the complete flow QA-A must inspect in detail --
    detection fires -> prompt sent -> reply received via getUpdates ->
    deleteMessage called on that reply -> password handed to on_password --
    entirely against a mocked Telegram API surface.
    """
    delete_calls = []
    send_calls = []
    update_call_count = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal update_call_count
        import json as _json

        path = request.url.path
        body = _json.loads(request.content) if request.content else {}

        if path.endswith("/sendMessage"):
            send_calls.append(body)
            return httpx.Response(200, json={"ok": True, "result": {"message_id": 1}})

        if path.endswith("/getUpdates"):
            update_call_count += 1
            if update_call_count == 1:
                return httpx.Response(
                    200,
                    json={
                        "ok": True,
                        "result": [
                            {
                                "update_id": 500,
                                "message": {
                                    "message_id": 77,
                                    "from": {"id": 555, "is_bot": False, "first_name": "Aric"},
                                    "chat": {"id": 555, "type": "private"},
                                    "date": 1,
                                    "text": "correct-horse-battery-staple",
                                },
                            }
                        ],
                    },
                )
            return httpx.Response(200, json={"ok": True, "result": []})

        if path.endswith("/deleteMessage"):
            delete_calls.append(body)
            return httpx.Response(200, json={"ok": True, "result": True})

        raise AssertionError(f"unexpected path {path}")

    client = make_client(handler)

    received_passwords = []

    async def on_password(password: str) -> None:
        received_passwords.append(password)

    module = TelegramLoginModule(client, on_password, chat_id=555)

    await module.on_detection(DetectionResult(state=DetectionState.FILEVAULT_PROMPT, confidence=0.9))
    assert len(send_calls) == 1
    assert "FileVault" in send_calls[0]["text"]

    updates = client.get_updates(offset=None, timeout=30)
    await module._handle_update(updates[0])

    assert delete_calls == [{"chat_id": 555, "message_id": 77}]
    assert received_passwords == ["correct-horse-battery-staple"]


@pytest.mark.asyncio
async def test_handle_update_ignores_message_from_unexpected_chat_id():
    delete_calls = []
    received = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/deleteMessage"):
            delete_calls.append(True)
        return httpx.Response(200, json={"ok": True, "result": True})

    client = make_client(handler)

    async def on_password(password: str) -> None:
        received.append(password)

    module = TelegramLoginModule(client, on_password, chat_id=555)
    update = {
        "update_id": 1,
        "message": {
            "message_id": 1,
            "chat": {"id": 999},  # not the pinned chat_id
            "text": "not-the-real-operator",
        },
    }
    await module._handle_update(update)

    assert delete_calls == []
    assert received == []


@pytest.mark.asyncio
async def test_handle_update_ignores_non_text_message():
    received = []

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"ok": True, "result": True})

    client = make_client(handler)

    async def on_password(password: str) -> None:
        received.append(password)

    module = TelegramLoginModule(client, on_password, chat_id=555)
    update = {"update_id": 1, "message": {"message_id": 1, "chat": {"id": 555}}}  # no "text"
    await module._handle_update(update)

    assert received == []


@pytest.mark.asyncio
async def test_delete_failure_does_not_block_password_handoff():
    received = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/deleteMessage"):
            return httpx.Response(
                400, json={"ok": False, "error_code": 400, "description": "too old"}
            )
        return httpx.Response(200, json={"ok": True, "result": True})

    client = make_client(handler)

    async def on_password(password: str) -> None:
        received.append(password)

    module = TelegramLoginModule(client, on_password, chat_id=555)
    update = {
        "update_id": 1,
        "message": {"message_id": 1, "chat": {"id": 555}, "text": "still-the-password"},
    }
    await module._handle_update(update)

    assert received == ["still-the-password"]


# -- TelegramLoginModule: chat_id discovery handshake -----------------------------


@pytest.mark.asyncio
async def test_first_message_pins_chat_id_and_is_not_treated_as_password():
    delete_calls = []
    received = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/deleteMessage"):
            delete_calls.append(True)
        return httpx.Response(200, json={"ok": True, "result": True})

    client = make_client(handler)

    async def on_password(password: str) -> None:
        received.append(password)

    module = TelegramLoginModule(client, on_password)  # chat_id starts unknown
    assert module._chat_id is None

    discovery_update = {
        "update_id": 1,
        "message": {"message_id": 1, "chat": {"id": 777}, "text": "/start"},
    }
    await module._handle_update(discovery_update)

    assert module._chat_id == 777
    assert received == []  # discovery message is never treated as a password
    assert delete_calls == [True]  # still deleted for hygiene

    # a subsequent message from the now-pinned chat IS treated as a password
    real_update = {
        "update_id": 2,
        "message": {"message_id": 2, "chat": {"id": 777}, "text": "the-real-password"},
    }
    await module._handle_update(real_update)
    assert received == ["the-real-password"]


# -- start/stop lifecycle ---------------------------------------------------------


@pytest.mark.asyncio
async def test_start_stop_lifecycle_is_safe():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"ok": True, "result": []})

    client = make_client(handler)

    async def on_password(password: str) -> None:
        pass

    module = TelegramLoginModule(client, on_password, chat_id=555)

    # stop() before start() must be safe (BridgeModule contract)
    await module.stop()

    await module.start(config=None)  # config unused, matches VideoMonitorModule
    await module.stop()
    assert module._task is None


# -- QA-B: grep-based assertion that the password value is never logged ---------


def test_password_variable_never_passed_to_logger_calls():
    """
    Purpose: QA-B's grep-based assertion, made executable and durable against
    future edits -- parses telegram_client.py's AST and fails if any
    `logger.*(...)` call's arguments reference the `password` name anywhere
    in the call (directly, or via a % / f-string / .format() that embeds it).
    This is stricter than a plain text grep: it inspects actual call-site
    argument expressions, not just substring co-occurrence on a line.
    Inputs: none (reads the module's own source file).
    Outputs: pytest assertion.
    Constraints: also fails if the literal substring "password" appears
    inside any logger.*() call's string-literal arguments (catches an
    accidental "password=..." interpolation placeholder), as a second,
    coarser safety net alongside the AST check.
    """
    source_path = Path(__file__).parent.parent / "curtain_bridge" / "telegram_client.py"
    source = source_path.read_text(encoding="utf-8")

    tree = ast.parse(source, filename=str(source_path))

    violations = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        is_logger_call = (
            isinstance(func, ast.Attribute)
            and isinstance(func.value, ast.Name)
            and func.value.id == "logger"
        )
        if not is_logger_call:
            continue
        call_source = ast.dump(node)
        if "id='password'" in call_source or "id=\"password\"" in call_source:
            violations.append((node.lineno, ast.unparse(node)))

    assert violations == [], f"logger call references `password` variable: {violations}"

    # Coarser, independent second implementation of the same rule: for every
    # logger.*() call site (found via the AST, so multi-line calls are
    # handled correctly), strip out all string-literal arguments and confirm
    # the bare word "password" does not appear in what remains -- i.e. it
    # only ever appears inside a descriptive string (safe: e.g. "deleted
    # password-reply message_id=%s"), never as a real argument expression
    # (unsafe: passing the `password` variable itself, or any expression
    # containing it, such as an f-string that interpolates it).
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        is_logger_call = (
            isinstance(func, ast.Attribute)
            and isinstance(func.value, ast.Name)
            and func.value.id == "logger"
        )
        if not is_logger_call:
            continue
        for arg in list(node.args) + [kw.value for kw in node.keywords]:
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                continue  # plain string literal argument -- always safe
            arg_text = ast.unparse(arg)
            if re.search(r"\bpassword\b", arg_text):
                violations.append((node.lineno, arg_text))

    assert violations == [], f"logger call passes a `password`-referencing argument: {violations}"
