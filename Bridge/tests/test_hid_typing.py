"""
Purpose: Tests for curtain_bridge.hid_typing -- confirms HidUnlockModule's
         success path (type -> LOGGED_IN_DESKTOP detected -> re-lock ->
         success message) and failure path (type -> timeout -> failure
         message -> stop, zero further typing calls) against mocked
         TinyPilotClient/TelegramClient/DetectionPoller interfaces, plus the
         hard-security-boundary edge case: a second password reply arriving
         while a typing attempt is already in progress must be rejected,
         never queued or retried, so no code path can ever type more than
         once per human-confirmed reply.
Inputs: none (self-contained fakes per test -- no real network, no real
        TinyPilot/Telegram credentials).
Outputs: pytest test functions.
Constraints: `POST_TYPE_TIMEOUT_SECONDS` and `_POLL_CHECK_INTERVAL_SECONDS`
             are patched down to test-speed values via module attribute
             overrides (same pattern test_detection.py already uses for
             POLL_INTERVAL_SECONDS) rather than sleeping for the real 45s
             timeout.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-03)
"""

from __future__ import annotations

import asyncio

import pytest

from curtain_bridge.detection import DetectionState
from curtain_bridge.hid_typing import (
    SUCCESS_MESSAGE,
    DetectionPoller,
    HidUnlockModule,
    LatestStateTracker,
)


class _FakeTinyPilotClient:
    """Stand-in for TinyPilotClient -- records every send_keystroke call's
    kwargs without touching the network."""

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def send_keystroke(self, code, **modifiers):
        self.calls.append({"code": code, **modifiers})


class _FakeTelegramClient:
    """Stand-in for TelegramClient -- records every send_message call."""

    def __init__(self) -> None:
        self.sent: list[tuple[int, str]] = []

    def send_message(self, chat_id: int, text: str) -> int:
        self.sent.append((chat_id, text))
        return 1


class _ManualPoller:
    """DetectionPoller whose state is set directly by the test, so tests
    control exactly when (or whether) LOGGED_IN_DESKTOP becomes visible."""

    def __init__(self, initial: DetectionState = DetectionState.NO_MATCH) -> None:
        self._state = initial

    def set_state(self, state: DetectionState) -> None:
        self._state = state

    def latest_state(self) -> DetectionState:
        return self._state


def _patch_timing(monkeypatch, timeout: float, interval: float) -> None:
    import curtain_bridge.hid_typing as hid_typing_module

    monkeypatch.setattr(hid_typing_module, "POST_TYPE_TIMEOUT_SECONDS", timeout)
    monkeypatch.setattr(hid_typing_module, "_POLL_CHECK_INTERVAL_SECONDS", interval)


# -- success path -----------------------------------------------------------------


@pytest.mark.asyncio
async def test_success_path_types_detects_relocks_and_sends_success(monkeypatch):
    _patch_timing(monkeypatch, timeout=2.0, interval=0.05)

    tinypilot = _FakeTinyPilotClient()
    telegram = _FakeTelegramClient()
    poller = _ManualPoller(DetectionState.NO_MATCH)

    module = HidUnlockModule(tinypilot, telegram, chat_id=555, detection_poller=poller)

    async def flip_to_logged_in_after_delay():
        await asyncio.sleep(0.1)
        poller.set_state(DetectionState.LOGGED_IN_DESKTOP)

    flipper = asyncio.create_task(flip_to_logged_in_after_delay())
    await module.handle_password("abc123")
    await flipper

    # Exactly one send_keystroke call per password character, plus exactly
    # one more for the re-lock combo -- never more.
    password_calls = tinypilot.calls[: len("abc123")]
    assert len(password_calls) == len("abc123")
    relock_call = tinypilot.calls[-1]
    assert relock_call == {"code": "KeyQ", "shift_left": False, "ctrl_left": True, "meta_left": True}
    assert len(tinypilot.calls) == len("abc123") + 1

    assert telegram.sent == [(555, SUCCESS_MESSAGE)]


