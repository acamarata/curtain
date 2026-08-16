"""
Purpose: Template-matching detection of the three Mac boot/login/unlocked
         video states the Bridge must recognize purely from TinyPilot
         screenshot captures (see
         tinypilot_client.TinyPilotClient.get_screenshot): the macOS
         FileVault pre-boot password prompt, the standard macOS login
         window, and (added by T-P1-E12-03) a successfully-logged-in
         desktop state distinct from both. Also implements the continuous
         polling loop that drives detection off a live TinyPilotClient for
         as long as the Bridge is powered on, wired into service.py's
         BridgeModule registration point as VideoMonitorModule.
Inputs: raw JPEG/PNG screenshot bytes (as returned by
        TinyPilotClient.get_screenshot()) fed to detect_state(); a
        TinyPilotClient instance and an async callback fed to
        VideoMonitorModule for the polling loop.
Outputs: a typed DetectionResult (DetectionState + confidence score) from
         detect_state(); VideoMonitorModule calls the supplied callback with
         each DetectionResult as frames are polled.
Constraints: template matching only -- explicitly NOT a vision-model/LLM
             call, both because macOS's login/FileVault/desktop screens are
             visually consistent enough that template matching is
             sufficient, and because sending login-screen images to any
             third-party AI service is unacceptable given what this Mac
             protects (VA/legal/financial records). No auto-unlock or
             credential-caching path exists anywhere in this module -- it
             only classifies frames; T-P1-E12-02 (Telegram) and T-P1-E12-03
             (HID injection) are the only tickets permitted to act on a
             detection result, and both require a human-in-the-loop
             confirmation per the epic's hard security boundary.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-01, extended T-P1-E12-03)
"""

from __future__ import annotations

import asyncio
import io
import logging
from dataclasses import dataclass
from enum import Enum
from importlib import resources
from typing import TYPE_CHECKING, Awaitable, Callable

import cv2
import numpy as np
from PIL import Image

if TYPE_CHECKING:
    from curtain_bridge.service import BridgeConfig
    from curtain_bridge.tinypilot_client import TinyPilotClient

logger = logging.getLogger("curtain_bridge.detection")

# -- library choice -----------------------------------------------------------
#
# OpenCV (`opencv-python-headless`) is the natural choice for Python template
# matching: `cv2.matchTemplate` implements normalized cross-correlation (and
# several other well-understood metrics) in optimized C++, is the de facto
# standard for this exact problem, and `-headless` specifically excludes the
# GUI/video-display bindings this server-side daemon never uses (no X11/Qt
# dependency on a headless Pi). This is a deliberate NEW runtime dependency,
# unlike E-11's health.py which stayed stdlib-only for a trivial HTTP
# responder -- image template matching genuinely needs a real numerical
# image-processing library; reimplementing normalized cross-correlation by
# hand in pure Python would be slower, more error-prone, and harder to
# reason about than depending on OpenCV's mature, widely-used implementation.
# `numpy` is OpenCV's own array representation and is pulled in as a direct
# dependency (not left implicit) so pinning/upgrades are explicit here too.

# -- confidence threshold -----------------------------------------------------
#
# 0.8 normalized cross-correlation (cv2.TM_CCOEFF_NORMED, range [-1.0, 1.0])
# is the match-confidence floor below which a result is treated as NO_MATCH.
# Reasoning: TM_CCOEFF_NORMED scores 1.0 for a pixel-perfect match and falls
# off quickly against structurally different content (different shapes,
# layouts, or color relationships) even under moderate brightness/contrast
# drift, which is the realistic variance expected between the synthetic
# fixtures used here and a real HDMI capture. 0.8 is high enough to reject
# generic dialog chrome and screensavers (see the true-negative fixtures in
# tests/test_detection.py, which score well below this floor) while staying
# low enough to tolerate compression artifacts and minor scaling from a real
# TinyPilot JPEG capture. FLAGGED FOR LIVE-HARDWARE VERIFICATION: this value
# is tuned only against synthetic fixtures; real HDMI capture noise, scaling,
# and color-profile variance are not represented in the current test data
# (see this module's docstring and CHANGELOG.md for the full list of what
# must be re-verified once TinyPilot hardware is purchased) and may require
# adjusting this threshold up or down.
CONFIDENCE_THRESHOLD = 0.8

