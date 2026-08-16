"""
Purpose: Character-to-HID-keycode mapping for typing an arbitrary password
         string one `TinyPilotClient.send_keystroke()` call per character.
         TinyPilot's `/api/v1/keystroke` endpoint (see tinypilot_client.py)
         takes exactly one JS `KeyboardEvent.code` value plus eight modifier
         booleans per call -- there is no batch/string endpoint for keystroke
         injection (that is what `/api/v1/paste` is for, and it is
         deliberately NOT used for password entry, see module-level
         constraint below) -- so typing a password means resolving each
         character to its US-QWERTY physical key code plus whichever
         modifier(s) produce that character on a standard keyboard layout.
Inputs: single Python `str` characters (len == 1) via `keystroke_for_char()`.
Outputs: a `Keystroke` (code + modifier booleans) ready to splat as kwargs
         into `TinyPilotClient.send_keystroke(**keystroke.as_kwargs())`.
Constraints: US-QWERTY layout only -- TinyPilot's `/api/v1/keystroke`
             endpoint identifies keys by physical position (`KeyA`, `Digit1`,
             etc, i.e. the JS `KeyboardEvent.code` scheme, which is
             layout-independent on the *receiving* end), so this mapping
             assumes the password was typed by the human, on their own
             keyboard, as US-QWERTY characters -- a password containing a
             character with no US-QWERTY physical-key representation (e.g.
             non-ASCII/Unicode symbols not reachable via Shift on a US
             keyboard) raises `UnsupportedCharacterError` rather than
             silently sending a wrong/adjacent key, since a wrong keystroke
             during password entry is worse than a loud failure. Never
             logs the character being mapped (see hid_typing.py, which is
             the only caller and owns the no-logging invariant for the
             password value itself).
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-03)
"""

from __future__ import annotations

from dataclasses import dataclass


class UnsupportedCharacterError(ValueError):
    """
    Purpose: raised by `keystroke_for_char()` when a character has no known
             US-QWERTY physical-key + modifier representation.
    Inputs: none beyond the standard ValueError message (deliberately does
            NOT include the character itself in a way that could be logged
            insecurely by an unaware caller -- see message wording below).
    Outputs: a message stating a character was unsupported, without ever
             including the *value* of a supposed password character in a
             context a naive `str(exc)` log call could leak verbatim --
             this exception's message intentionally omits the character.
    Constraints: callers (hid_typing.py) must not catch-and-log this
                 exception's message alongside any other password context.
    """

    def __init__(self) -> None:
        super().__init__(
            "character has no US-QWERTY physical-key representation "
            "(unsupported for HID keystroke injection)"
        )


@dataclass(frozen=True)
class Keystroke:
    """
    Purpose: one fully-resolved HID keystroke -- a physical key code plus
             the exact modifier booleans `TinyPilotClient.send_keystroke()`
             expects, matching that method's keyword-argument shape exactly
             so a `Keystroke` can be splatted directly into a call.
    Inputs: constructed only by `keystroke_for_char()` or the fixed re-lock
            combo in `hid_typing.py`.
    Outputs: `as_kwargs()` returns a dict matching
             `TinyPilotClient.send_keystroke`'s signature.
    Constraints: immutable (frozen) -- matches `DetectionResult`/
                 `TelegramReply`'s pattern elsewhere in this codebase.
    """

    code: str
    shift_left: bool = False
    ctrl_left: bool = False
    meta_left: bool = False

    def as_kwargs(self) -> dict[str, bool | str]:
        """Purpose: shape this Keystroke for **-splatting into
        TinyPilotClient.send_keystroke(). Inputs/Outputs: see class docstring."""
        return {
            "code": self.code,
            "shift_left": self.shift_left,
            "ctrl_left": self.ctrl_left,
            "meta_left": self.meta_left,
        }


# -- letters ------------------------------------------------------------------
#
# US-QWERTY: lowercase = bare KeyX, uppercase = KeyX + shiftLeft.
_LETTER_CODES = {chr(ord("a") + i): f"Key{chr(ord('A') + i)}" for i in range(26)}

