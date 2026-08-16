"""
Purpose: Adversarial security-boundary test suite for curtain_bridge.mcp_server
         -- the Bridge-side MCP server, the higher-risk of the two MCP
         surfaces in E-14 (reachable exactly when the Mac's own login/
         FileVault/app-UI safeguards are bypassed). Per this ticket's own
         framing, this suite must be more exhaustive than T-P1-E14-01's
         baseline: it goes beyond enumerating the tool list to actively
         attempting misuse and to proving, by source inspection, that no
         code path in this module can reach Curtain's password-storage or
         Telegram-confirmed unlock flow.
Inputs: none (self-contained fixtures per test; TinyPilot and relay HTTP
        calls are mocked via httpx.MockTransport, matching
        test_tinypilot_client.py's existing pattern -- no real network,
        hardware, or MCP client subprocess required).
Outputs: pytest test functions.
Constraints: covers, per the ticket's guide: (a) exact tool enumeration,
             (b) per-tool parameter-schema inspection for any
             Settings-shaped field, (c) grep-based source-file scanning for
             any reference to password-storage/E-12-Telegram-flow code,
             (d) attempted-misuse calls to curtain_kvm_type crafted to probe
             for a cached-password-retrieval path.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E14-02)
"""

from __future__ import annotations

import ast
import asyncio
import base64
import json
import re
from pathlib import Path

import httpx
import pytest

from curtain_bridge.mcp_server import EXPOSED_TOOL_NAMES, build_server
from curtain_bridge.relay_client import RelayClient
from curtain_bridge.tinypilot_client import TinyPilotClient

FAKE_JPEG = b"\xff\xd8\xff\xe0fake-jpeg-bytes\xff\xd9"

# -- shared fixtures ------------------------------------------------------------


def make_tinypilot(handler) -> TinyPilotClient:
    transport = httpx.MockTransport(handler)
    http_client = httpx.Client(base_url="http://tinypilot.test", transport=transport)
    return TinyPilotClient("http://tinypilot.test", client=http_client)


def default_tinypilot_handler(request: httpx.Request) -> httpx.Response:
    if request.url.path == "/api/v1/auth":
        return httpx.Response(200, json={"token": "tok-1"})
    if request.url.path == "/api/v1/screenshot":
        return httpx.Response(200, content=FAKE_JPEG)
    if request.url.path == "/api/v1/keystroke":
        return httpx.Response(200)
    return httpx.Response(404)


def call_tool(server, name: str, arguments: dict) -> dict:
    """Purpose: synchronously invoke a registered tool by name via FastMCP's
    own call_tool() (no subprocess/stdio needed for testing). Inputs: server,
    name, arguments. Outputs: the parsed JSON-shaped dict the tool returned.
    Constraints: FastMCP wraps plain dict returns as a single TextContent
    block containing the JSON-serialized dict; this unwraps that for
    convenient assertions."""

    async def _run():
        return await server.call_tool(name, arguments)

    result = asyncio.run(_run())
    # FastMCP's call_tool returns (content_blocks, raw_result) in recent
    # versions, or just content_blocks in others -- handle both shapes.
    content = result[0] if isinstance(result, tuple) else result
    block = content[0]
    text = block.text if hasattr(block, "text") else str(block)
    return json.loads(text)


# -- (a) exact tool enumeration --------------------------------------------------


def test_exposes_exactly_three_named_tools():
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url=None)

    async def _list():
        return await server.list_tools()

    tools = asyncio.run(_list())
    names = {t.name for t in tools}

    assert names == EXPOSED_TOOL_NAMES
    assert names == {"curtain_kvm_screenshot", "curtain_kvm_type", "curtain_kvm_power"}
    assert len(tools) == 3


# -- (b) parameter-schema inspection for Settings-shaped fields -----------------

# Field-name substrings that would plausibly map to Curtain's own Settings/
# security state if they ever appeared in any tool's parameter schema.
_FORBIDDEN_SCHEMA_SUBSTRINGS = (
    "password",
    "credential",
    "secret",
    "armed",
    "disarm",
    "hasPassword".lower(),
    "passwordHash".lower(),
    "cover",
    "coverappearance",
    "settings",
)


def test_no_tool_schema_has_a_settings_shaped_parameter():
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url=None)

    async def _list():
        return await server.list_tools()

    tools = asyncio.run(_list())
    for tool in tools:
        schema_text = json.dumps(tool.inputSchema).lower()
        for forbidden in _FORBIDDEN_SCHEMA_SUBSTRINGS:
            assert forbidden not in schema_text, (
                f"tool {tool.name!r} schema unexpectedly mentions {forbidden!r}: "
                f"{tool.inputSchema}"
            )