# -- polling cadence -----------------------------------------------------------
#
# 3.0 seconds balances two costs: responsiveness (a human-in-the-loop
# Telegram confirmation flow, built in T-P1-E12-02, needs a detection to
# surface promptly after a real reboot/login-window appears, not tens of
# seconds later) against continuous Pi CPU/network load (a Raspberry Pi
# running this polling loop 24/7 for as long as the Bridge is powered on
# should not be decoding/matching full-frame images faster than needed --
# matchTemplate over a ~1280x800 frame is cheap, but polling every second
# would still triple the Pi's sustained CPU/network use for no responsiveness
# benefit a human confirming over Telegram would ever notice). 3s sits
# between the 2-5s range the ticket's guide suggests.
POLL_INTERVAL_SECONDS = 3.0

_TEMPLATES_PACKAGE = "curtain_bridge.fixtures.templates"


class DetectionState(Enum):
    """
    Purpose: Typed result of matching one screenshot frame against the known
             reference templates.
    Inputs: N/A (enum definition).
    Outputs: N/A (enum definition).
    Constraints: four members: NO_MATCH, FILEVAULT_PROMPT, LOGIN_WINDOW (all
                 three from T-P1-E12-01), plus LOGGED_IN_DESKTOP (added by
                 T-P1-E12-03) -- a fourth, distinct state confirming the Mac
                 has actually reached the unlocked desktop after a password
                 was typed, so the HID-typing flow can positively detect
                 success rather than assuming it the moment typing finishes.
                 LOGGED_IN_DESKTOP must never be confused with NO_MATCH: a
                 generic "nothing matched" frame (screensaver, blank screen,
                 unrelated app) is NO_MATCH, not a claim about being logged
                 in -- only a frame that positively matches the desktop
                 reference template classifies as LOGGED_IN_DESKTOP.
    """

    NO_MATCH = "no_match"
    FILEVAULT_PROMPT = "filevault_prompt"
    LOGIN_WINDOW = "login_window"
    LOGGED_IN_DESKTOP = "logged_in_desktop"


@dataclass(frozen=True)
class DetectionResult:
    """
    Purpose: Typed return value of detect_state() -- the classified state
             plus the raw confidence score that produced it, so callers (and
             tests) can inspect *why* a classification was made, not just the
             final label.
    Inputs: constructed only by detect_state().
    Outputs: state (DetectionState), confidence (float, the best of the two
             per-template scores actually observed -- 0.0 when state is
             NO_MATCH only because both scores were below threshold, in
             which case confidence still reports the higher of the two raw
             scores for diagnostic/logging purposes, not a synthetic 0.0).
    Constraints: immutable (frozen) -- a detection result is a point-in-time
                 fact about one frame, never mutated after creation.
    """

    state: DetectionState
    confidence: float


def _load_reference_template(filename: str) -> np.ndarray:
    """
    Purpose: load one of the checked-in reference template PNGs (packaged
             under curtain_bridge/fixtures/templates/) as an OpenCV-ready
             BGR numpy array.
    Inputs: filename (e.g. "filevault_prompt.png"), resolved via
            importlib.resources against this package's fixtures.templates
            subpackage so it works both from a source checkout and from an
            installed wheel/sdist (see pyproject.toml's package-data config
            for how these PNGs are included in the built distribution).
    Outputs: a numpy ndarray in OpenCV's default BGR channel order.
    Constraints: raises FileNotFoundError (via resources.files) if the
                 template asset is missing from the installed package --
                 intentionally uncaught so a broken install fails loudly at
                 first use rather than silently always returning NO_MATCH.
    """
    template_bytes = resources.files(_TEMPLATES_PACKAGE).joinpath(filename).read_bytes()
    pil_image = Image.open(io.BytesIO(template_bytes)).convert("RGB")
    rgb_array = np.array(pil_image)
    return cv2.cvtColor(rgb_array, cv2.COLOR_RGB2BGR)


