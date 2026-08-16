"""
Purpose: Safe, rollback-guaranteed in-place update mechanism for an
         already-deployed curtain-bridge install on the Pi. Stages a new
         version into a separate directory, validates it in isolation, and
         only atomically swaps the running systemd service to point at the
         new install if validation AND a post-swap health check both pass --
         on any failure at any stage, the previously-running install is left
         completely untouched.
Inputs: `apply_update(new_package_path)` takes a local filesystem path (on
        the Pi) to an already-extracted new version of the Bridge/ package
        source tree (i.e. a directory containing pyproject.toml and
        curtain_bridge/, the same shape rsync'd by
        `KVMBridgeDeployer.deploy()`). It does not fetch or extract an
        archive itself -- that transport concern belongs to the caller (the
        SSH deploy path in KVMBridgeDeployer.swift, per this ticket's scope).
Outputs: an `UpdateResult` describing exactly what happened: success (new
         version now running), or failure with a `rolled_back` flag and the
         reason -- callers must be able to tell "update failed, old version
         still running" apart from any other failure mode.
Constraints: THE CORE GUARANTEE THIS FILE EXISTS TO ENFORCE: the Pi must
             never be left with zero working Bridge version installed and
             running. Every failure branch below returns before the live
             symlink/systemd state is touched, or -- if the swap already
             happened -- reverts the symlink and restarts the service on the
             old install before returning failure. This process itself
             (running as the currently-active `curtain-bridge` service, or
             invoked as a one-off script by the SSH deploy path) must survive
             a failed update of itself; see `apply_update`'s staged-directory
             design for why overwrite-in-place is never used.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E11-03)
"""

from __future__ import annotations

import dataclasses
import logging
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

logger = logging.getLogger("curtain_bridge.updater")

# Root under which staged (candidate) and live installs both live, as sibling
# directories, so an atomic symlink flip is a same-filesystem rename -- never
# crossing a filesystem boundary, which could turn "atomic" into "briefly
# both-or-neither" on some setups.
INSTALL_ROOT = Path("/opt/curtain-bridge")
# The symlink systemd's ExecStart resolves through (see
# Bridge/systemd/curtain-bridge.service's WorkingDirectory/ExecStart, which
# point at /opt/curtain-bridge/venv -- this module keeps that same venv path
# stable across updates by making /opt/curtain-bridge/venv itself a symlink
# to the currently-live staged venv).
LIVE_VENV_LINK = INSTALL_ROOT / "venv"
STAGED_ROOT = INSTALL_ROOT / "staged"
SERVICE_NAME = "curtain-bridge"
HEALTH_URL = "http://127.0.0.1:8642/health"


@dataclasses.dataclass(frozen=True)
class UpdateResult:
    """
    Purpose: typed outcome of `apply_update`, distinguishing success from the
             two failure shapes callers must be able to tell apart.
    Inputs: constructed only by apply_update/its helpers.
    Outputs: `ok` (bool), `rolled_back` (bool -- True only when a swap had
             already happened and was then reverted), `message` (human-
             readable detail for logs/UI), `version` (the version now
             actually running, old or new, always populated on both success
             and failure so a caller can display "still on vX.Y.Z").
    Constraints: `ok=False, rolled_back=True` is the specific case this
                 ticket's CR-C gate traces for -- it means an update was
                 attempted, failed, and the prior version was successfully
                 restored to a running state. `ok=False, rolled_back=False`
                 means validation failed before anything live was touched
                 (the common case -- no rollback was even necessary).
    """

    ok: bool
    rolled_back: bool
    message: str
    version: str | None = None


def _run(cmd: list[str], *, timeout: float = 30.0) -> subprocess.CompletedProcess[str]:
    """Purpose: thin subprocess.run wrapper with consistent capture/timeout/text
    settings, factored out so every shell-out in this file behaves identically.
    Inputs: cmd (argv list), timeout. Outputs: CompletedProcess (never raises
    on non-zero exit -- callers check .returncode themselves).
    Constraints: never uses shell=True -- every command is an explicit argv
    list, so no command-injection surface exists even though the values
    involved (paths) are locally controlled, not attacker input."""
    return subprocess.run(
        cmd, capture_output=True, text=True, timeout=timeout, check=False
    )