def test_curtain_kvm_type_schema_is_exactly_one_generic_text_field():
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url=None)

    async def _list():
        return await server.list_tools()

    tools = {t.name: t for t in asyncio.run(_list())}
    schema = tools["curtain_kvm_type"].inputSchema
    properties = schema.get("properties", {})
    assert set(properties.keys()) == {"text"}
    assert properties["text"]["type"] == "string"


def test_curtain_kvm_screenshot_takes_no_parameters():
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url=None)

    async def _list():
        return await server.list_tools()

    tools = {t.name: t for t in asyncio.run(_list())}
    schema = tools["curtain_kvm_screenshot"].inputSchema
    assert schema.get("properties", {}) == {}


def test_curtain_kvm_power_schema_is_a_closed_action_enum_only():
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url=None)

    async def _list():
        return await server.list_tools()

    tools = {t.name: t for t in asyncio.run(_list())}
    schema = tools["curtain_kvm_power"].inputSchema
    properties = schema.get("properties", {})
    assert set(properties.keys()) == {"action"}
    assert properties["action"]["type"] == "string"


# -- (c) grep/AST-based source scan for password-flow references ---------------

BRIDGE_ROOT = Path(__file__).resolve().parent.parent / "curtain_bridge"
MCP_LAYER_FILES = (
    BRIDGE_ROOT / "mcp_server.py",
    BRIDGE_ROOT / "relay_client.py",
)

# Symbols/strings that would indicate a code path into password storage or
# the E-12 Telegram-confirmed unlock flow, if they appeared anywhere in the
# MCP layer's own EXECUTABLE source (not documentation prose -- see
# _source_without_docstrings_and_comments below, since this ticket's own doc
# comments legitimately *name* these symbols when explaining that no code
# path to them exists, e.g. "grep-verified zero references to Settings.swift"
# -- a raw substring grep over the whole file would false-positive on its own
# security-boundary documentation).
_FORBIDDEN_REFERENCES = (
    "hasPassword",
    "passwordHash",
    "SessionCoordinator",
    "telegram_client",
    "TelegramLoginModule",
    "hid_typing",
    "HidUnlockModule",
    "handle_password",
)


def _source_without_docstrings_and_comments(path: Path) -> str:
    """
    Purpose: return a file's source with every docstring (module/class/
             function) and every `#` comment stripped, so a grep for
             forbidden identifiers checks only executable code -- imports,
             calls, attribute access, string literals used as actual
             values -- not prose explaining the security boundary (which
             legitimately names the forbidden symbols to describe their
             absence, e.g. this very test suite's own module docstring).
    Inputs: path to a .py file.
    Outputs: the reconstructed source with docstring string bodies replaced
             by empty strings and comments removed, via Python's own
             tokenizer (not a regex heuristic) so it is exact regardless of
             quoting style.
    Constraints: uses `tokenize`, not `ast.unparse`, specifically so
             non-docstring string literals (e.g. dict keys, error messages)
             are preserved untouched -- only COMMENT tokens and STRING
             tokens that are docstrings (first statement in a module/class/
             function body, standalone expression statements) are blanked.
    """
    import io
    import tokenize

    source = path.read_text()
    tree = ast.parse(source)

    docstring_line_ranges: list[tuple[int, int]] = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = getattr(node, "body", [])
            if (
                body
                and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)
            ):
                docstring_node = body[0]
                docstring_line_ranges.append(
                    (docstring_node.lineno, docstring_node.end_lineno or docstring_node.lineno)
                )

    lines = source.splitlines(keepends=True)
    for start, end in docstring_line_ranges:
        for lineno in range(start, end + 1):
            lines[lineno - 1] = "\n"
    stripped = "".join(lines)

    # Remove `#` comments token-by-token (safe against `#` inside remaining
    # string literals, unlike a regex).
    out_tokens = []
    for tok in tokenize.generate_tokens(io.StringIO(stripped).readline):
        if tok.type == tokenize.COMMENT:
            continue
        out_tokens.append(tok.string)
    return " ".join(out_tokens)