def _decode_frame(screenshot_bytes: bytes) -> np.ndarray:
    """
    Purpose: decode raw screenshot bytes (as returned by
             TinyPilotClient.get_screenshot(), JPEG per that method's
             docstring, though this also accepts PNG since the fixture
             tests below use PNG for lossless synthetic images) into an
             OpenCV-ready BGR numpy array.
    Inputs: screenshot_bytes (raw encoded image bytes).
    Outputs: a numpy ndarray in OpenCV's default BGR channel order.
    Constraints: raises ValueError if the bytes cannot be decoded as an
                 image -- deliberately not swallowed, since a corrupt frame
                 should surface as an error to the polling loop's caller
                 rather than silently classifying as NO_MATCH.
    """
    pil_image = Image.open(io.BytesIO(screenshot_bytes)).convert("RGB")
    rgb_array = np.array(pil_image)
    return cv2.cvtColor(rgb_array, cv2.COLOR_RGB2BGR)


def _best_match_score(frame_bgr: np.ndarray, template_bgr: np.ndarray) -> float:
    """
    Purpose: run cv2.matchTemplate (normalized cross-correlation) of one
             reference template against a full captured frame and return the
             single best match score found anywhere in the frame.
    Inputs: frame_bgr (the full captured screenshot), template_bgr (a
            reference template, smaller than or equal in size to the frame).
    Outputs: a float in [-1.0, 1.0] -- the maximum TM_CCOEFF_NORMED score
             across every position the template was slid to.
    Constraints: if the template is larger than the frame in either
                 dimension (e.g. a frame captured at an unexpectedly small
                 resolution), returns 0.0 rather than letting cv2 raise --
                 this is a real, if unlikely, condition worth degrading
                 gracefully on rather than crashing the polling loop over.
                 A near-zero-variance frame (e.g. solid black/gray right
                 after an HDMI lock) can make TM_CCOEFF_NORMED's
                 near-zero-denominator normalization produce NaN entries in
                 `result`; those are sanitized to -1.0 (this metric's
                 documented minimum) before minMaxLoc so a NaN can never win
                 the max and corrupt the frame's classification.
    """
    frame_h, frame_w = frame_bgr.shape[:2]
    tmpl_h, tmpl_w = template_bgr.shape[:2]
    if tmpl_h > frame_h or tmpl_w > frame_w:
        logger.warning(
            "detection: template (%dx%d) larger than captured frame (%dx%d), skipping",
            tmpl_w,
            tmpl_h,
            frame_w,
            frame_h,
        )
        return 0.0
    result = cv2.matchTemplate(frame_bgr, template_bgr, cv2.TM_CCOEFF_NORMED)
    result = np.nan_to_num(result, nan=-1.0, posinf=1.0, neginf=-1.0)
    _min_val, max_val, _min_loc, _max_loc = cv2.minMaxLoc(result)
    return float(max_val)


def detect_state(screenshot_bytes: bytes) -> DetectionResult:
    """
    Purpose: classify one captured screenshot frame as NO_MATCH,
             FILEVAULT_PROMPT, LOGIN_WINDOW, or LOGGED_IN_DESKTOP by
             template-matching it against all three reference templates and
             comparing against CONFIDENCE_THRESHOLD.
    Inputs: screenshot_bytes (raw encoded image bytes, as returned by
            TinyPilotClient.get_screenshot()).
    Outputs: a DetectionResult. When every template scores below
             CONFIDENCE_THRESHOLD, state is NO_MATCH and confidence reports
             the highest of the three raw scores (for logging/diagnostics,
             not to imply a near-miss). When one or more templates meet or
             exceed the threshold, the highest-scoring template's state wins
             (ties resolve in the fixed order FILEVAULT_PROMPT ->
             LOGIN_WINDOW -> LOGGED_IN_DESKTOP, since each template's
             distinctive region -- padlock, avatar circle, menu-bar/dock
             chrome -- is not expected to plausibly co-match the same real
             frame at a tied score).
    Constraints: never calls any vision-model/LLM API -- this function's
                 entire implementation is local OpenCV template matching
                 against the three checked-in reference PNGs. Never performs
                 any unlock, keystroke, or credential action -- it only
                 classifies and returns; callers (T-P1-E12-02/03) own any
                 subsequent human-confirmed action.
    """
    frame_bgr = _decode_frame(screenshot_bytes)

    filevault_template = _load_reference_template("filevault_prompt.png")
    login_template = _load_reference_template("login_window.png")
    desktop_template = _load_reference_template("logged_in_desktop.png")

    filevault_score = _best_match_score(frame_bgr, filevault_template)
    login_score = _best_match_score(frame_bgr, login_template)
    desktop_score = _best_match_score(frame_bgr, desktop_template)

    scored_states = (
        (filevault_score, DetectionState.FILEVAULT_PROMPT),
        (login_score, DetectionState.LOGIN_WINDOW),
        (desktop_score, DetectionState.LOGGED_IN_DESKTOP),
    )
    best_score = max(score for score, _state in scored_states)
    if best_score < CONFIDENCE_THRESHOLD:
        return DetectionResult(state=DetectionState.NO_MATCH, confidence=best_score)

    # First entry (in the fixed FILEVAULT_PROMPT -> LOGIN_WINDOW ->
    # LOGGED_IN_DESKTOP order above) whose score equals the max wins ties
    # deterministically, matching this function's documented tie-break rule.
    for score, state in scored_states:
        if score == best_score:
            return DetectionResult(state=state, confidence=score)
    raise AssertionError("unreachable: best_score was computed from scored_states")


