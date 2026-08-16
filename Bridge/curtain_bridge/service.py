"""
Purpose: Minimal long-running daemon skeleton that hosts the T-P1-E11-03
         health/version endpoint plus E-12's Telegram-login-after-reboot logic
         and E-13's video-monitoring logic, all as registered modules.
Inputs: a config file path (JSON) passed via CLI arg or the
        CURTAIN_BRIDGE_CONFIG env var, containing at minimum the TinyPilot
        target's host/port and a token-cache location.
Outputs: a running asyncio event loop that starts every registered module,
         idles, and stops them cleanly on SIGTERM/SIGINT/KeyboardInterrupt.
Constraints: this process must run entirely on the Pi's own power/network
             path, independent of the protected Mac -- it is a distinct
             deployment artifact from Curtain.app, not something invoked by or
             bundled into it. Zero real network calls happen from this file
             directly; that lives in tinypilot_client.py, health.py, and
             future module implementations.
SPORT: MASTER-APPS (Bridge/ deployment artifact)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from curtain_bridge.health import HealthModule
from curtain_bridge.health import get_installed_version as _installed_version

logger = logging.getLogger("curtain_bridge.service")


@dataclass(frozen=True)
class BridgeConfig:
    """
    Purpose: Typed representation of the Bridge's config file.
    Inputs: parsed from JSON via BridgeConfig.load().
    Outputs: immutable config values consumed by the service and, later, by
             registered modules.
    Constraints: only fields needed by this skeleton are defined now
                 (tinypilot_host/tinypilot_port/token_cache_path); E-12/E-13
                 modules will read their own keys out of `extra` rather than
                 requiring changes to this dataclass.
    """

    tinypilot_host: str
    tinypilot_port: int = 80
    token_cache_path: str = "/var/lib/curtain-bridge/token"
    extra: dict[str, object] = field(default_factory=dict)

    @staticmethod
    def load(path: str | Path) -> "BridgeConfig":
        """
        Purpose: read and validate a JSON config file into a BridgeConfig.
        Inputs: path (str or Path) to a JSON file.
        Outputs: a BridgeConfig instance.
        Constraints: raises FileNotFoundError if the path doesn't exist, and
                     KeyError if the required "tinypilot_host" key is missing --
                     both are intentionally left uncaught here so startup fails
                     loudly rather than running with a broken config.
        """
        raw = json.loads(Path(path).read_text())
        known = {"tinypilot_host", "tinypilot_port", "token_cache_path"}
        return BridgeConfig(
            tinypilot_host=raw["tinypilot_host"],
            tinypilot_port=raw.get("tinypilot_port", 80),
            token_cache_path=raw.get("token_cache_path", "/var/lib/curtain-bridge/token"),
            extra={k: v for k, v in raw.items() if k not in known},
        )


class BridgeModule(Protocol):
    """
    Purpose: The registration contract E-12 (Telegram login-after-reboot) and
             E-13 (video-monitoring) implement to plug into BridgeService
             without modifying this file.
    Inputs: N/A (protocol definition).
    Outputs: N/A (protocol definition).
    Constraints: start()/stop() must both be coroutines; start() should return
                 once the module has finished its own setup (it may still run
                 background tasks it spawned itself), and stop() must be safe
                 to call even if start() failed partway through.
    """

    name: str

    async def start(self, config: BridgeConfig) -> None: ...

    async def stop(self) -> None: ...


class BridgeService:
    """
    Purpose: Owns the registered-module list, config, and asyncio lifecycle
             for the curtain-bridge daemon.
    Inputs: a BridgeConfig at construction.
    Outputs: run() blocks until stopped (signal or programmatic stop()).
    Constraints: modules are started in registration order and stopped in
                 reverse order; a module raising during start() aborts startup
                 and stops any modules already started, so the process never
                 idles in a half-initialized state.
    """

    def __init__(self, config: BridgeConfig) -> None:
        self.config = config
        self._modules: list[BridgeModule] = []
        self._started_modules: list[BridgeModule] = []
        self._stop_event = asyncio.Event()

    def register(self, module: BridgeModule) -> None:
        """
        Purpose: add a module to be started when the service runs. This is the
                 documented extension point E-12/E-13 use.
        Inputs: module (any object satisfying the BridgeModule protocol).
        Outputs: none (mutates internal registration list).
        Constraints: must be called before run()/start_all(); registering
                     after startup has no effect on the current run.
        """
        logger.info("service: registered module %s", module.name)
        self._modules.append(module)

    async def start_all(self) -> None:
        """Purpose: start every registered module in order. Inputs/Outputs: none.
        Constraints: on failure, stops already-started modules before re-raising."""
        for module in self._modules:
            try:
                logger.info("service: starting module %s", module.name)
                await module.start(self.config)
                self._started_modules.append(module)
            except Exception:
                logger.exception("service: module %s failed to start, rolling back", module.name)
                await self.stop_all()
                raise

    async def stop_all(self) -> None:
        """Purpose: stop every started module in reverse-start order. Inputs/Outputs: none.
        Constraints: continues stopping remaining modules even if one raises,
        logging each failure, so a single bad module can't block shutdown."""
        for module in reversed(self._started_modules):
            try:
                logger.info("service: stopping module %s", module.name)
                await module.stop()
            except Exception:
                logger.exception("service: module %s failed to stop cleanly", module.name)
        self._started_modules.clear()

    def request_stop(self) -> None:
        """Purpose: signal run() to exit its idle loop. Inputs/Outputs: none."""
        self._stop_event.set()

    async def run(self) -> None:
        """
        Purpose: start all modules, idle until stopped, then stop all modules.
        Inputs: none.
        Outputs: returns once shutdown is complete.
        Constraints: with zero registered modules this starts nothing, idles
                     until stopped, and stops nothing -- i.e. it runs cleanly
                     standalone, which is this ticket's acceptance bar (E-12/
                     E-13 modules are registered by later tickets, not here).
        """
        logger.info("service: starting with %d registered module(s)", len(self._modules))
        await self.start_all()
        try:
            await self._stop_event.wait()
        finally:
            await self.stop_all()
        logger.info("service: stopped")