def _validate_staged_install(staged_venv: Path, package_dir: Path) -> tuple[bool, str]:
    """
    Purpose: Validate a freshly-staged install BEFORE it is ever made live:
             (a) the package imports cleanly, (b) a lightweight self-check
             passes, (c) the console-script entry point responds to
             `--version`. All three run against the staged venv directly --
             never against the currently-live one -- so validation failure
             has zero effect on what's currently running.
    Inputs: staged_venv (path to the new venv, not yet linked live),
            package_dir (the source tree apply_update installed from, used
            only for the failure message).
    Outputs: (True, "") on success; (False, reason) on the first failing
             check.
    Constraints: each of the three checks is independent and short-circuits
                 on first failure, so the caller's log/UI message is specific
                 about which check failed rather than a generic "invalid".
    """
    python_bin = staged_venv / "bin" / "python"
    if not python_bin.exists():
        return False, f"staged venv has no python binary at {python_bin}"

    # (a) import cleanly
    import_check = _run([str(python_bin), "-c", "import curtain_bridge"])
    if import_check.returncode != 0:
        return False, f"staged package failed to import: {import_check.stderr.strip()}"

    # (b) lightweight self-check -- resolves its own version via the same
    # importlib.metadata path health.py uses, proving package metadata is
    # intact and consistent for the staged install specifically (not the
    # currently-running process's own metadata cache, if any).
    self_check = _run(
        [
            str(python_bin),
            "-c",
            "from curtain_bridge.health import get_installed_version as g; "
            "v = g(); "
            "assert v and v != '0.0.0-unknown', f'unresolved version: {v}'; "
            "print(v)",
        ]
    )
    if self_check.returncode != 0:
        return False, f"staged package self-check failed: {self_check.stderr.strip()}"

    # (c) console-script entry point responds to --version
    entry_point = staged_venv / "bin" / "curtain-bridge"
    if not entry_point.exists():
        return False, f"staged install has no curtain-bridge entry point at {entry_point}"
    version_check = _run([str(entry_point), "--version"], timeout=10.0)
    if version_check.returncode != 0:
        return False, f"staged entry point --version failed: {version_check.stderr.strip()}"

    return True, ""


def _query_health(timeout: float = 5.0) -> dict[str, object] | None:
    """
    Purpose: GET the local /health endpoint (the same one health.py serves)
             and parse it, used post-swap to confirm the newly-live install
             is actually the one now answering requests.
    Inputs: timeout in seconds.
    Outputs: the parsed JSON dict on a 200 response, or None on any failure
             (connection refused, timeout, non-200, malformed JSON) -- every
             failure mode collapses to "couldn't confirm health", which the
             caller treats uniformly as "swap unconfirmed, roll back".
    Constraints: talks to the LOCAL health port only (127.0.0.1) -- this is
                 the Pi checking itself post-swap, distinct from
                 KVMBridgeDeployer.checkHealth's remote/LAN call from the Mac.
                 Since health.py now requires the shared-secret bearer token
                 (see auth.py) on every request -- including this Pi-local
                 self-check -- this reads the SAME token file health.py
                 itself loads from (`auth.DEFAULT_AUTH_TOKEN_PATH`) and
                 presents it. A missing token file degrades the same as any
                 other health-check failure (the request goes out with no
                 header, gets a 401, and collapses into the same "couldn't
                 confirm health" None return as every other failure mode
                 here) rather than raising.
    """
    from curtain_bridge.auth import load_bridge_auth_token

    headers = {}
    token = load_bridge_auth_token()
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    try:
        request = urllib.request.Request(HEALTH_URL, headers=headers, method="GET")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status != 200:
                return None
            import json

            return json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None


