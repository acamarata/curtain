"""
Purpose: HTTP client for TinyPilot's documented public REST API
         (https://tinypilotkvm.com/pages/tinypilot-rest-api, fetched live during
         ticket T-P1-E11-01). Covers the token-auth flow plus the screenshot,
         keystroke, and paste endpoints that E-12/E-13 will drive.
Inputs: a TinyPilot base URL (e.g. "http://tinypilot.local") supplied at
        construction; per-call arguments documented on each method below.
Outputs: parsed response bodies (bytes | None for screenshot, None for the
         write endpoints) or a typed exception on failure.
Constraints: TinyPilot requires a paid per-device "Automation License" to be
             activated on the Pi before any of these endpoints will respond
             successfully (see TinyPilotLicenseError below for the caveat on
             how that condition is detected). The auth token has no documented
             expiry -- it is only invalidated by a TinyPilot server restart --
             so this client re-authenticates lazily on the first 401 it sees
             rather than on a timer.
SPORT: MASTER-APPS (Bridge/ deployment artifact)
"""

from __future__ import annotations

import logging
from typing import Any

import httpx

logger = logging.getLogger("curtain_bridge.tinypilot_client")

# Languages TinyPilot's paste endpoint documents as supported. Any other value
# (or unsupported characters within a supported language) yields a 400.
SUPPORTED_PASTE_LANGUAGES = frozenset({"en-US", "en-GB", "de-DE"})


class TinyPilotAPIError(Exception):
    """
    Purpose: Raised when TinyPilot returns a 400 (malformed request) or 500
             (server-side forwarding failure) for keystroke/paste calls, or any
             other unexpected non-2xx/204 status this client doesn't have a
             more specific exception for.
    Inputs: status_code (the HTTP status TinyPilot returned), message (response
            body text or a synthesized description), endpoint (the request path).
    Outputs: a formatted exception message combining all three for logs/errors.
    Constraints: this is the general-purpose failure type; TinyPilotLicenseError
                 is raised instead when the license-inactive signal is detected.
    """

    def __init__(self, status_code: int, message: str, endpoint: str) -> None:
        self.status_code = status_code
        self.message = message
        self.endpoint = endpoint
        super().__init__(f"TinyPilot API error on {endpoint}: {status_code} {message}")


class TinyPilotLicenseError(Exception):
    """
    Purpose: Raised when this client detects that TinyPilot's per-device
             Automation License is not active on the target Pi, so the caller
             gets a specific, actionable error instead of a generic
             TinyPilotAPIError / HTTP failure.
    Inputs: endpoint (the request path that failed), status_code, message.
    Outputs: an exception message pointing at the activation command.
    Constraints: TinyPilot's public docs (tinypilotkvm.com/pages/automation)
                 confirm the license requirement and the on-device activation
                 command (`sudo su tinypilot bash -c
                 "/opt/tinypilot/scripts/activate-license $LICENSE_KEY"`) but do
                 NOT fully specify the exact unlicensed-request response shape.
                 This client currently treats a 401/403 response whose body
                 mentions "license" (case-insensitive) as the license-inactive
                 signal. FLAGGED FOR LIVE-HARDWARE VERIFICATION: the real
                 unlicensed response shape is unconfirmed until hardware is in
                 hand -- this detection heuristic may need adjustment once the
                 actual response is observed.
    """

    def __init__(self, endpoint: str, status_code: int, message: str) -> None:
        self.endpoint = endpoint
        self.status_code = status_code
        self.message = message
        super().__init__(
            f"TinyPilot Automation License appears inactive (on {endpoint}: "
            f"{status_code} {message}). Activate it on the Pi with: "
            'sudo su tinypilot bash -c "/opt/tinypilot/scripts/activate-license $LICENSE_KEY"'
        )


def _looks_like_license_error(status_code: int, body_text: str) -> bool:
    """
    Purpose: Best-effort heuristic to distinguish an inactive-Automation-License
             response from an ordinary auth failure, since TinyPilot's docs
             don't specify the unlicensed response shape precisely.
    Inputs: status_code (int), body_text (raw response body, may be empty).
    Outputs: True if the response looks like a license-inactive rejection.
    Constraints: only applied to 401/403 responses; this is explicitly a
                 heuristic pending live-hardware confirmation (see
                 TinyPilotLicenseError's docstring).
    """
    if status_code not in (401, 403):
        return False
    return "license" in body_text.lower()