def configure_logging() -> None:
    """Purpose: structured logging setup for the daemon. Inputs/Outputs: none.
    Constraints: writes to stdout so systemd's journal captures it directly
    (no separate log-file management needed on the Pi)."""
    logging.basicConfig(
        level=os.environ.get("CURTAIN_BRIDGE_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )


def _install_signal_handlers(service: BridgeService, loop: asyncio.AbstractEventLoop) -> None:
    """Purpose: wire SIGTERM/SIGINT to a graceful BridgeService.request_stop().
    Inputs: service, the running event loop. Outputs: none.
    Constraints: uses loop.add_signal_handler, which is POSIX-only -- correct
    for this Raspberry Pi OS deployment target, not intended for Windows."""
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, service.request_stop)


async def _async_main(config_path: str) -> None:
    config = BridgeConfig.load(config_path)
    service = BridgeService(config)
    service.register(HealthModule())
    # E-12/E-13 register their modules here in later tickets, e.g.:
    #   service.register(TelegramLoginModule(...))
    #   service.register(VideoMonitorModule(...))
    # T-P1-E12-03 (HID password typing, LOGGED_IN_DESKTOP detection, re-lock,
    # failure timeout -- see hid_typing.py's module doc comment): HidUnlockModule
    # is wired as TelegramLoginModule's on_password callback directly (not as a
    # second detection-callback consumer) since it needs a synchronous "type
    # then poll" flow, not another push-based subscriber -- a LatestStateTracker
    # sits alongside VideoMonitorModule's on_detection to give it a cheap,
    # non-blocking read of the latest classified frame:
    #   state_tracker = LatestStateTracker()
    #   video_monitor = VideoMonitorModule(tinypilot_client, state_tracker.record)  # type: ignore[arg-type]
    #   hid_unlock = HidUnlockModule(tinypilot_client, telegram_client, chat_id=..., detection_poller=state_tracker)
    #   telegram_login = TelegramLoginModule(telegram_client, hid_unlock.handle_password, chat_id=...)
    #   service.register(video_monitor)
    #   service.register(hid_unlock)
    #   service.register(telegram_login)
    # T-P1-E12-04 (Mac-side crash-cause reporting, relay-through-Bridge
    # decision -- see crash_relay.py's doc comment): once TelegramLoginModule
    # is wired above, register its relay counterpart alongside it, sharing
    # the SAME TelegramClient instance and reading the login module's live
    # pinned chat_id -- no second credential store, no second chat_id source:
    #   telegram_login = TelegramLoginModule(telegram_client, on_password, chat_id=...)
    #   service.register(telegram_login)
    #   service.register(CrashRelayModule(telegram_client, lambda: telegram_login._chat_id))
    loop = asyncio.get_running_loop()
    _install_signal_handlers(service, loop)
    await service.run()


def main() -> None:
    """
    Purpose: console-script entry point (`curtain-bridge`), invoked by the
             systemd unit's ExecStart, and also by
             `KVMBridgeDeployer.checkForUpdate` (Swift side, over SSH) and
             `updater.py`'s `_validate_staged_install` (local, against a
             staged install) as a lightweight "does this install actually
             work" probe via `--version`.
    Inputs: --config CLI flag, falling back to the CURTAIN_BRIDGE_CONFIG env
            var if omitted; --version, which prints the installed package
            version (resolved live via the same importlib.metadata path
            health.py uses, never hardcoded) and exits immediately without
            requiring a config file.
    Outputs: process exit code 0 on clean shutdown or after --version, 1 if
             no config was supplied by either means.
    Constraints: --version must work even when no config file exists yet
                 (e.g. a freshly-staged, not-yet-configured install being
                 validated by updater.py) -- it is handled by argparse's
                 built-in `action="version"` before the --config check runs.
    """
    configure_logging()
    parser = argparse.ArgumentParser(prog="curtain-bridge")
    parser.add_argument("--config", default=os.environ.get("CURTAIN_BRIDGE_CONFIG"))
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {_installed_version()}",
    )
    args = parser.parse_args()
    if not args.config:
        logger.error(
            "no config path supplied (use --config or CURTAIN_BRIDGE_CONFIG env var)"
        )
        sys.exit(1)
    asyncio.run(_async_main(args.config))


if __name__ == "__main__":
    main()
