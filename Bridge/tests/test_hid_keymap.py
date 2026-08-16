"""
Purpose: Tests for curtain_bridge.hid_keymap -- confirms the
         character-to-HID-keycode mapping covers letters, digits, shifted
         digit-row symbols, punctuation, and space correctly, rejects
         multi-character/empty input and characters with no US-QWERTY
         representation, and that the fixed re-lock combo is expressed
         correctly per TinyPilot's real keystroke contract (E-11).
Inputs: none (pure function tests, no I/O).
Outputs: pytest test functions.
Constraints: exercises the real mapping tables end-to-end (no mocking) --
             this module has no external dependencies to mock.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-03)
"""

from __future__ import annotations

import string

import pytest

from curtain_bridge.hid_keymap import (
    RELOCK_KEYSTROKE,
    Keystroke,
    UnsupportedCharacterError,
    keystroke_for_char,
)

# -- letters --------------------------------------------------------------------


def test_lowercase_letters_map_to_bare_key_code():
    for letter in string.ascii_lowercase:
        keystroke = keystroke_for_char(letter)
        assert keystroke.code == f"Key{letter.upper()}"
        assert keystroke.shift_left is False
        assert keystroke.ctrl_left is False
        assert keystroke.meta_left is False


def test_uppercase_letters_map_to_same_key_code_with_shift():
    for letter in string.ascii_uppercase:
        keystroke = keystroke_for_char(letter)
        assert keystroke.code == f"Key{letter}"
        assert keystroke.shift_left is True


# -- digits + shifted digit-row symbols -----------------------------------------


def test_digits_map_to_bare_digit_code():
    expected = {
        "1": "Digit1", "2": "Digit2", "3": "Digit3", "4": "Digit4", "5": "Digit5",
        "6": "Digit6", "7": "Digit7", "8": "Digit8", "9": "Digit9", "0": "Digit0",
    }
    for digit, code in expected.items():
        keystroke = keystroke_for_char(digit)
        assert keystroke.code == code
        assert keystroke.shift_left is False


def test_shifted_digit_symbols_map_to_digit_code_with_shift():
    expected = {
        "!": "Digit1", "@": "Digit2", "#": "Digit3", "$": "Digit4", "%": "Digit5",
        "^": "Digit6", "&": "Digit7", "*": "Digit8", "(": "Digit9", ")": "Digit0",
    }
    for symbol, code in expected.items():
        keystroke = keystroke_for_char(symbol)
        assert keystroke.code == code
        assert keystroke.shift_left is True


# -- punctuation ------------------------------------------------------------------


def test_punctuation_unshifted_and_shifted_pairs():
    pairs = {
        "-": ("Minus", False), "_": ("Minus", True),
        "=": ("Equal", False), "+": ("Equal", True),
        "[": ("BracketLeft", False), "{": ("BracketLeft", True),
        "]": ("BracketRight", False), "}": ("BracketRight", True),
        "\\": ("Backslash", False), "|": ("Backslash", True),
        ";": ("Semicolon", False), ":": ("Semicolon", True),
        "'": ("Quote", False), '"': ("Quote", True),
        ",": ("Comma", False), "<": ("Comma", True),
        ".": ("Period", False), ">": ("Period", True),
        "/": ("Slash", False), "?": ("Slash", True),
        "`": ("Backquote", False), "~": ("Backquote", True),
    }
    for char, (code, shifted) in pairs.items():
        keystroke = keystroke_for_char(char)
        assert keystroke.code == code
        assert keystroke.shift_left is shifted


def test_space_maps_to_space_code():
    keystroke = keystroke_for_char(" ")
    assert keystroke.code == "Space"
    assert keystroke.shift_left is False


# -- error paths --------------------------------------------------------------------


def test_multi_character_input_raises_value_error():
    with pytest.raises(ValueError):
        keystroke_for_char("ab")


def test_empty_string_raises_value_error():
    with pytest.raises(ValueError):
        keystroke_for_char("")


def test_unsupported_character_raises_specific_error_without_leaking_char():
    with pytest.raises(UnsupportedCharacterError) as exc_info:
        keystroke_for_char("€")
    # The exception message must never embed the actual unsupported
    # character value -- see UnsupportedCharacterError's docstring for why
    # (defense in depth against an unaware caller logging str(exc) verbatim
    # alongside password context).
    assert "€" not in str(exc_info.value)


def test_unsupported_character_is_a_value_error_subclass():
    # Callers that catch ValueError broadly (e.g. hid_typing.py's
    # exception handling) must still catch this.
    assert issubclass(UnsupportedCharacterError, ValueError)


# -- Keystroke.as_kwargs() shape ---------------------------------------------------


def test_as_kwargs_matches_send_keystroke_signature_shape():
    keystroke = Keystroke(code="KeyA", shift_left=True, ctrl_left=False, meta_left=False)
    kwargs = keystroke.as_kwargs()
    assert kwargs == {
        "code": "KeyA",
        "shift_left": True,
        "ctrl_left": False,
        "meta_left": False,
    }


def test_default_keystroke_has_no_modifiers():
    keystroke = keystroke_for_char("x")
    kwargs = keystroke.as_kwargs()
    assert kwargs["shift_left"] is False
    assert kwargs["ctrl_left"] is False
    assert kwargs["meta_left"] is False


# -- re-lock combo ------------------------------------------------------------------


def test_relock_keystroke_is_ctrl_cmd_q():
    # macOS's standard lock-screen shortcut, Control+Command+Q -- confirms
    # this module expresses it exactly as TinyPilotClient.send_keystroke's
    # real contract expects (code="KeyQ", ctrlLeft=True, metaLeft=True).
    assert RELOCK_KEYSTROKE.code == "KeyQ"
    assert RELOCK_KEYSTROKE.ctrl_left is True
    assert RELOCK_KEYSTROKE.meta_left is True
    assert RELOCK_KEYSTROKE.shift_left is False


def test_full_ascii_printable_set_has_no_gaps_except_documented_exclusions():
    # Regression guard: every character in string.printable except
    # whitespace control chars (\t\n\r\v\f, not real password characters)
    # must resolve without raising.
    unsupported = []
    for char in string.ascii_letters + string.digits + string.punctuation + " ":
        try:
            keystroke_for_char(char)
        except UnsupportedCharacterError:
            unsupported.append(char)
    assert unsupported == [], f"unexpectedly unsupported: {unsupported!r}"