DetectionCallback = Callable[[DetectionResult], Awaitable[None]]


class VideoMonitorModule:
    """
    Purpose: BridgeModule-conformant wrapper that runs a continuous polling
             loop -- capture a frame via TinyPilotClient.get_screenshot(),
             classify it with detect_state(), invoke the supplied async
             callback with the result -- every POLL_INTERVAL_SECONDS for as
             long as the Bridge service is running. This is the module E-12
             registers into service.py's registration point (per the
             ticket's guide, step 6) to drive detection continuously rather
             than on-demand.
    Inputs: a TinyPilotClient (constructed by the caller from
            config.tinypilot_host/tinypilot_port -- this module does not
            construct its own client, matching the "consume, don't
            reimplement E-11's client" constraint) and an async
            on_detection callback invoked with each DetectionResult.
    Outputs: none directly; side effect is the callback being invoked
             repeatedly while the module is running.
    Constraints: NO_MATCH results are still delivered to the callback (not
                 filtered out here) -- callers that only care about the two
                 target states are expected to filter for themselves,
                 keeping this module's job purely "poll and classify," not
                 "poll, classify, and decide what matters." A single
                 get_screenshot() failure (network hiccup, TinyPilot
                 transiently down) is logged and the loop continues on the
                 next tick rather than crashing the module -- a KVM Bridge
                 that dies on the first transient network blip would defeat
                 the point of it being the thing that still works when the
                 Mac can't help. No auto-unlock or credential-caching path
                 exists in this class or anywhere it's reachable from.
    """

    name = "video_monitor"

    def __init__(self, client: "TinyPilotClient", on_detection: DetectionCallback) -> None:
        self._client = client
        self._on_detection = on_detection
        self._task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()

    async def _poll_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                screenshot = await asyncio.to_thread(self._client.get_screenshot)
                if screenshot is not None:
                    result = detect_state(screenshot)
                    logger.debug(
                        "video_monitor: frame classified as %s (confidence=%.3f)",
                        result.state.value,
                        result.confidence,
                    )
                    await self._on_detection(result)
            except Exception:
                logger.exception("video_monitor: error during poll cycle, continuing")

            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=POLL_INTERVAL_SECONDS)
            except asyncio.TimeoutError:
                pass  # normal case: interval elapsed, loop again

    async def start(self, config: "BridgeConfig") -> None:
        """Purpose: begin the background polling task. Inputs: config (unused
        directly -- the TinyPilotClient is already constructed and injected
        at __init__ time by whatever wires this module into service.py's
        _async_main). Outputs: none. Constraints: idempotent-unsafe if
        called twice without an intervening stop() -- matches every other
        BridgeModule in this codebase (see health.py's HealthModule)."""
        self._stop_event.clear()
        self._task = asyncio.create_task(self._poll_loop())
        logger.info(
            "video_monitor: started, polling every %.1fs (threshold=%.2f)",
            POLL_INTERVAL_SECONDS,
            CONFIDENCE_THRESHOLD,
        )

    async def stop(self) -> None:
        """Purpose: stop the polling loop and wait for it to exit cleanly.
        Inputs/Outputs: none. Constraints: safe to call even if start() was
        never called (self._task stays None) or already stopped, matching
        BridgeModule's documented stop()-safety contract in service.py."""
        self._stop_event.set()
        if self._task is not None:
            await self._task
            self._task = None
        logger.info("video_monitor: stopped")