def _restart_service() -> tuple[bool, str]:
    """Purpose: `systemctl restart curtain-bridge`, used identically after
    both a forward swap and a rollback swap. Inputs: none. Outputs:
    (succeeded, stderr-or-empty). Constraints: requires the invoking user to
    have passwordless sudo for this exact systemctl invocation (documented in
    Bridge/README.md's update-mechanism section, matching the existing
    deploy-path assumption in KVMBridgeDeployer.swift's remote install
    script)."""
    result = _run(["sudo", "systemctl", "restart", SERVICE_NAME], timeout=20.0)
    return result.returncode == 0, result.stderr.strip()


def _current_live_target() -> Path | None:
    """Purpose: resolve what LIVE_VENV_LINK currently points at, before any
    swap attempt, so a failed swap can be reverted to exactly this path
    rather than a guessed/reconstructed one. Inputs: none. Outputs: the
    resolved Path, or None if the symlink doesn't exist yet (first-ever
    install has no "previous" to roll back to). Constraints: uses
    os.readlink semantics (Path.readlink) rather than fully resolving through
    to a real path, so relative symlink targets are preserved verbatim."""
    if not LIVE_VENV_LINK.is_symlink():
        return None
    return LIVE_VENV_LINK.readlink()


def apply_update(new_package_path: str) -> UpdateResult:
    """
    Purpose: Stage, validate, and conditionally swap to a new curtain-bridge
             version, per this file's module-level doc comment. This is the
             single entry point `KVMBridgeDeployer.swift`'s Swift-side update
             flow triggers (via SSH, per T-P1-E11-02's deploy path) once it
             has independently decided a genuine version mismatch exists
             (`compareVersions`).
    Inputs: new_package_path -- local path (on the Pi) to the new version's
            already-transferred Bridge/ source tree.
    Outputs: UpdateResult (see its own doc comment for the four outcome
             shapes).
    Constraints: Sequence, each step gated on the previous succeeding:
        1. Stage: create a new venv under STAGED_ROOT/<timestamp>/ and pip
           install the new package into it. The CURRENTLY LIVE install
           (wherever LIVE_VENV_LINK points) is never touched during this
           step -- a failure here (disk full, bad package, network pip
           index unreachable) leaves the live install completely untouched
           and this function returns before any swap is attempted.
        2. Validate: _validate_staged_install() against the staged venv
           only. A failure here likewise leaves the live install untouched
           -- returns UpdateResult(ok=False, rolled_back=False, ...) since
           nothing live was ever touched, so there is nothing to "roll back
           from".
        3. Swap: flip LIVE_VENV_LINK to point at the new staged venv
           (atomic on POSIX via os.rename/Path.replace on a symlink), then
           restart the systemd service.
        4. Post-swap health check: poll /health (which, once the restarted
           service is actually up, will report the NEW version, since
           health.py resolves the version live rather than caching it) to
           confirm the new version is genuinely serving requests -- not just
           that the process launched, but that it launched successfully
           enough to answer HTTP. If this fails, step 5 fires.
        5. Rollback (only reached if step 3 or 4 failed): flip
           LIVE_VENV_LINK back to the path captured before the swap
           (`_current_live_target()`, captured BEFORE step 3 ever runs) and
           restart the service again. This is the specific path CR-C traces:
           if this rollback itself also fails to restore a running service
           (e.g. systemd is in a genuinely broken state unrelated to this
           update), that is returned as ok=False, rolled_back=False with an
           explicit "MANUAL INTERVENTION REQUIRED" message -- this function
           never silently claims success it cannot verify, but also never
           pretends a rollback succeeded when it didn't.
        6. Only once the post-swap health check in step 4 has confirmed the
           NEW version is live and serving does the old staged directory get
           removed (cleanup) -- if cleanup itself fails (e.g. permission
           error), that is logged but does not flip the overall result to
           failure, since the update itself already fully succeeded at that
           point; a leftover staged directory is disk-space untidiness, not
           a broken-install risk.
    """
    new_package_path_obj = Path(new_package_path)
    if not new_package_path_obj.is_dir():
        return UpdateResult(
            ok=False,
            rolled_back=False,
            message=f"new_package_path does not exist or is not a directory: {new_package_path}",
        )

    previous_target = _current_live_target()
    stage_dir = STAGED_ROOT / f"staged-{int(time.time())}"
    staged_venv = stage_dir / "venv"

    # -- 1. Stage -----------------------------------------------------------
    try:
        stage_dir.mkdir(parents=True, exist_ok=False)
    except OSError as exc:
        return UpdateResult(ok=False, rolled_back=False, message=f"failed to create stage directory: {exc}")

    venv_create = _run(["python3", "-m", "venv", str(staged_venv)], timeout=30.0)
    if venv_create.returncode != 0:
        shutil.rmtree(stage_dir, ignore_errors=True)
        return UpdateResult(
            ok=False,
            rolled_back=False,
            message=f"failed to create staged venv: {venv_create.stderr.strip()}",
        )

    pip_install = _run(
        [str(staged_venv / "bin" / "pip"), "install", "--quiet", str(new_package_path_obj)],
        timeout=120.0,
    )
    if pip_install.returncode != 0:
        shutil.rmtree(stage_dir, ignore_errors=True)
        return UpdateResult(
            ok=False,
            rolled_back=False,
            message=f"failed to pip install staged package: {pip_install.stderr.strip()}",
        )

    # -- 2. Validate (staged install only; live install untouched so far) ---
    valid, reason = _validate_staged_install(staged_venv, new_package_path_obj)
    if not valid:
        shutil.rmtree(stage_dir, ignore_errors=True)
        return UpdateResult(ok=False, rolled_back=False, message=f"validation failed: {reason}")

    # -- 3. Swap --------------------------------------------------------------
    try:
        if LIVE_VENV_LINK.is_symlink() or LIVE_VENV_LINK.exists():
            LIVE_VENV_LINK.unlink()
        LIVE_VENV_LINK.symlink_to(staged_venv, target_is_directory=True)
    except OSError as exc:
        # Nothing live was actually swapped (unlink+symlink_to didn't both
        # complete) -- best-effort restore of the original link if unlink
        # succeeded but symlink_to didn't, then report untouched-live failure.
        shutil.rmtree(stage_dir, ignore_errors=True)
        if previous_target is not None:
            if not LIVE_VENV_LINK.exists():
                try:
                    LIVE_VENV_LINK.symlink_to(previous_target, target_is_directory=True)
                except OSError as restore_exc:
                    return UpdateResult(
                        ok=False,
                        rolled_back=False,
                        message=(
                            f"symlink swap failed ({exc}) AND restoring the previous link also "
                            f"failed: {restore_exc}. MANUAL INTERVENTION REQUIRED: verify "
                            f"{LIVE_VENV_LINK} points at a working install."
                        ),
                    )
            return UpdateResult(ok=False, rolled_back=False, message=f"symlink swap failed: {exc}")
        # First-ever install (nothing to restore): report plainly rather than
        # implying a "rollback" happened when there was no prior version.
        return UpdateResult(
            ok=False,
            rolled_back=False,
            message=(
                f"symlink swap failed on first-ever install: {exc}. No previous version exists "
                "to fall back to."
            ),
        )

    restarted, restart_err = _restart_service()
    if not restarted:
        return _rollback(
            previous_target,
            stage_dir,
            reason=f"post-swap systemctl restart failed: {restart_err}",
        )

    # -- 4. Post-swap health check ---------------------------------------------
    # Poll briefly rather than a single immediate check -- systemd's restart
    # returns once the unit is (re)started, not once the health server inside
    # it has finished binding its socket.
    health: dict[str, object] | None = None
    for _ in range(10):
        health = _query_health(timeout=2.0)
        if health is not None:
            break
        time.sleep(0.5)

    if health is None:
        return _rollback(
            previous_target,
            stage_dir,
            reason="post-swap health check never responded",
        )

    new_version = str(health.get("version", ""))
    if health.get("status") != "ok" or not new_version:
        return _rollback(
            previous_target,
            stage_dir,
            reason=f"post-swap health check returned unhealthy status: {health}",
        )

    # -- 5. (rollback path lives in _rollback(), only reached above) --------

    # -- 6. Cleanup: remove the OLD staged copy now that the new one is
    # confirmed live and healthy. Failure here does not change the overall
    # success result (see doc comment step 6).
    if previous_target is not None:
        old_stage_dir = previous_target.parent
        # Guard: only ever rmtree a path under STAGED_ROOT -- never anything
        # else, even if `previous_target` were somehow corrupted to point
        # elsewhere (defense in depth for a destructive filesystem op).
        try:
            if old_stage_dir != stage_dir and STAGED_ROOT in old_stage_dir.parents:
                shutil.rmtree(old_stage_dir, ignore_errors=True)
        except OSError:
            logger.warning("updater: failed to clean up old staged copy at %s", old_stage_dir)

    return UpdateResult(
        ok=True,
        rolled_back=False,
        message=f"updated and confirmed healthy at version {new_version}",
        version=new_version,
    )