# -- digit row: unshifted digit, shifted symbol -------------------------------
#
# US-QWERTY digit row layout, top-row physical keys Digit0-Digit9 plus their
# Shift-modified symbols -- the standard US keyboard shift-mapping, not
# derivable algorithmically (it's a historical/typewriter-derived mapping,
# not a formula), so it is enumerated explicitly here.
_DIGIT_ROW = {
    "1": ("Digit1", "!"),
    "2": ("Digit2", "@"),
    "3": ("Digit3", "#"),
    "4": ("Digit4", "$"),
    "5": ("Digit5", "%"),
    "6": ("Digit6", "^"),
    "7": ("Digit7", "&"),
    "8": ("Digit8", "*"),
    "9": ("Digit9", "("),
    "0": ("Digit0", ")"),
}

# -- punctuation: unshifted code, (unshifted char, shifted char) -------------
#
# The remaining US-QWERTY punctuation keys and their Shift-modified partners.
# Source: standard US-QWERTY physical layout (the same layout TinyPilot's own
# `/api/v1/paste` endpoint documents supporting for "en-US" -- see
# tinypilot_client.py's SUPPORTED_PASTE_LANGUAGES -- confirming these are the
# characters a US-layout keyboard, real or KVM-emulated, can produce).
_PUNCTUATION_ROW = {
    "Minus": ("-", "_"),
    "Equal": ("=", "+"),
    "BracketLeft": ("[", "{"),
    "BracketRight": ("]", "}"),
    "Backslash": ("\\", "|"),
    "Semicolon": (";", ":"),
    "Quote": ("'", '"'),
    "Comma": (",", "<"),
    "Period": (".", ">"),
    "Slash": ("/", "?"),
    "Backquote": ("`", "~"),
}

_SPACE_CODE = "Space"


def _build_char_table() -> dict[str, Keystroke]:
    """
    Purpose: build the complete char -> Keystroke lookup table once, at
             import time, from the smaller per-row tables above.
    Inputs: none (reads the module-level _LETTER_CODES/_DIGIT_ROW/
            _PUNCTUATION_ROW tables).
    Outputs: a dict covering every printable US-QWERTY character reachable
             with zero or one Shift modifier.
    Constraints: pure function, no side effects beyond building the dict;
                 called exactly once at module load to populate
                 `_CHAR_TABLE` below rather than being rebuilt per-call.
    """
    table: dict[str, Keystroke] = {}

    for lower, code in _LETTER_CODES.items():
        table[lower] = Keystroke(code=code)
        table[lower.upper()] = Keystroke(code=code, shift_left=True)

    for digit, (code, shifted_char) in _DIGIT_ROW.items():
        table[digit] = Keystroke(code=code)
        table[shifted_char] = Keystroke(code=code, shift_left=True)

    for code, (unshifted_char, shifted_char) in _PUNCTUATION_ROW.items():
        table[unshifted_char] = Keystroke(code=code)
        table[shifted_char] = Keystroke(code=code, shift_left=True)

    table[" "] = Keystroke(code=_SPACE_CODE)

    return table


_CHAR_TABLE: dict[str, Keystroke] = _build_char_table()


def keystroke_for_char(char: str) -> Keystroke:
    """
    Purpose: resolve one character to the Keystroke that produces it on a
             US-QWERTY keyboard.
    Inputs: char (a str of length exactly 1).
    Outputs: a Keystroke.
    Constraints: raises ValueError if len(char) != 1 (a caller bug, not a
                 data problem -- password strings are iterated one character
                 at a time by hid_typing.py, never passed here as a whole).
                 Raises UnsupportedCharacterError (subclass of ValueError)
                 if the character has no US-QWERTY representation in
                 `_CHAR_TABLE` -- see that exception's docstring for why its
                 message omits the character value.
    """
    if len(char) != 1:
        raise ValueError(f"keystroke_for_char expects exactly one character, got {char!r}")
    keystroke = _CHAR_TABLE.get(char)
    if keystroke is None:
        raise UnsupportedCharacterError()
    return keystroke


# -- re-lock combo --------------------------------------------------------------
#
# macOS's standard lock-screen shortcut, Control+Command+Q. Exposed here
# (rather than only inline in hid_typing.py) so its exact modifier shape is
# co-located with the rest of this module's keycode knowledge and easy to
# find/verify independently of the typing-flow logic.
RELOCK_KEYSTROKE = Keystroke(code="KeyQ", ctrl_left=True, meta_left=True)
