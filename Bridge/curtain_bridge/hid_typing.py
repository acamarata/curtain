"""
Purpose: The orchestrating module that ties T-P1-E12-01's detection,
         T-P1-E12-02's Telegram human-confirmation channel, and E-11's
         TinyPilot HID keystroke-injection client together into the actual
         unlock flow: receive a human-confirmed password (via
         `TelegramLoginModule`'s `on_password` handoff), type it via HID
         exactly once, poll for a positively-detected `LOGGED_IN_DESKTOP`
         state, then either re-lock + send a success message, or -- on
         timeout -- send a failure message and stop. This is the module
         E-12 registers into `service.py`'s registration point (per the
         ticket's guide, step 7) as the consumer of `TelegramLoginModule`'s
         `on_password` callback.
Inputs: a `TinyPilotClient` (E-11) for keystroke injection, a
        `TelegramClient` (T-P1-E12-02) for the success/failure follow-up
        messages, the pinned chat_id those messages go to, and a detection
        source this module polls for `LOGGED_IN_DESKTOP` after typing (see
        `DetectionPoller` protocol below -- decoupled from
        `VideoMonitorModule`'s push-based callback so this module can poll
        synchronously within its own bounded-timeout loop rather than
        reshaping `VideoMonitorModule`'s push design).
Outputs: none directly; side effects are HID keystroke-injection calls (via
         `TinyPilotClient.send_keystroke`) and Telegram messages (via
         `TelegramClient.send_message`).
Constraints: HARD SECURITY BOUNDARY, non-negotiable -- `handle_password()` is
             the ONLY entry point that ever types a password, and it types
             the exact string it was given exactly once, with no internal
             retry of any kind. There is no code path in this module that
             can be invoked with a cached, replayed, or previously-seen
             password value -- every call is driven directly by
             `TelegramLoginModule._handle_update`'s fresh
             `on_password(password)` invocation for that specific human
             reply (see telegram_client.py's docstring: the local
             `password` variable there is read from one Telegram message,
             handed off once, and immediately dropped). A second Telegram
             reply arriving while a `handle_password()` call is still
             in-flight is handled by `_typing_in_progress` below: it is
             REJECTED (not queued, not merged, not silently ignored-then-
             retried) with an explicit Telegram message telling the human
             to wait for the current attempt to finish -- this guarantees
             at most one typing attempt is ever in flight at a time, so
             "two replies race" can never result in two keystroke sequences
             interleaving on the wire. No password value is ever logged, is
             ever written to disk, or is ever retained past the end of
             `handle_password()`'s single call frame.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-03)
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import TYPE_CHECKING, Protocol

from curtain_bridge.detection import DetectionState
from curtain_bridge.hid_keymap import RELOCK_KEYSTROKE, keystroke_for_char

if TYPE_CHECKING:
    from curtain_bridge.telegram_client import TelegramClient
    from curtain_bridge.tinypilot_client import TinyPilotClient

logger = logging.getLogger("curtain_bridge.hid_typing")

# -- post-type polling timeout -------------------------------------------------
#
# 45.0 seconds. Justification: a macOS login/unlock transition -- password
# accepted, FileVault pre-boot handoff to the full OS (if applicable),
# desktop/Dock/menu-bar render, login-item launch churn settling enough for
# the menu-bar status-icon cluster this module's detection template keys off
# (see detection.py's LOGGED_IN_DESKTOP addition) to actually be on-screen --
# is a multi-second animated sequence, not instantaneous. Apple's own
# documented FileVault-to-desktop transition and typical macOS login
# animations run a few seconds; 45s gives generous headroom above that for a
# slower/older Mac, a post-FileVault full-disk-decrypt boot continuation, or
# a slightly slow TinyPilot screenshot poll cadence (detection.py's
# POLL_INTERVAL_SECONDS = 3.0, so 45s guarantees at least ~13 poll
# opportunities) -- while still being short enough that a genuinely wrong
# password produces a failure message within under a minute rather than
# leaving the human waiting indefinitely wondering if anything is happening.
POST_TYPE_TIMEOUT_SECONDS = 45.0

# How often this module's own poll loop checks the detection source while
# waiting for LOGGED_IN_DESKTOP -- independent of, and slightly faster than,
# VideoMonitorModule's own 3.0s screenshot-capture cadence (detection.py),
# since DetectionPoller implementations are expected to cache/return the
# latest already-classified result rather than forcing a new capture on
# every call (see DetectionPoller's docstring below).
_POLL_CHECK_INTERVAL_SECONDS = 1.0

SUCCESS_MESSAGE = "ready for screen share"
_FAILURE_MESSAGE = (
    "Unlock attempt did not reach the desktop within the timeout — reply "
    "with the password again if you want to retry, or check the Mac "
    "directly."
)
_BUSY_MESSAGE = (
    "An unlock attempt is already in progress — wait for it to finish "
    "before replying again."
)
_UNSUPPORTED_CHARACTER_MESSAGE = (
    "Unlock failed: the password contains a character that cannot be typed "
    "via HID injection on a US keyboard layout. No characters were "
    "retried or guessed — reply with the password again (or a corrected "
    "one) to try again."
)


class DetectionPoller(Protocol):
    """
    Purpose: the minimal read-only contract `HidUnlockModule` needs from a
             detection source to poll for `LOGGED_IN_DESKTOP` after typing,
             decoupled from `VideoMonitorModule`'s specific push-callback
             design so this module doesn't need to reshape that class.
    Inputs: N/A (protocol definition).
    Outputs: N/A (protocol definition).
    Constraints: `latest_state()` is expected to be cheap and non-blocking --
                 implementations should return the most recently classified
                 `DetectionState` from an already-running poll loop (e.g.
                 `VideoMonitorModule`'s own cadence), NOT synchronously
                 trigger a brand-new TinyPilot screenshot capture on every
                 call, since `HidUnlockModule`'s poll loop below calls this
                 every `_POLL_CHECK_INTERVAL_SECONDS`.
    """

    def latest_state(self) -> DetectionState: ...


class LatestStateTracker:
    """
    Purpose: a trivial `DetectionPoller` implementation that records the most
             recent `DetectionState` seen from `VideoMonitorModule`'s
             `on_detection` callback stream, so `HidUnlockModule` can poll
             "what's the latest classified frame" without VideoMonitorModule
             needing any changes.
    Inputs: fed via `record()`, wired as (or alongside) a
            `VideoMonitorModule` `on_detection` callback by whatever
            constructs the module graph in `service.py`.
    Outputs: `latest_state()` returns the most recent recorded state,
             defaulting to `DetectionState.NO_MATCH` before any frame has
             been classified yet.
    Constraints: intentionally NOT itself a `DetectionCallback` (async) --
                 `record()` is a plain sync setter so a thin async lambda/
                 wrapper at the call site can await nothing and just store
                 the value; keeping this class free of asyncio makes it
                 trivially testable without an event loop.
    """

    def __init__(self) -> None:
        self._state: DetectionState = DetectionState.NO_MATCH

    def record(self, state: DetectionState) -> None:
        """Purpose: update the latest recorded state. Inputs: state.
        Outputs: none."""
        self._state = state

    def latest_state(self) -> DetectionState:
        """Purpose: DetectionPoller-conformant read. Inputs/Outputs: see
        class docstring."""
        return self._state


class HidUnlockModule:
    """
    Purpose: BridgeModule-conformant orchestrator wiring HID password typing,
             LOGGED_IN_DESKTOP detection, HID re-lock, and Telegram success/
             failure messaging into the single `handle_password()` entry
             point that `TelegramLoginModule`'s `on_password` callback
             invokes for every fresh, human-confirmed password reply.
    Inputs: a `TinyPilotClient` (for `send_keystroke`), a `TelegramClient`
            (for `send_message`), and the pinned `chat_id` those messages
            go to (matching `TelegramLoginModule`'s already-pinned chat_id
            at the point this module is wired in -- see service.py's
            registration order).
    Outputs: none directly; see module docstring for side effects.
    Constraints: `start()`/`stop()` are no-ops satisfying the `BridgeModule`
                 protocol -- this module has no background task of its own;
                 it is purely reactive, invoked by `TelegramLoginModule`'s
                 `on_password` callback. See module docstring for the full
                 hard-security-boundary constraints on `handle_password()`.
    """

    name = "hid_unlock"

    def __init__(
        self,
        tinypilot_client: "TinyPilotClient",
        telegram_client: "TelegramClient",
        chat_id: int,
        detection_poller: DetectionPoller,
    ) -> None:
        self._tinypilot = tinypilot_client
        self._telegram = telegram_client
        self._chat_id = chat_id
        self._detection_poller = detection_poller
        self._typing_in_progress = False

    async def start(self, config: object) -> None:
        """Purpose: BridgeModule-conformant no-op (this module has no
        background task of its own -- see class docstring). Inputs: config
        (unused). Outputs: none."""
        logger.info("hid_unlock: started (reactive, no background task)")

    async def stop(self) -> None:
        """Purpose: BridgeModule-conformant no-op. Inputs/Outputs: none."""
        logger.info("hid_unlock: stopped")

    # -- the single entry point: TelegramLoginModule's on_password callback --

    async def handle_password(self, password: str) -> None:
        """
        Purpose: the `PasswordHandoff`-conformant callback
                 (telegram_client.PasswordHandoff) wired as
                 `TelegramLoginModule`'s `on_password` -- types `password`
                 via HID exactly once, polls for `LOGGED_IN_DESKTOP`, then
                 re-locks + sends success, or sends failure on timeout.
        Inputs: password (str, the plaintext password for this one
                human-confirmed Telegram reply -- see module docstring for
                the guarantee that this is always a fresh value, never a
                cached/replayed one).
        Outputs: none; side effects as described in the module docstring.
        Constraints: SECURITY-CRITICAL, see module docstring in full. Two
                     invariants enforced directly in this method's control
                     flow: (1) if `_typing_in_progress` is already True (a
                     second Telegram reply raced in while this method is
                     still running for a prior reply), this call returns
                     immediately after sending `_BUSY_MESSAGE` -- it never
                     types anything and never queues the new password for
                     later; (2) `_typing_in_progress` is held True for the
                     ENTIRE attempt -- typing, the post-type detection poll,
                     and the re-lock/failure-message step -- not just the
                     typing sub-call, since a second reply racing in during
                     the post-type poll (before the first attempt's
                     success/failure has even been decided) is exactly the
                     scenario this guard exists to close; it is reset to
                     False in a `finally` block wrapping the whole method
                     body, so it can never get stuck True after an
                     exception and silently block all future attempts.
                     `password` is never assigned to `self` and is allowed
                     to go out of scope at the end of this call frame (the
                     only local aliasing is the `for` loop's per-character
                     `char`, which is itself just a single-character slice,
                     never retained after its iteration).
        """
        if self._typing_in_progress:
            logger.warning(
                "hid_unlock: password reply received while an unlock attempt "
                "is already in progress -- rejecting, not queuing"
            )
            await self._send_message(_BUSY_MESSAGE)
            return

        self._typing_in_progress = True
        try:
            try:
                await self._type_password_once(password)
            except Exception:
                logger.exception(
                    "hid_unlock: unsupported character or HID injection "
                    "failure during typing -- stopping, no retry"
                )
                await self._send_message(_UNSUPPORTED_CHARACTER_MESSAGE)
                return

            reached_desktop = await self._wait_for_logged_in_desktop()
            if reached_desktop:
                await self._relock_and_confirm()
            else:
                await self._send_message(_FAILURE_MESSAGE)
                logger.info("hid_unlock: timeout without LOGGED_IN_DESKTOP, flow stopped")
        finally:
            self._typing_in_progress = False

    async def _type_password_once(self, password: str) -> None:
        """
        Purpose: send exactly one `send_keystroke` call per character of
                 `password`, in order, with no retry of any individual
                 character and no retry of the whole string.
        Inputs: password (str).
        Outputs: none.
        Constraints: the ONLY place in this module (or this codebase) that
                     ever calls `send_keystroke` with a character derived
                     from a real password. `char` (the per-iteration local)
                     is never logged, never included in any exception
                     message (see `keystroke_for_char`'s
                     `UnsupportedCharacterError`, which deliberately omits
                     the character value), and stops discarding references
                     the moment the loop ends -- there is no `password`
                     variable retained on `self` at any point.
        """
        for char in password:
            keystroke = keystroke_for_char(char)
            await asyncio.to_thread(self._tinypilot.send_keystroke, **keystroke.as_kwargs())
        logger.info(
            "hid_unlock: typed password (%d characters), value discarded", len(password)
        )

    async def _wait_for_logged_in_desktop(self) -> bool:
        """
        Purpose: poll `self._detection_poller.latest_state()` every
                 `_POLL_CHECK_INTERVAL_SECONDS` until it reports
                 `DetectionState.LOGGED_IN_DESKTOP` or
                 `POST_TYPE_TIMEOUT_SECONDS` elapses.
        Inputs: none (reads `self._detection_poller`).
        Outputs: True if `LOGGED_IN_DESKTOP` was observed within the
                 timeout, False on timeout.
        Constraints: pure polling/waiting -- performs no keystroke or
                     Telegram action itself; the caller (`handle_password`)
                     decides what to do with the True/False result. Never
                     loops past `POST_TYPE_TIMEOUT_SECONDS`.
        """
        deadline = time.monotonic() + POST_TYPE_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if self._detection_poller.latest_state() == DetectionState.LOGGED_IN_DESKTOP:
                return True
            await asyncio.sleep(_POLL_CHECK_INTERVAL_SECONDS)
        return self._detection_poller.latest_state() == DetectionState.LOGGED_IN_DESKTOP

    async def _relock_and_confirm(self) -> None:
        """
        Purpose: inject the macOS lock-screen key-combo (Control+Command+Q)
                 via HID, then send the "ready for screen share" success
                 message -- called ONLY after `LOGGED_IN_DESKTOP` has been
                 positively confirmed by `_wait_for_logged_in_desktop`.
        Inputs: none.
        Outputs: none.
        Constraints: re-lock is attempted before the success message is
                     sent, matching the ticket's documented order (re-lock,
                     then notify) -- if the re-lock keystroke call itself
                     raises, this propagates rather than sending a false
                     "ready for screen share" claim while the Mac may still
                     be unlocked.
        """
        await asyncio.to_thread(
            self._tinypilot.send_keystroke, **RELOCK_KEYSTROKE.as_kwargs()
        )
        logger.info("hid_unlock: re-lock key-combo injected")
        await self._send_message(SUCCESS_MESSAGE)

    async def _send_message(self, text: str) -> None:
        """Purpose: shared Telegram send helper, swallowing/logging failures
        so a Telegram outage can't crash this module's control flow (matches
        TelegramLoginModule.on_detection's own failure-handling pattern).
        Inputs: text. Outputs: none."""
        try:
            await asyncio.to_thread(self._telegram.send_message, self._chat_id, text)
        except Exception:
            logger.exception("hid_unlock: failed to send Telegram message")