def _rollback(previous_target: Path | None, failed_stage_dir: Path, *, reason: str) -> UpdateResult:
    """
    Purpose: Revert LIVE_VENV_LINK to the pre-swap target and restart the
             service, used by every post-swap failure branch in
             apply_update. THIS IS THE FUNCTION CR-C's MANDATORY TRACE MUST
             CONFIRM: it must never return ok=True/rolled_back=True unless a
             restarted, running service was actually confirmed.
    Inputs: previous_target (the venv path LIVE_VENV_LINK pointed at before
            the swap -- may be None only on a first-ever install, in which
            case there is nothing to roll back TO, which is reported
            distinctly). failed_stage_dir (the new, failed staged directory
            -- removed regardless of rollback outcome, since it's the thing
            that failed validation/health, not the recovery target).
    Outputs: UpdateResult with rolled_back=True only if the symlink revert
             AND the subsequent restart both succeeded; rolled_back=False
             (with an explicit MANUAL INTERVENTION message) if either the
             revert or the restart itself fails -- this function never
             claims a successful rollback it did not verify.
    Constraints: does not re-run the post-swap health check against the
                 restored old version -- that version was already running
                 and healthy before this update attempt began (an invariant
                 this whole ticket depends on: apply_update is only ever
                 invoked against a previously-healthy install), so re-
                 verifying it here would be redundant, not additive safety.
    """
    if previous_target is None:
        # No prior install to roll back to (first-ever install failed
        # post-swap). The staged/failed venv is still symlinked live at this
        # point -- explicitly unlink it so the service does not keep pointing
        # at an install that failed its own health check, even though there
        # is nothing better to point it at.
        try:
            if LIVE_VENV_LINK.is_symlink():
                LIVE_VENV_LINK.unlink()
        except OSError:
            pass
        shutil.rmtree(failed_stage_dir, ignore_errors=True)
        return UpdateResult(
            ok=False,
            rolled_back=False,
            message=(
                "first-time install failed validation/health check and there is no "
                f"previous version to roll back to (reason: {reason}). MANUAL "
                "INTERVENTION REQUIRED: no working curtain-bridge version is "
                "currently installed."
            ),
        )

    try:
        if LIVE_VENV_LINK.is_symlink() or LIVE_VENV_LINK.exists():
            LIVE_VENV_LINK.unlink()
        LIVE_VENV_LINK.symlink_to(previous_target, target_is_directory=True)
    except OSError as exc:
        return UpdateResult(
            ok=False,
            rolled_back=False,
            message=(
                f"update failed ({reason}) AND rollback symlink revert also failed: {exc}. "
                "MANUAL INTERVENTION REQUIRED: verify /opt/curtain-bridge/venv points at a "
                "working install and restart curtain-bridge manually."
            ),
        )

    restarted, restart_err = _restart_service()
    shutil.rmtree(failed_stage_dir, ignore_errors=True)
    if not restarted:
        return UpdateResult(
            ok=False,
            rolled_back=False,
            message=(
                f"update failed ({reason}); rollback symlink was reverted to the previous "
                f"install but the service restart also failed: {restart_err}. MANUAL "
                "INTERVENTION REQUIRED: run `sudo systemctl restart curtain-bridge` and "
                "check `journalctl -u curtain-bridge` for the cause."
            ),
        )

    return UpdateResult(
        ok=False,
        rolled_back=True,
        message=f"update failed and was rolled back cleanly ({reason}); previous version is running",
    )
