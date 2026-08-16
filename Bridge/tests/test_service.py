"""
Purpose: Tests for curtain_bridge.service's daemon skeleton -- config loading,
         module registration, and startup/idle/shutdown lifecycle. No real
         TinyPilot or network calls are made anywhere in this file.
Inputs: none (self-contained fixtures per test; temp config files via
        pytest's tmp_path).
Outputs: pytest test functions.
Constraints: exercises the skeleton exactly as E-12/E-13 will use it (register
             modules, then run), without adding real module implementations.
SPORT: MASTER-APPS (Bridge/ deployment artifact)
"""

from __future__ import annotations

import asyncio
import json

import pytest

from curtain_bridge.service import BridgeConfig, BridgeService


# -- BridgeConfig ---------------------------------------------------------------


def test_bridge_config_load_minimal(tmp_path):
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps({"tinypilot_host": "tinypilot.local"}))

    config = BridgeConfig.load(config_path)

    assert config.tinypilot_host == "tinypilot.local"
    assert config.tinypilot_port == 80
    assert config.token_cache_path == "/var/lib/curtain-bridge/token"
    assert config.extra == {}


def test_bridge_config_load_full_and_extra_keys_preserved(tmp_path):
    config_path = tmp_path / "config.json"
    config_path.write_text(
        json.dumps(
            {
                "tinypilot_host": "192.168.1.50",
                "tinypilot_port": 8080,
                "token_cache_path": "/tmp/token",
                "telegram_bot_token": "future-e12-key",
            }
        )
    )

    config = BridgeConfig.load(config_path)

    assert config.tinypilot_host == "192.168.1.50"
    assert config.tinypilot_port == 8080
    assert config.token_cache_path == "/tmp/token"
    assert config.extra == {"telegram_bot_token": "future-e12-key"}


def test_bridge_config_load_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        BridgeConfig.load(tmp_path / "does-not-exist.json")


def test_bridge_config_load_missing_required_key_raises(tmp_path):
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps({"tinypilot_port": 80}))
    with pytest.raises(KeyError):
        BridgeConfig.load(config_path)


# -- BridgeService: zero modules (this ticket's acceptance bar) -----------------


@pytest.mark.asyncio
async def test_service_runs_standalone_with_zero_modules():
    config = BridgeConfig(tinypilot_host="tinypilot.local")
    service = BridgeService(config)

    run_task = asyncio.create_task(service.run())
    await asyncio.sleep(0.05)
    assert not run_task.done()  # still idling

    service.request_stop()
    await asyncio.wait_for(run_task, timeout=1.0)
    assert run_task.done()


# -- BridgeService: module registration + lifecycle ------------------------------


class _RecordingModule:
    def __init__(self, name: str, fail_start: bool = False) -> None:
        self.name = name
        self.fail_start = fail_start
        self.started_with: BridgeConfig | None = None
        self.stopped = False

    async def start(self, config: BridgeConfig) -> None:
        if self.fail_start:
            raise RuntimeError(f"{self.name} intentionally failed to start")
        self.started_with = config

    async def stop(self) -> None:
        self.stopped = True


@pytest.mark.asyncio
async def test_service_starts_and_stops_registered_modules_in_order():
    config = BridgeConfig(tinypilot_host="tinypilot.local")
    service = BridgeService(config)
    mod_a = _RecordingModule("a")
    mod_b = _RecordingModule("b")
    service.register(mod_a)
    service.register(mod_b)

    run_task = asyncio.create_task(service.run())
    await asyncio.sleep(0.05)

    assert mod_a.started_with is config
    assert mod_b.started_with is config
    assert not mod_a.stopped
    assert not mod_b.stopped

    service.request_stop()
    await asyncio.wait_for(run_task, timeout=1.0)

    assert mod_a.stopped
    assert mod_b.stopped


@pytest.mark.asyncio
async def test_service_start_failure_rolls_back_already_started_modules():
    config = BridgeConfig(tinypilot_host="tinypilot.local")
    service = BridgeService(config)
    mod_a = _RecordingModule("a")
    mod_b_fails = _RecordingModule("b", fail_start=True)
    service.register(mod_a)
    service.register(mod_b_fails)

    with pytest.raises(RuntimeError):
        await service.start_all()

    assert mod_a.started_with is config
    assert mod_a.stopped  # rolled back