class TinyPilotClient:
    """
    Purpose: Thin, typed wrapper around TinyPilot's REST API covering auth,
             screenshot retrieval, keystroke injection, and paste -- the
             surface E-12 (Telegram login-after-reboot) and E-13
             (video-monitoring) will drive.
    Inputs: base_url (e.g. "http://tinypilot.local" or "http://192.168.1.50"),
            an optional httpx.Client for injection in tests, and an optional
            timeout in seconds.
    Outputs: see per-method docstrings.
    Constraints: NOT thread-safe across concurrent calls that both trigger
                 re-authentication (the token cache is a plain instance
                 attribute, not lock-protected) -- callers running this from
                 multiple threads must serialize access or hold their own lock.
                 service.py's skeleton drives this from a single asyncio task
                 per TinyPilot target, which sidesteps the issue for now.
    """

    def __init__(
        self,
        base_url: str,
        *,
        client: httpx.Client | None = None,
        timeout: float = 10.0,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = client or httpx.Client(base_url=self._base_url, timeout=timeout)
        self._token: str | None = None

    def close(self) -> None:
        """Purpose: release the underlying HTTP connection pool. Inputs/Outputs: none."""
        self._client.close()

    def __enter__(self) -> "TinyPilotClient":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    # -- auth ---------------------------------------------------------------

    def authenticate(self) -> str:
        """
        Purpose: POST /api/v1/auth and cache the returned token for use as
                 `Authorization: Bearer <token>` on subsequent calls.
        Inputs: none (uses the client's configured base_url).
        Outputs: the token string (also cached on self._token).
        Constraints: per TinyPilot's docs, the request must NOT include an
                     Origin header -- httpx does not add one by default for a
                     plain POST, so no explicit suppression is needed here.
                     The token has no documented expiry; it is invalidated only
                     by a TinyPilot server restart, so callers should treat a
                     later 401 as the re-auth signal rather than polling.
        """
        response = self._client.post("/api/v1/auth")
        if response.status_code != 200:
            if _looks_like_license_error(response.status_code, response.text):
                raise TinyPilotLicenseError("/api/v1/auth", response.status_code, response.text)
            raise TinyPilotAPIError(response.status_code, response.text, "/api/v1/auth")
        body: dict[str, Any] = response.json()
        token = body["token"]
        self._token = token
        logger.info("tinypilot_client: authenticated, token cached")
        return token

    def _auth_headers(self) -> dict[str, str]:
        if self._token is None:
            self.authenticate()
        assert self._token is not None
        return {"Authorization": f"Bearer {self._token}"}

    def _request_with_reauth(
        self, method: str, path: str, **kwargs: Any
    ) -> httpx.Response:
        """
        Purpose: issue a request with the cached bearer token, transparently
                 re-authenticating once if the server reports 401 (e.g. after a
                 TinyPilot restart invalidated the cached token).
        Inputs: method ("GET"/"POST"), path, and any httpx request kwargs.
        Outputs: the httpx.Response from the (possibly retried) call.
        Constraints: retries at most once to avoid looping against a server
                     that is rejecting auth for a non-token reason (e.g. an
                     inactive license, which is not fixed by re-authenticating).
        """
        headers = dict(kwargs.pop("headers", {}) or {})
        headers.update(self._auth_headers())
        response = self._client.request(method, path, headers=headers, **kwargs)
        if response.status_code == 401:
            logger.info("tinypilot_client: got 401 on %s, re-authenticating once", path)
            self._token = None
            headers.update(self._auth_headers())
            response = self._client.request(method, path, headers=headers, **kwargs)
        return response

    # -- screenshot -----------------------------------------------------------

    def get_screenshot(self) -> bytes | None:
        """
        Purpose: GET /api/v1/screenshot -- retrieve the current video frame.
        Inputs: none.
        Outputs: raw JPEG bytes on 200 OK, or None on 204 No Content (no video
                 input available).
        Constraints: FLAGGED FOR LIVE-HARDWARE VERIFICATION -- real-world JPEG
                     byte validity against an actual video feed is unverified
                     until hardware is available; this method only validates
                     the documented status-code contract (200/204) here.
        """
        response = self._request_with_reauth("GET", "/api/v1/screenshot")
        if response.status_code == 204:
            return None
        if response.status_code != 200:
            if _looks_like_license_error(response.status_code, response.text):
                raise TinyPilotLicenseError(
                    "/api/v1/screenshot", response.status_code, response.text
                )
            raise TinyPilotAPIError(response.status_code, response.text, "/api/v1/screenshot")
        return response.content

    # -- keystroke ------------------------------------------------------------

    def send_keystroke(
        self,
        code: str,
        *,
        shift_left: bool = False,
        shift_right: bool = False,
        alt_left: bool = False,
        alt_right: bool = False,
        ctrl_left: bool = False,
        ctrl_right: bool = False,
        meta_left: bool = False,
        meta_right: bool = False,
    ) -> None:
        """
        Purpose: POST /api/v1/keystroke -- inject a single keystroke with
                 optional modifier keys.
        Inputs: code (a JS KeyboardEvent.code value, e.g. "KeyA"), and eight
                boolean modifier flags matching TinyPilot's documented body
                shape exactly (shiftLeft/shiftRight/altLeft/altRight/
                ctrlLeft/ctrlRight/metaLeft/metaRight).
        Outputs: None on success (200 OK).
        Constraints: raises TinyPilotAPIError on 400 (malformed request) or 500
                     (TinyPilot failed to forward the keystroke to the target
                     machine) -- both are typed, not swallowed. Real forwarding
                     latency/behavior against a live target is FLAGGED FOR
                     LIVE-HARDWARE VERIFICATION.
        """
        body = {
            "code": code,
            "shiftLeft": shift_left,
            "shiftRight": shift_right,
            "altLeft": alt_left,
            "altRight": alt_right,
            "ctrlLeft": ctrl_left,
            "ctrlRight": ctrl_right,
            "metaLeft": meta_left,
            "metaRight": meta_right,
        }
        response = self._request_with_reauth(
            "POST",
            "/api/v1/keystroke",
            json=body,
            headers={"Content-Type": "application/json"},
        )
        if response.status_code != 200:
            if _looks_like_license_error(response.status_code, response.text):
                raise TinyPilotLicenseError(
                    "/api/v1/keystroke", response.status_code, response.text
                )
            raise TinyPilotAPIError(response.status_code, response.text, "/api/v1/keystroke")

    # -- paste ------------------------------------------------------------------

    def paste_text(self, text: str, language: str = "en-US") -> None:
        """
        Purpose: POST /api/v1/paste -- type a block of text via TinyPilot's
                 paste endpoint (faster than per-key keystroke injection for
                 longer strings).
        Inputs: text (the string to type), language (one of "en-US", "en-GB",
                "de-DE" per TinyPilot's documented supported set; defaults to
                "en-US").
        Outputs: None on success (200 OK).
        Constraints: raises ValueError locally (before making a request) if
                     `language` is outside SUPPORTED_PASTE_LANGUAGES, since that
                     is a client-side-detectable mistake. Raises
                     TinyPilotAPIError on 400 (e.g. unsupported characters
                     within an otherwise-supported language) -- that case DOES
                     require a round trip since character-set validity is
                     server-side.
        """
        if language not in SUPPORTED_PASTE_LANGUAGES:
            raise ValueError(
                f"Unsupported paste language {language!r}; "
                f"TinyPilot supports: {sorted(SUPPORTED_PASTE_LANGUAGES)}"
            )
        body = {"text": text, "language": language}
        response = self._request_with_reauth(
            "POST",
            "/api/v1/paste",
            json=body,
            headers={"Content-Type": "application/json"},
        )
        if response.status_code != 200:
            if _looks_like_license_error(response.status_code, response.text):
                raise TinyPilotLicenseError("/api/v1/paste", response.status_code, response.text)
            raise TinyPilotAPIError(response.status_code, response.text, "/api/v1/paste")
