"""
Purpose: Telegram Bot API client + reply-listening module implementing the
         human-in-the-loop "Mac rebooted, reply with password to unlock" flow
         triggered by T-P1-E12-01's video detection. Sends a prompt message
         when a FILEVAULT_PROMPT/LOGIN_WINDOW detection fires, long-polls for
         the user's password reply in that same private chat, deletes the
         incoming reply message immediately after reading it, and hands the
         password value to a caller-supplied ephemeral handoff callback (the
         in-process seam T-P1-E12-03's HID-typing step will consume).
Inputs: a bot token (read from the file E-11-02's setup wizard already writes
        via `KVMBridgeDeployer.sendTelegramToken` -- see `load_bot_token()`),
        a target chat_id (the private 1:1 chat the token's owner talks to the
        bot from), a `curtain_bridge.detection.DetectionResult` fed in by
        whatever wires this module to `VideoMonitorModule`'s callback, and an
        `on_password` async callback invoked with the plaintext password.
Outputs: outbound Telegram messages (sendMessage), and a call to
         `on_password(password)` once a reply is received and its source
         message has been deleted.
Constraints: HARD SECURITY BOUNDARY -- this module implements NO auto-unlock
             path. A human must send the password reply themselves, every
             time; there is no standing credential, no cached password, no
             skip-confirmation toggle anywhere in this file. The password
             string exists only in local variables for the minimum number of
             statements needed to delete its source message and hand it to
             `on_password` -- it is never logged (not even at DEBUG level),
             never written to disk, and never stored on `self`. The bot
             token IS persisted (a different risk class -- worst case is
             someone messaging as the bot, not unlocking the disk), reusing
             E-11-02's existing SSH-delivered file at
             `/etc/curtain-bridge/telegram-token` rather than inventing a
             second credential store.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-02)
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Awaitable, Callable

import httpx

if TYPE_CHECKING:
    from curtain_bridge.detection import DetectionResult
    from curtain_bridge.service import BridgeConfig

logger = logging.getLogger("curtain_bridge.telegram_client")

# -- API base -------------------------------------------------------------
#
# Telegram's Bot API is namespaced per-token under this base
# (https://core.telegram.org/bots/api#making-requests): every method call is
# an HTTPS POST/GET to `{API_BASE}{token}/{method}`. There is no separate
# "auth" step like TinyPilot's client has -- the token itself IS the
# credential, included directly in the URL path on every request.
API_BASE = "https://api.telegram.org/bot"

# -- long-polling vs webhook ------------------------------------------------
#
# Long-polling (getUpdates) is used here, not a webhook, because E-11's
# deployment topology (see Bridge/README.md: "A TinyPilot device on the same
# network, reachable by hostname or IP") gives the Pi no public inbound port,
# no reverse proxy, and no TLS termination -- it is a LAN-only device reached
# outbound-only for this purpose. A webhook would require Telegram's servers
# to reach back in over HTTPS with a valid certificate, which means exposing
# a port on the user's home network and provisioning/renewing a TLS cert on
# a Raspberry Pi -- real ongoing operational burden for a single-user bot.
# Long-polling only needs the Pi to make outbound HTTPS calls (already true
# for every other Telegram/TinyPilot call this module and tinypilot_client.py
# make), at the cost of one held-open connection per poll cycle, which is a
# trivial resource cost for a Pi that already runs a continuous video-poll
# loop (see detection.py's VideoMonitorModule). This matches the ticket's
# guide (step 4) and E-11's actual confirmed network setup.
DEFAULT_POLL_TIMEOUT_SECONDS = 30

# Telegram's documented per-message text length ceiling (sendMessage).
_MAX_MESSAGE_LENGTH = 4096

PROMPT_TEXT = {
    "filevault_prompt": (
        "Mac rebooted, at FileVault screen — reply with password to unlock"
    ),
    "login_window": (
        "Mac rebooted, at login window — reply with password to unlock"
    ),
}

# Sent to the human when deleteMessage fails for their password-reply message
# (see TelegramLoginModule._handle_update) -- the human otherwise gets zero
# signal that their plaintext password is still sitting in Telegram chat
# history, since the existing except-branch there only logs the failure.
_DELETE_FAILED_WARNING = (
    "Warning: Curtain could not delete your password reply from this chat "
    "history. Please delete that message manually. Continuing with the "
    "unlock attempt now."
)

# Default location E-11-02's setup wizard writes the bot token to over SSH
# (see `KVMBridgeDeployer.sendTelegramToken`, which pipes the raw token bytes
# via stdin to `cat > /etc/curtain-bridge/telegram-token` -- no JSON wrapper,
# no trailing-newline guarantee). Reused verbatim here rather than inventing
# a second credential store, per this ticket's hard scope constraint.
DEFAULT_TOKEN_PATH = "/etc/curtain-bridge/telegram-token"


class TelegramAPIError(Exception):
    """
    Purpose: Raised for a Telegram Bot API response with `"ok": false` that
             isn't one of the two more specific exceptions below.
    Inputs: error_code (int, Telegram's documented numeric error code),
            description (str, Telegram's human-readable message), method
            (the API method name that failed, e.g. "sendMessage").
    Outputs: a formatted exception message combining all three.
    Constraints: never includes request body contents in the formatted
                 message -- callers of sendMessage/deleteMessage in this
                 module never pass the password value as a parameter to a
                 call that could raise this, but this stays a hard invariant
                 of the exception type itself, not just current call sites.
    """

    def __init__(self, error_code: int, description: str, method: str) -> None:
        self.error_code = error_code
        self.description = description
        self.method = method
        super().__init__(f"Telegram API error on {method}: {error_code} {description}")


class TelegramRateLimitedError(TelegramAPIError):
    """
    Purpose: Raised specifically for a 429 "Too Many Requests" response, so
             callers can retry after the documented `retry_after` window
             instead of treating it as a terminal failure.
    Inputs: retry_after (int, seconds, from the response's
            `parameters.retry_after` field), description, method.
    Outputs: as TelegramAPIError, plus the parsed `retry_after` value.
    Constraints: `retry_after` defaults to 1 if Telegram's response omits the
                 `parameters` object (documented as present but not
                 guaranteed on every 429 by every API version) so callers
                 always have a usable backoff value.
    """

    def __init__(self, retry_after: int, description: str, method: str) -> None:
        self.retry_after = retry_after
        super().__init__(429, description, method)


class TelegramAuthError(TelegramAPIError):
    """
    Purpose: Raised for a 401 Unauthorized response -- the persisted bot
             token is invalid or was revoked via @BotFather. Distinct from
             the generic TelegramAPIError so callers can surface a clear
             "re-run the setup wizard's Telegram step" failure state rather
             than a generic API error.
    """

    def __init__(self, description: str, method: str) -> None:
        super().__init__(401, description, method)


def load_bot_token(path: str | Path = DEFAULT_TOKEN_PATH) -> str:
    """
    Purpose: read the bot token from the file E-11-02's setup wizard already
             delivers it to, over the exact same path
             `KVMBridgeDeployer.sendTelegramToken` writes
             (`/etc/curtain-bridge/telegram-token`) -- reusing that storage
             mechanism rather than inventing a second credential store, per
             this ticket's hard scope constraint.
    Inputs: path (defaults to DEFAULT_TOKEN_PATH; overridable for tests and
            for non-standard installs via config.extra, see
            `TelegramLoginModule.start`).
    Outputs: the token string, stripped of any trailing newline/whitespace
             (the Mac-side writer pipes raw `token.data(using: .utf8)` with
             no guaranteed trailing newline, but stripping is harmless
             either way and protects against a stray newline from manual
             `cat > file` testing on the Pi).
    Constraints: raises FileNotFoundError if the setup wizard's Telegram step
                 hasn't been run yet -- intentionally uncaught here so a
                 misconfigured Bridge fails loudly at module start rather
                 than silently never sending prompts. Never logs the token
                 value itself (only the fact that loading succeeded/failed).
    """
    token = Path(path).read_text(encoding="utf-8").strip()
    if not token:
        raise ValueError(f"telegram bot token file at {path} is empty")
    logger.info("telegram_client: bot token loaded from %s", path)
    return token


@dataclass(frozen=True)
class TelegramReply:
    """
    Purpose: Typed result of a successful long-poll cycle that found a text
             reply in the expected chat -- the shape `_poll_once` returns
             internally before the password is extracted, deleted, and
             handed off.
    Inputs: constructed only by TelegramClient.get_updates() callers.
    Outputs: chat_id, message_id (both needed for the immediate
             deleteMessage call), and text (the raw message body -- the
             caller, not this dataclass, is responsible for treating it as a
             one-time secret and not retaining it).
    Constraints: immutable (frozen), matching DetectionResult's pattern in
                 detection.py -- a point-in-time fact about one update.
    """

    chat_id: int
    message_id: int
    text: str


class TelegramClient:
    """
    Purpose: Thin, typed wrapper around the three Telegram Bot API methods
             this integration needs: sendMessage, getUpdates (long-polling),
             deleteMessage. Mirrors tinypilot_client.TinyPilotClient's shape
             (typed exceptions, httpx.Client injection for tests) for
             consistency across the Bridge's two HTTP clients.
    Inputs: bot_token (the credential, embedded directly in every request
            URL per Telegram's API design -- see API_BASE), an optional
            httpx.Client for injection in tests, and an optional timeout.
    Outputs: see per-method docstrings.
    Constraints: NOT thread-safe for concurrent overlapping getUpdates calls
                 against the same offset tracking -- matches
                 TinyPilotClient's documented single-asyncio-task assumption;
                 TelegramLoginModule drives this from one asyncio task.
    """

    def __init__(
        self,
        bot_token: str,
        *,
        client: httpx.Client | None = None,
        timeout: float = DEFAULT_POLL_TIMEOUT_SECONDS + 10.0,
    ) -> None:
        self._base_url = f"{API_BASE}{bot_token}"
        self._client = client or httpx.Client(base_url=self._base_url, timeout=timeout)

    def close(self) -> None:
        """Purpose: release the underlying HTTP connection pool. Inputs/Outputs: none."""
        self._client.close()

    def __enter__(self) -> "TelegramClient":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def _call(self, method: str, *, json_body: dict[str, Any] | None = None) -> dict[str, Any]:
        """
        Purpose: shared request/response envelope handling for every Telegram
                 API method -- POSTs to `/{method}`, parses the documented
                 `{"ok": bool, "result": ..., "error_code": ..., "description":
                 ..., "parameters": {...}}` envelope, and raises the right
                 typed exception for a non-ok response.
        Inputs: method (e.g. "sendMessage"), json_body (request params, or
                None for parameter-less calls -- none of this module's three
                methods are parameter-less, but the signature stays general).
        Outputs: the parsed `result` value from a `"ok": true` response.
        Constraints: never includes json_body's contents in a log line (only
                     the method name and, on failure, Telegram's own
                     description) -- this is the one call site every
                     sendMessage/getUpdates/deleteMessage invocation funnels
                     through, so keeping it log-body-free here covers all
                     three at once.
        """
        try:
            response = self._client.post(f"/{method}", json=json_body or {})
        except httpx.HTTPError as exc:
            logger.warning("telegram_client: network error calling %s: %s", method, exc)
            raise TelegramAPIError(0, f"network error: {exc}", method) from exc

        try:
            body: dict[str, Any] = response.json()
        except ValueError as exc:
            raise TelegramAPIError(
                response.status_code, "non-JSON response body", method
            ) from exc

        if body.get("ok") is True:
            return body.get("result")

        error_code = int(body.get("error_code", response.status_code))
        description = str(body.get("description", "unknown error"))

        if error_code == 429:
            retry_after = 1
            parameters = body.get("parameters") or {}
            if isinstance(parameters, dict) and "retry_after" in parameters:
                retry_after = int(parameters["retry_after"])
            logger.warning(
                "telegram_client: %s rate-limited, retry_after=%ds", method, retry_after
            )
            raise TelegramRateLimitedError(retry_after, description, method)

        if error_code == 401:
            logger.error("telegram_client: %s got 401 -- bot token invalid/revoked", method)
            raise TelegramAuthError(description, method)

        logger.warning(
            "telegram_client: %s failed: %d %s", method, error_code, description
        )
        raise TelegramAPIError(error_code, description, method)

    # -- sendMessage ------------------------------------------------------------

    def send_message(self, chat_id: int, text: str) -> int:
        """
        Purpose: POST /sendMessage -- send a text message to a chat.
        Inputs: chat_id (int, the target private chat's numeric id), text
                (str, 1-4096 chars per Telegram's documented limit).
        Outputs: the sent message's message_id (int), from the response
                 Message object's "message_id" field.
        Constraints: raises ValueError locally (no request made) if text is
                     empty or exceeds _MAX_MESSAGE_LENGTH -- both are
                     client-side-detectable per Telegram's documented limits.
                     Raises TelegramRateLimitedError/TelegramAuthError/
                     TelegramAPIError per _call()'s envelope handling.
        """
        if not text:
            raise ValueError("text must not be empty")
        if len(text) > _MAX_MESSAGE_LENGTH:
            raise ValueError(f"text exceeds Telegram's {_MAX_MESSAGE_LENGTH}-char limit")
        result = self._call("sendMessage", json_body={"chat_id": chat_id, "text": text})
        return int(result["message_id"])

    # -- getUpdates (long-polling) ------------------------------------------------

    def get_updates(self, offset: int | None = None, timeout: int = DEFAULT_POLL_TIMEOUT_SECONDS) -> list[dict[str, Any]]:
        """
        Purpose: POST /getUpdates -- long-poll for new updates (holds the
                 connection open up to `timeout` seconds server-side,
                 returning immediately if an update is already pending).
        Inputs: offset (int | None; per Telegram's docs, must be one greater
                than the highest update_id already processed, to mark prior
                updates as confirmed/consumed -- None on the first call),
                timeout (int seconds, 0-100s reasonable range per Telegram's
                docs; this module's poll loop always passes
                DEFAULT_POLL_TIMEOUT_SECONDS).
        Outputs: the raw list of Update objects (dicts) from the response's
                 "result" array -- callers extract the reply text/chat_id/
                 message_id from each; parsing into TelegramReply happens in
                 TelegramLoginModule, not here, so this method stays a
                 faithful thin wrapper over the documented contract.
        Constraints: raises the same typed exceptions as _call(). An empty
                     list is a normal, expected long-poll timeout outcome,
                     not an error.
        """
        body: dict[str, Any] = {"timeout": timeout, "allowed_updates": ["message"]}
        if offset is not None:
            body["offset"] = offset
        result = self._call("getUpdates", json_body=body)
        return list(result or [])

    # -- deleteMessage ------------------------------------------------------------

    def delete_message(self, chat_id: int, message_id: int) -> bool:
        """
        Purpose: POST /deleteMessage -- delete a message (either the bot's
                 own outgoing message or, in a private 1:1 chat, the user's
                 incoming message to the bot) by chat_id + message_id.
        Inputs: chat_id (int), message_id (int, the message to delete).
        Outputs: True on success, per Telegram's documented Boolean result
                 for this method.
        Constraints: Telegram enforces a 48-hour deletion window for
                     messages in private chats (documented, confirmed during
                     this ticket's research) -- a message older than that
                     will fail with a TelegramAPIError, which is irrelevant
                     to this module's actual usage (it always deletes the
                     password-reply message within seconds of receiving it,
                     see TelegramLoginModule._handle_reply) but is not
                     specially caught here since it can never legitimately
                     occur on this module's call path.
        """
        result = self._call(
            "deleteMessage", json_body={"chat_id": chat_id, "message_id": message_id}
        )
        return bool(result)


PasswordHandoff = Callable[[str], Awaitable[None]]


class TelegramLoginModule:
    """
    Purpose: BridgeModule-conformant wrapper wiring T-P1-E12-01's detection
             results to an outbound Telegram prompt, and running the
             reply-listening long-poll loop that turns the human's password
             reply into an ephemeral, in-memory-only handoff to
             `on_password` -- the seam T-P1-E12-03's HID-typing step
             consumes. This is the module E-12 registers into service.py's
             registration point (per the ticket's guide, step 6/8).
    Inputs: a TelegramClient (constructed by the caller from the persisted
            bot token -- this module does not load the token itself, mirroring
            VideoMonitorModule's "consume, don't construct the shared client"
            pattern), an optional pinned chat_id (the private chat the human
            replies from), and an on_password async callback. E-11-02's setup
            wizard only ever delivers the bot token, not a chat_id (Telegram
            bot tokens have no notion of "who talks to this bot" until
            someone actually messages it) -- so when chat_id is omitted
            (None), this module learns it from the first inbound message it
            ever sees (the human's own first message to their new bot, e.g.
            "/start" or any text, sent once after the setup wizard's
            "Create a Telegram bot" step) and pins it as `self._chat_id` for
            every message thereafter. This is a one-time, same-process
            discovery step, not a persisted second credential store.
    Outputs: none directly; side effects are outbound sendMessage calls (via
             `on_detection`, called by VideoMonitorModule per detection.py)
             and eventual `on_password(password)` invocations.
    Constraints: HARD SECURITY BOUNDARY -- `on_detection` only ever sends a
                 prompt asking the human to reply; it never unlocks anything
                 itself. `_poll_loop` only ever reads a reply, deletes it,
                 and hands the value onward -- there is no code path in this
                 class that acts on a password without a human having typed
                 it into Telegram themselves in response to this module's
                 own prompt. Once `self._chat_id` is pinned (either supplied
                 at construction or learned from the first message), only
                 messages from that exact chat_id are ever treated as
                 password replies -- other chat_ids (e.g. someone else
                 discovering and messaging the bot) are logged and ignored,
                 never treated as a reply and never allowed to re-pin
                 `self._chat_id`. NO_MATCH detections are ignored (no
                 message sent), matching the fact that VideoMonitorModule
                 delivers every classification, filtered here per its
                 documented contract in detection.py.
    """

    name = "telegram_login"

    def __init__(
        self,
        client: "TelegramClient",
        on_password: PasswordHandoff,
        chat_id: int | None = None,
    ) -> None:
        self._client = client
        self._chat_id = chat_id
        self._on_password = on_password
        self._task: asyncio.Task[None] | None = None
        self._stop_event: asyncio.Event | None = None
        self._offset: int | None = None

    async def on_detection(self, result: "DetectionResult") -> None:
        """
        Purpose: DetectionCallback-conformant handler (see detection.py's
                 DetectionCallback type) -- called by VideoMonitorModule with
                 every classified frame; sends the matching prompt for
                 FILEVAULT_PROMPT/LOGIN_WINDOW and does nothing for NO_MATCH.
        Inputs: result (a detection.DetectionResult).
        Outputs: none; side effect is an outbound sendMessage call.
        Constraints: NO_MATCH is intentionally a no-op, not an error -- most
                     polled frames are expected to be NO_MATCH (desktop,
                     screensaver, etc.) per VideoMonitorModule's own
                     docstring. A sendMessage failure here is logged and
                     swallowed rather than propagated, so a single transient
                     Telegram API failure can't crash the detection poll loop
                     it's driven from -- the next detection tick will retry.
                     If `self._chat_id` hasn't been learned yet (the human
                     has never messaged the bot), this is a no-op with a
                     warning log rather than a crash or a broadcast to an
                     unknown chat -- there is nowhere safe to send a prompt
                     until the chat_id discovery handshake (see
                     `_handle_update`) has happened at least once.
        """
        if self._chat_id is None:
            logger.warning(
                "telegram_login: detection fired but chat_id not yet known "
                "(human must message the bot once first) -- prompt not sent"
            )
            return
        prompt_key = getattr(result.state, "value", None)
        text = PROMPT_TEXT.get(prompt_key) if prompt_key else None
        if text is None:
            return  # NO_MATCH (or any future state this module doesn't prompt for)
        try:
            await self._send_in_thread(text)
            logger.info("telegram_login: sent prompt for state=%s", prompt_key)
        except Exception:
            logger.exception("telegram_login: failed to send prompt for state=%s", prompt_key)

    async def _send_in_thread(self, text: str) -> None:
        await asyncio.to_thread(self._client.send_message, self._chat_id, text)

    async def _poll_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                updates = await asyncio.to_thread(
                    self._client.get_updates, self._offset, DEFAULT_POLL_TIMEOUT_SECONDS
                )
                for update in updates:
                    self._offset = int(update["update_id"]) + 1
                    await self._handle_update(update)
            except TelegramRateLimitedError as exc:
                logger.warning(
                    "telegram_login: rate-limited, backing off %ds", exc.retry_after
                )
                await asyncio.sleep(exc.retry_after)
            except TelegramAuthError:
                logger.error(
                    "telegram_login: bot token invalid/revoked -- re-run the setup "
                    "wizard's Telegram step to re-provision it"
                )
                await asyncio.sleep(30)
            except Exception:
                logger.exception("telegram_login: error during poll cycle, continuing")
                await asyncio.sleep(1)

    async def _handle_update(self, update: dict[str, Any]) -> None:
        """
        Purpose: extract a text-message reply from one Update object, verify
                 it came from the expected chat, delete it immediately after
                 reading its text, and hand the text to `on_password` -- the
                 single call path in this module that ever touches the
                 plaintext password value.
        Inputs: update (one raw Update dict, as returned by
                TelegramClient.get_updates()).
        Outputs: none; side effects are one deleteMessage call and one
                 on_password() invocation, in that order, when applicable.
        Constraints: SECURITY-CRITICAL -- the local `password` variable is
                     read from `message["text"]`, used only to call
                     `self._on_password(password)`, and never assigned to
                     `self`, never passed to `logger.*`, and never written
                     anywhere else. `delete_message` is called before
                     `on_password` so a crash inside the caller's handoff
                     logic can never leave the plaintext sitting undeleted
                     in the chat. Updates missing a "message" key (e.g.
                     edited_message, channel_post -- excluded by
                     allowed_updates=["message"] but defensively handled
                     anyway) or a "text" key (e.g. a photo/sticker reply) are
                     ignored, not treated as a password. CHAT_ID DISCOVERY:
                     if `self._chat_id` is still None (no human has messaged
                     the bot yet this process lifetime), the first message's
                     chat_id is pinned as `self._chat_id` and this first
                     message is treated as the discovery handshake, NOT as a
                     password -- it is deleted (same immediate-delete
                     hygiene as a real reply, in case the human's first
                     message accidentally contains something sensitive) but
                     `on_password` is never called for it. Every subsequent
                     message must match the pinned `self._chat_id` exactly;
                     a message from any other chat_id is logged (chat id
                     only, never message content) and ignored without
                     re-pinning -- this prevents a second person who
                     discovers the bot's username from ever being treated as
                     the trusted operator.
        """
        message = update.get("message")
        if not message or "text" not in message:
            return

        incoming_chat_id = message.get("chat", {}).get("id")
        message_id = message.get("message_id")

        if self._chat_id is None:
            self._chat_id = incoming_chat_id
            logger.info(
                "telegram_login: chat_id discovered and pinned from first inbound message"
            )
            try:
                await asyncio.to_thread(self._client.delete_message, incoming_chat_id, message_id)
            except Exception:
                logger.exception(
                    "telegram_login: failed to delete discovery handshake message_id=%s",
                    message_id,
                )
            return  # discovery handshake message is never treated as a password

        if incoming_chat_id != self._chat_id:
            logger.warning(
                "telegram_login: ignoring message from unexpected chat_id=%s",
                incoming_chat_id,
            )
            return

        password = message["text"]
        try:
            await asyncio.to_thread(self._client.delete_message, self._chat_id, message_id)
            logger.info("telegram_login: deleted password-reply message_id=%s", message_id)
        except Exception:
            logger.exception(
                "telegram_login: failed to delete password-reply message_id=%s "
                "(continuing to hand off password regardless -- deletion failure "
                "must not block unlock)",
                message_id,
            )
            try:
                await self._send_in_thread(_DELETE_FAILED_WARNING)
            except Exception:
                logger.exception(
                    "telegram_login: failed to send delete-failure warning "
                    "message_id=%s (continuing to hand off password regardless)",
                    message_id,
                )

        await self._on_password(password)
        del password  # explicit: drop the local reference the instant it's handed off

    async def start(self, config: "BridgeConfig") -> None:
        """Purpose: begin the background reply-listening task. Inputs: config
        (unused directly -- client/chat_id are already constructed and
        injected at __init__ time, matching VideoMonitorModule's pattern).
        Outputs: none."""
        self._stop_event = asyncio.Event()
        self._task = asyncio.create_task(self._poll_loop())
        logger.info("telegram_login: started, long-polling chat_id=%s", self._chat_id)

    async def stop(self) -> None:
        """Purpose: stop the reply-listening loop and wait for it to exit
        cleanly. Inputs/Outputs: none. Constraints: safe to call even if
        start() was never called, matching BridgeModule's documented
        stop()-safety contract in service.py."""
        if self._stop_event is not None:
            self._stop_event.set()
        if self._task is not None:
            await self._task
            self._task = None
        logger.info("telegram_login: stopped")