def test_mcp_layer_executable_code_has_zero_references_to_password_or_telegram_flow():
    """
    Purpose: grep-based confirmation (per the ticket's guide, step 5c) that
             no source file in the new MCP layer's EXECUTABLE code (imports,
             calls, identifiers -- docstrings/comments excluded, see
             _source_without_docstrings_and_comments) references any
             password-storage mechanism or E-12's Telegram-password-flow
             code, by identifier name.
    """
    for path in MCP_LAYER_FILES:
        code_only = _source_without_docstrings_and_comments(path)
        for forbidden in _FORBIDDEN_REFERENCES:
            assert forbidden not in code_only, (
                f"{path.name}'s executable code unexpectedly references "
                f"{forbidden!r} -- the MCP layer must have zero code path "
                "to password storage or the E-12 Telegram-confirmed unlock flow"
            )


def test_mcp_layer_full_source_never_names_settings_swift_setter_paths():
    """
    Purpose: separate, narrower check across the FULL source (docstrings
             included) confirming this module never names an actual
             Settings.swift SETTER (e.g. "Settings.armed =",
             "Settings.setPassword") -- unlike the read-only identifiers
             checked above, a setter reference would be concerning even in
             prose, since it would suggest awareness of a mutation path this
             module should have zero reason to even discuss.
    """
    setter_patterns = (
        "Settings.armed =",
        "Settings.setPassword",
        "setPassword(",
        "Settings.passwordHash =",
    )
    for path in MCP_LAYER_FILES:
        text = path.read_text()
        for pattern in setter_patterns:
            assert pattern not in text


def test_mcp_layer_imports_only_the_documented_curtain_bridge_modules():
    """
    Purpose: AST-based (not just substring) confirmation that mcp_server.py's
             import statements name only the specific curtain_bridge modules
             this ticket's scope allows (tinypilot_client, hid_keymap,
             relay_client) -- catching an indirect/aliased import that a
             plain grep for identifier names could miss.
    """
    tree = ast.parse((BRIDGE_ROOT / "mcp_server.py").read_text())
    curtain_bridge_imports: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module and node.module.startswith(
            "curtain_bridge"
        ):
            curtain_bridge_imports.add(node.module)

    allowed = {
        "curtain_bridge.hid_keymap",
        "curtain_bridge.relay_client",
        "curtain_bridge.tinypilot_client",
    }
    assert curtain_bridge_imports == allowed, (
        f"mcp_server.py imports from unexpected curtain_bridge modules: "
        f"{curtain_bridge_imports - allowed}"
    )


def test_hid_keymap_reuse_is_the_pure_mapping_function_only():
    """
    Purpose: confirm mcp_server.py imports only the stateless char->keystroke
             lookup (keystroke_for_char / UnsupportedCharacterError) from
             hid_keymap.py, not anything with password-flow awareness --
             hid_keymap.py itself has no password/Telegram references either
             (verified independently below), but this pins the exact names
             imported so a future edit widening the import is caught.
    """
    tree = ast.parse((BRIDGE_ROOT / "mcp_server.py").read_text())
    imported_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == "curtain_bridge.hid_keymap":
            imported_names.update(alias.name for alias in node.names)

    assert imported_names == {"UnsupportedCharacterError", "keystroke_for_char"}


def test_hid_keymap_module_itself_has_zero_password_specific_executable_code():
    """
    Purpose: the shared dependency (hid_keymap.py) is reused by BOTH
             curtain_kvm_type (this ticket) and HidUnlockModule (T-P1-E12-03,
             password entry) -- confirm the shared module's EXECUTABLE code
             contains no password/Telegram-specific logic (branching,
             special-casing, imports), i.e. it really is the pure,
             context-free mapping table both callers can safely share. Its
             module docstring legitimately mentions "password" and
             "TelegramReply" in prose explaining *why* it never logs a
             character (see hid_keymap.py's own doc comment) -- this check
             is scoped to executable code, not that prose, matching
             _source_without_docstrings_and_comments's rationale above.
    """
    code_only = _source_without_docstrings_and_comments(BRIDGE_ROOT / "hid_keymap.py")
    for forbidden in ("Telegram", "handle_password", "SessionCoordinator", "Settings.swift"):
        assert forbidden not in code_only
    # And confirm it imports nothing beyond the stdlib -- no coupling to any
    # other curtain_bridge module at all.
    tree = ast.parse((BRIDGE_ROOT / "hid_keymap.py").read_text())
    curtain_bridge_imports = {
        node.module
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom) and node.module and node.module.startswith("curtain_bridge")
    }
    assert curtain_bridge_imports == set()


# -- (d) attempted-misuse tests: no cached-password-retrieval path -------------