@pytest.mark.asyncio
async def test_success_path_types_each_character_exactly_once(monkeypatch):
    _patch_timing(monkeypatch, timeout=2.0, interval=0.05)

    tinypilot = _FakeTinyPilotClient()
    telegram = _FakeTelegramClient()
    poller = _ManualPoller(DetectionState.LOGGED_IN_DESKTOP)  # already there

    module = HidUnlockModule(tinypilot, telegram, chat_id=555, detection_poller=poller)
    await module.handle_password("Hi!")

    # "H" -> shift+KeyH, "i" -> KeyI, "!" -> shift+Digit1, then relock.
    codes = [c["code"] for c in tinypilot.calls]
    assert codes == ["KeyH", "KeyI", "Digit1", "KeyQ"]
    assert tinypilot.calls[0]["shift_left"] is True  # H
    assert tinypilot.calls[1]["shift_left"] is False  # i
    assert tinypilot.calls[2]["shift_left"] is True  # !


# -- failure/timeout path -----------------------------------------------------------


@pytest.mark.asyncio
async def test_failure_path_sends_failure_message_and_stops(monkeypatch):
    _patch_timing(monkeypatch, timeout=0.15, interval=0.05)

    tinypilot = _FakeTinyPilotClient()
    telegram = _FakeTelegramClient()
    poller = _ManualPoller(DetectionState.NO_MATCH)  # never reaches LOGGED_IN_DESKTOP

    module = HidUnlockModule(tinypilot, telegram, chat_id=555, detection_poller=poller)
    await module.handle_password("wrongpass")

    # Typing happened exactly once (one call per character), but NO re-lock
    # call was made -- confirms the failure path never proceeds to re-lock.
    assert len(tinypilot.calls) == len("wrongpass")
    assert all(c["code"] != "KeyQ" for c in tinypilot.calls)

    # Exactly one failure message sent, no success message.
    assert len(telegram.sent) == 1
    assert telegram.sent[0][0] == 555
    assert "did not reach the desktop" in telegram.sent[0][1]


@pytest.mark.asyncio
async def test_failure_path_never_retypes_the_password(monkeypatch):
    """
    Purpose: CR-C's core assertion made executable -- on timeout, the mock's
    send_keystroke call count for the password characters stays at exactly
    len(password), never more, proving no internal retry loop exists.
    """
    _patch_timing(monkeypatch, timeout=0.2, interval=0.05)

    tinypilot = _FakeTinyPilotClient()
    telegram = _FakeTelegramClient()
    poller = _ManualPoller(DetectionState.NO_MATCH)

    module = HidUnlockModule(tinypilot, telegram, chat_id=555, detection_poller=poller)
    password = "correct-horse-battery-staple"
    await module.handle_password(password)

    assert len(tinypilot.calls) == len(password)


# -- hard security boundary: concurrent/racing second reply ------------------------


@pytest.mark.asyncio
async def test_second_password_while_typing_in_progress_is_rejected_not_queued(monkeypatch):
    """
    Purpose: the mid-flow-second-reply edge case CR-C's guidance calls out
    explicitly -- if a second Telegram reply's password arrives while
    handle_password() is still running for a first one, it must be REJECTED
    (busy message sent, zero typing calls for the second password), never
    queued for later and never merged/interleaved with the first attempt.
    """
    _patch_timing(monkeypatch, timeout=2.0, interval=0.02)

    tinypilot = _FakeTinyPilotClient()
    telegram = _FakeTelegramClient()
    poller = _ManualPoller(DetectionState.NO_MATCH)

    module = HidUnlockModule(tinypilot, telegram, chat_id=555, detection_poller=poller)

    async def first_attempt():
        # Never reaches LOGGED_IN_DESKTOP -- stays in progress until the
        # (shortened) timeout, giving the second reply time to race in.
        await module.handle_password("first-password")

    first_task = asyncio.create_task(first_attempt())
    await asyncio.sleep(0.05)  # let the first attempt start typing
    assert module._typing_in_progress is True

    # Second reply arrives mid-flow.
    await module.handle_password("second-password")

    await first_task

    # The second password was never typed -- only "first-password"'s
    # characters appear in the keystroke call log.
    total_password_chars = len("first-password")
    keystroke_codes_for_password = tinypilot.calls[:total_password_chars]
    assert len(keystroke_codes_for_password) == total_password_chars

    # No keystroke call sequence corresponds to "second-password" typing --
    # total calls is exactly first-password's length (no relock, since it
    # timed out) -- proving the second call injected zero keystrokes.
    assert len(tinypilot.calls) == total_password_chars

    # A busy message was sent for the rejected second attempt, in addition
    # to the first attempt's eventual failure message.
    busy_messages = [text for _chat, text in telegram.sent if "already in progress" in text]
    assert len(busy_messages) == 1