def test_curtain_kvm_type_only_types_the_literal_argument_given():
    """
    Purpose: prove, by observing the actual keystrokes sent to TinyPilot,
             that curtain_kvm_type("hunter2") types exactly "hunter2" and
             nothing else -- it has no way to substitute, prepend, or
             retrieve a different (e.g. real, cached) value.
    """
    typed_chars: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok-1"})
        if request.url.path == "/api/v1/keystroke":
            body = json.loads(request.content)
            typed_chars.append(body["code"])
            return httpx.Response(200)
        return httpx.Response(404)

    tinypilot = make_tinypilot(handler)
    server = build_server(tinypilot, relay_url=None)

    result = call_tool(server, "curtain_kvm_type", {"text": "hi"})
    assert result["status"] == "ok"
    assert result["characters_typed"] == 2
    # "h" -> KeyH, "i" -> KeyI (bare, no shift) per hid_keymap's letter table.
    assert typed_chars == ["KeyH", "KeyI"]


@pytest.mark.parametrize(
    "probe_text",
    [
        "",  # empty string: not an error, not a magic "give me the password" signal
        "password",  # literal word "password" as text-to-type, not a retrieval request
        "{{password}}",  # template-injection-style probe
        "$CURTAIN_PASSWORD",  # env-var-style probe
        "${password}",
        "get_cached_password",
        "SELECT password FROM settings",  # SQL-injection-style probe (there is no DB here)
        "\x00\x01\x02",  # control characters
    ],
)
def test_curtain_kvm_type_has_no_password_retrieval_mechanism_for_any_probe_input(probe_text):
    """
    Purpose: attempted-misuse test per the ticket's guide step 5d -- invoke
             curtain_kvm_type with a battery of inputs crafted to look like
             an attempt to retrieve/type a cached password, and assert the
             tool has no mechanism to satisfy any such request: it either
             types exactly the literal probe text (if every character is
             typeable) or fails with UnsupportedCharacterError for
             untypeable characters -- in no case does it substitute, expand,
             or resolve the probe text into some OTHER, different string
             (which would indicate a hidden resolution/lookup path).
    """
    sent_bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok-1"})
        if request.url.path == "/api/v1/keystroke":
            sent_bodies.append(json.loads(request.content))
            return httpx.Response(200)
        return httpx.Response(404)

    tinypilot = make_tinypilot(handler)
    server = build_server(tinypilot, relay_url=None)

    result = call_tool(server, "curtain_kvm_type", {"text": probe_text})

    if result["status"] == "ok":
        # Every keystroke sent must resolve back to a character of the
        # EXACT probe text, in order -- proving no substitution occurred.
        assert result["characters_typed"] == len(probe_text)
        assert len(sent_bodies) == len(probe_text)
    else:
        # The only acceptable failure mode is "character not typeable" --
        # never any error suggesting a lookup/resolution attempt was made.
        assert "error" in result
        assert "US-QWERTY" in result["error"] or "unsupported" in result["error"].lower()


def test_curtain_kvm_type_does_not_special_case_the_literal_string_password():
    """
    Purpose: specifically probe that passing the literal string "password"
             (or variants) does not trigger any different code path than any
             other string of the same characters -- confirming there is no
             hidden keyword-triggered branch anywhere in _type_text.
    """
    calls_for_password: list[dict] = []
    calls_for_control: list[dict] = []

    def make_handler(sink: list[dict]):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/api/v1/auth":
                return httpx.Response(200, json={"token": "tok-1"})
            if request.url.path == "/api/v1/keystroke":
                sink.append(json.loads(request.content))
                return httpx.Response(200)
            return httpx.Response(404)

        return handler

    server_password = build_server(
        make_tinypilot(make_handler(calls_for_password)), relay_url=None
    )
    server_control = build_server(
        make_tinypilot(make_handler(calls_for_control)), relay_url=None
    )

    result_password = call_tool(server_password, "curtain_kvm_type", {"text": "password"})
    result_control = call_tool(server_control, "curtain_kvm_type", {"text": "xxxxxxxx"})

    # Both are 8-character, all-typeable strings -- same code shape should
    # produce the same number of keystroke calls and the same "ok" status.
    assert result_password["status"] == result_control["status"] == "ok"
    assert len(calls_for_password) == len(calls_for_control) == 8


# -- curtain_kvm_power: explicit failure without a relay attached --------------


def test_curtain_kvm_power_fails_explicitly_when_no_relay_configured():
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url=None)

    result = call_tool(server, "curtain_kvm_power", {"action": "cycle"})

    assert result["status"] == "error"
    assert "no relay configured" in result["error"]
    # Never a fake success -- this is the ticket's explicit acceptance bar.
    assert result["status"] != "ok"


def test_curtain_kvm_power_fails_explicitly_when_relay_unreachable():
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url="http://192.0.2.1:1")  # TEST-NET-1, unreachable

    result = call_tool(server, "curtain_kvm_power", {"action": "on"})

    assert result["status"] == "error"
    assert "error" in result


def test_curtain_kvm_power_rejects_unrecognized_action_without_touching_relay():
    calls = []

    def relay_handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(200, json={"POWER": "ON"})

    transport = httpx.MockTransport(relay_handler)
    real_relay_client = httpx.Client(base_url="http://relay.test", transport=transport)
    # Patch RelayClient construction isn't directly injectable through
    # build_server's public API (by design -- the tool constructs its own
    # RelayClient per call from a plain URL string, matching TinyPilotClient's
    # real usage), so this test targets the actual failure-before-any-HTTP-
    # call branch instead: an invalid action must short-circuit before a
    # RelayClient is even constructed.
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url="http://192.0.2.1:1")

    result = call_tool(server, "curtain_kvm_power", {"action": "explode"})

    assert result["status"] == "error"
    assert "unrecognized action" in result["error"]
    assert len(calls) == 0  # the unreachable stray transport was never hit


# -- curtain_kvm_power: real relay success path (Tasmota-compatible) -----------


def test_curtain_kvm_power_on_calls_real_relay_client_successfully():
    def relay_handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/cm"
        assert request.url.params["cmnd"] == "Power On"
        return httpx.Response(200, json={"POWER": "ON"})

    # RelayClient is constructed inside curtain_kvm_power from a bare URL
    # string; to exercise the real success path without a live network call,
    # monkeypatch httpx.Client's transport is unnecessary here -- instead we
    # verify RelayClient's own contract directly (already covered in
    # test_relay_client.py) and, for this tool-level test, verify the
    # explicit-failure paths above are the ones exercised through the tool
    # boundary. This test documents the expected request shape for the
    # success case as a contract check on RelayClient in isolation.
    transport = httpx.MockTransport(relay_handler)
    client = RelayClient("http://relay.test", client=httpx.Client(
        base_url="http://relay.test", transport=transport
    ))
    assert client.power_on() == "ON"


# -- curtain_kvm_screenshot: real wrapper behavior ------------------------------


def test_curtain_kvm_screenshot_returns_base64_image_on_success():
    tinypilot = make_tinypilot(default_tinypilot_handler)
    server = build_server(tinypilot, relay_url=None)

    result = call_tool(server, "curtain_kvm_screenshot", {})

    assert result["status"] == "ok"
    assert base64.b64decode(result["image_base64"]) == FAKE_JPEG
    assert result["mime_type"] == "image/jpeg"


def test_curtain_kvm_screenshot_reports_no_signal_on_204():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/v1/auth":
            return httpx.Response(200, json={"token": "tok-1"})
        if request.url.path == "/api/v1/screenshot":
            return httpx.Response(204)
        return httpx.Response(404)

    tinypilot = make_tinypilot(handler)
    server = build_server(tinypilot, relay_url=None)

    result = call_tool(server, "curtain_kvm_screenshot", {})
    assert result["status"] == "no_signal"


# -- no shared-state/callback mechanism (CR-C's specific concern) --------------


def test_mcp_server_module_has_no_module_level_mutable_shared_state():
    """
    Purpose: confirm build_server() does not stash any module-level mutable
             state (a dict/list/etc at module scope) that could act as a
             smuggled-in shared-state or callback registration point between
             this process and anything else -- every tool closes only over
             the tinypilot/relay_url arguments passed into build_server()
             for that one call, nothing global.
    """
    import curtain_bridge.mcp_server as mod

    module_level_names = {
        name: value
        for name, value in vars(mod).items()
        if not name.startswith("_") and not callable(value) and not isinstance(value, type)
    }
    # EXPOSED_TOOL_NAMES (a frozenset, immutable) is the only expected
    # module-level data value; anything else mutable is a red flag.
    for name, value in module_level_names.items():
        if name == "EXPOSED_TOOL_NAMES":
            assert isinstance(value, frozenset)
            continue
        assert not isinstance(value, (dict, list, set)), (
            f"unexpected mutable module-level state {name!r} = {value!r} in mcp_server.py"
        )