@pytest.mark.asyncio
async def test_typing_in_progress_flag_resets_after_completion(monkeypatch):
    _patch_timing(monkeypatch, timeout=0.1, interval=0.02)

    tinypilot = _FakeTinyPilotClient()
    telegram = _FakeTelegramClient()
    poller = _ManualPoller(DetectionState.NO_MATCH)

    module = HidUnlockModule(tinypilot, telegram, chat_id=555, detection_poller=poller)
    await module.handle_password("pw")
    assert module._typing_in_progress is False

    # A subsequent, independent call (a genuinely fresh human reply) is not
    # blocked -- proving the flag doesn't get stuck True.
    await module.handle_password("pw2")
    assert len(tinypilot.calls) == len("pw") + len("pw2")


@pytest.mark.asyncio
async def test_typing_in_progress_flag_resets_after_unsupported_character(monkeypatch):
    _patch_timing(monkeypatch, timeout=0.1, interval=0.02)

    tinypilot = _FakeTinyPilotClient()
    telegram = _FakeTelegramClient()
    poller = _ManualPoller(DetectionState.NO_MATCH)

    module = HidUnlockModule(tinypilot, telegram, chat_id=555, detection_poller=poller)
    await module.handle_password("bad€pw")  # euro sign has no US-QWERTY mapping
    assert module._typing_in_progress is False
    assert any("cannot be typed" in text for _chat, text in telegram.sent)

    # No re-lock or further typing occurred after the failure.
    assert all(c["code"] != "KeyQ" for c in tinypilot.calls)


# -- LatestStateTracker -------------------------------------------------------------


def test_latest_state_tracker_defaults_to_no_match():
    tracker = LatestStateTracker()
    assert tracker.latest_state() == DetectionState.NO_MATCH


def test_latest_state_tracker_records_and_returns_latest():
    tracker = LatestStateTracker()
    tracker.record(DetectionState.FILEVAULT_PROMPT)
    assert tracker.latest_state() == DetectionState.FILEVAULT_PROMPT
    tracker.record(DetectionState.LOGGED_IN_DESKTOP)
    assert tracker.latest_state() == DetectionState.LOGGED_IN_DESKTOP


def test_latest_state_tracker_satisfies_detection_poller_protocol():
    tracker = LatestStateTracker()
    # Structural check: DetectionPoller is a Protocol, so this just confirms
    # the required method exists with the right shape (runtime protocol
    # conformance is duck-typed, not isinstance-checkable without
    # @runtime_checkable, which this module deliberately doesn't add).
    assert hasattr(tracker, "latest_state")
    assert callable(tracker.latest_state)


# -- BridgeModule lifecycle no-ops ---------------------------------------------------


@pytest.mark.asyncio
async def test_start_stop_are_safe_noops():
    tinypilot = _FakeTinyPilotClient()
    telegram = _FakeTelegramClient()
    poller = _ManualPoller()
    module = HidUnlockModule(tinypilot, telegram, chat_id=555, detection_poller=poller)

    await module.start(config=None)
    await module.stop()
    # No exceptions, no side effects.
    assert tinypilot.calls == []
    assert telegram.sent == []
