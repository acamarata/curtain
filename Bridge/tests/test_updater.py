"""
Purpose: Tests for curtain_bridge.updater's apply_update -- the safety-
         critical mechanism this ticket exists to build. Exercises both the
         happy path (stage/validate/swap/confirm a genuinely new, valid
         version) and the failure/rollback path (a fixture package
         engineered to fail validation), confirming the ORIGINAL install is
         left running in both the validation-failure and post-swap-health-
         failure cases -- not just that a failure result is returned, but
         that the live symlink and a real `systemctl`-stand-in genuinely
         still point at/report the original version.
Inputs: none (each test builds its own throwaway INSTALL_ROOT under
        tmp_path, monkeypatching updater's module-level path constants and
        systemctl/health-check seams so no real systemd or real
        curtain-bridge install on the test host is touched).
Outputs: pytest test functions.
Constraints: `_run` (subprocess.run) and `_query_health` /
             `_restart_service` are monkeypatched via `monkeypatch.setattr`
             on the `curtain_bridge.updater` module rather than mocking
             `subprocess` globally, so real `python3 -m venv` + `pip install`
             DO run against real tmp_path directories -- this proves the
             actual staging/validation logic works against a real (tiny)
             installable package, not just against canned subprocess output.
             Only the systemd/service-restart and the /health HTTP call are
             stubbed, since those genuinely require a running systemd unit
             this test process does not have.
             The `_cheap_staged_venv` autouse fixture additionally strips the
             redundant re-download of heavy dependencies from those real staging
             runs (see its docstring) -- staging stays real, its disk cost does
             not. Run this suite from Bridge/.venv, which that fixture assumes.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E11-03)
"""

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from curtain_bridge import updater


@pytest.fixture(autouse=True)
def _cheap_staged_venv(monkeypatch):
    """
    Purpose: keep apply_update's staging step REAL while removing the disk cost
             that made this module flaky.
    Why: several tests below stage from this repo's own package root, so each
         apply_update call really pip-installs curtain_bridge's dependencies --
         opencv-python-headless and numpy, roughly 150MB of venv per call. This
         module calls apply_update nine times, into tmp dirs pytest retains across
         runs, so a few consecutive runs exhaust the disk. The failure that surfaces
         is a real `OSError: [Errno 28] No space left on device` raised by pip,
         which then fails whatever assertion the test was actually making. That is
         the true root cause of this suite's long-recorded flakiness; it was
         previously attributed to subprocess timing, but no timeout widening could
         fix it, and the ENOSPC error was observed directly.
    How: rewrite only the two heavy commands. `python3 -m venv` gains
         --system-site-packages so the staged venv inherits the already-installed
         heavy dependencies from the interpreter running the suite, and `pip install`
         gains --no-deps so it installs the package under test without re-resolving
         and re-downloading those dependencies.
    Constraints: this deliberately does NOT stub the staging step out. A real venv is
                 still created, a real pip install still runs, and
                 _validate_staged_install still genuinely imports the staged package,
                 resolves its metadata and invokes its --version entry point. Only the
                 redundant re-download of dependencies the test environment already has
                 is removed, so the logic under test is unchanged.
                 Assumes the suite runs inside Bridge/.venv (the documented way to run
                 it), since that is where the inherited dependencies come from.
    """
    real_run = updater._run

    def cheap_run(cmd, *args, **kwargs):
        if len(cmd) >= 3 and cmd[1] == "-m" and cmd[2] == "venv":
            cmd = [*cmd[:3], "--system-site-packages", *cmd[3:]]
        elif len(cmd) >= 2 and cmd[1] == "install":
            cmd = [*cmd[:2], "--no-deps", *cmd[2:]]
        return real_run(cmd, *args, **kwargs)

    monkeypatch.setattr(updater, "_run", cheap_run)


def _write_fixture_package(root: Path, *, version: str, valid: bool) -> Path:
    """
    Purpose: build a minimal, real, pip-installable fixture package on disk
             mimicking curtain_bridge's own shape closely enough that
             updater._validate_staged_install's three checks (import,
             self-check via curtain_bridge.health.get_installed_version,
             --version entry point) exercise real behavior.
    Inputs: root (tmp_path-scoped directory to build the fixture in),
            version (the fixture's own version string), valid (when False,
            the fixture's __init__ raises on import -- a real, unambiguous
            validation-failure trigger, distinct from a merely-different
            version).
    Outputs: path to the fixture package's project root (containing
             pyproject.toml), suitable as apply_update's new_package_path.
    Constraints: the "invalid" fixture fails specifically at import time
                 (not e.g. a missing entry point), matching the ticket's
                 instruction for "a fixture package engineered to fail
                 validation".
    """
    pkg_dir = root / "fixture_bridge"
    pkg_dir.mkdir(parents=True)
    src_dir = pkg_dir / "fixture_bridge_pkg"
    src_dir.mkdir()

    if valid:
        init_body = "def get_installed_version():\n    return __version__\n"
    else:
        init_body = "raise RuntimeError('intentionally broken fixture package for rollback test')\n"

    (src_dir / "__init__.py").write_text(
        f"__version__ = {version!r}\n{init_body}"
    )
    (src_dir / "health.py").write_text(
        # Mirrors curtain_bridge.health.get_installed_version's import path
        # shape closely enough for the self-check subprocess invocation used
        # against REAL curtain_bridge fixtures below (see
        # test_apply_update_happy_path, which installs the real package, not
        # this synthetic one -- this fixture path is only used for the
        # failure-path test, where import already fails before health.py
        # would ever be reached).
        f"def get_installed_version():\n    return {version!r}\n"
    )
    (pkg_dir / "pyproject.toml").write_text(
        textwrap.dedent(
            f"""
            [build-system]
            requires = ["hatchling"]
            build-backend = "hatchling.build"

            [project]
            name = "fixture-bridge"
            version = "{version}"
            requires-python = ">=3.11"

            [project.scripts]
            fixture-bridge = "fixture_bridge_pkg:get_installed_version"

            [tool.hatch.build.targets.wheel]
            packages = ["fixture_bridge_pkg"]
            """
        )
    )
    return pkg_dir


@pytest.fixture
def isolated_install_root(tmp_path, monkeypatch):
    """
    Purpose: point every updater module-level path constant at a throwaway
             tmp_path tree, so tests never touch a real /opt/curtain-bridge.
    Inputs: pytest's tmp_path/monkeypatch fixtures.
    Outputs: the throwaway install root Path.
    Constraints: also seeds an initial "previously installed, healthy"
                 version at LIVE_VENV_LINK by installing curtain_bridge
                 itself (the real package under test, already importable in
                 this test environment) into a real venv -- this is what
                 "the original install" means in every assertion below.
    """
    install_root = tmp_path / "curtain-bridge"
    staged_root = install_root / "staged"
    live_link = install_root / "venv"
    install_root.mkdir()
    staged_root.mkdir()

    monkeypatch.setattr(updater, "INSTALL_ROOT", install_root)
    monkeypatch.setattr(updater, "STAGED_ROOT", staged_root)
    monkeypatch.setattr(updater, "LIVE_VENV_LINK", live_link)

    # Seed the "previous" install: a real venv with curtain-bridge itself
    # installed (editable, from the repo checkout), representing the
    # genuinely-running prior version.
    import subprocess
    import sys

    repo_root = Path(__file__).resolve().parents[1]  # Bridge/
    prior_dir = staged_root / "staged-0000000000"
    prior_venv = prior_dir / "venv"
    subprocess.run([sys.executable, "-m", "venv", str(prior_venv)], check=True)
    subprocess.run(
        [str(prior_venv / "bin" / "pip"), "install", "--quiet", str(repo_root)],
        check=True,
    )
    live_link.symlink_to(prior_venv, target_is_directory=True)

    return install_root


def test_apply_update_happy_path_swaps_to_new_version(isolated_install_root, monkeypatch, tmp_path):
    """A genuinely new, valid curtain-bridge install (same real package,
    installed fresh into a new staged venv) stages, validates, swaps, and is
    confirmed via a stubbed-but-realistic post-swap health check."""
    restart_calls: list[None] = []

    def fake_restart() -> tuple[bool, str]:
        restart_calls.append(None)
        return True, ""

    def fake_query_health(timeout: float = 5.0) -> dict[str, object]:
        # Simulates the restarted service's health.py now resolving the
        # NEWLY-swapped venv's package metadata -- proven for real via
        # get_installed_version() run against the just-staged venv's python.
        import subprocess

        new_venv = updater.LIVE_VENV_LINK
        result = subprocess.run(
            [str(new_venv / "bin" / "python"), "-c",
             "from curtain_bridge.health import get_installed_version as g; print(g())"],
            capture_output=True, text=True, check=True,
        )
        return {"status": "ok", "version": result.stdout.strip(), "uptime_seconds": 0}

    monkeypatch.setattr(updater, "_restart_service", fake_restart)
    monkeypatch.setattr(updater, "_query_health", fake_query_health)

    repo_root = Path(__file__).resolve().parents[1]
    result = updater.apply_update(str(repo_root))

    assert result.ok is True
    assert result.rolled_back is False
    assert restart_calls  # service restart was actually invoked
    # The live symlink now points at a NEW staged directory, not the
    # original seeded one.
    assert updater.LIVE_VENV_LINK.resolve().parent.name != "staged-0000000000"
    assert updater.LIVE_VENV_LINK.is_symlink()
    assert (updater.LIVE_VENV_LINK / "bin" / "python").exists()


def test_apply_update_validation_failure_leaves_original_running(
    isolated_install_root, monkeypatch, tmp_path
):
    """The core rollback-safety guarantee, validation-failure flavor: a
    fixture package engineered to raise on import must fail
    _validate_staged_install BEFORE any live swap happens, so the original
    (seeded) install is left completely untouched -- confirmed by re-reading
    the live symlink's target and running --version-equivalent against it."""
    original_target = updater.LIVE_VENV_LINK.readlink()

    restart_calls: list[None] = []
    monkeypatch.setattr(
        updater, "_restart_service", lambda: (restart_calls.append(None), (True, ""))[1]
    )

    broken_fixture = _write_fixture_package(tmp_path, version="9.9.9", valid=False)
    result = updater.apply_update(str(broken_fixture))

    assert result.ok is False
    assert result.rolled_back is False  # nothing live was ever touched
    assert "validation failed" in result.message
    assert restart_calls == []  # restart was never even attempted

    # The live symlink still points at exactly the original seeded install.
    assert updater.LIVE_VENV_LINK.readlink() == original_target
    assert updater.LIVE_VENV_LINK.is_symlink()
    # And the original install is still genuinely importable/functional.
    import subprocess

    check = subprocess.run(
        [str(updater.LIVE_VENV_LINK / "bin" / "python"), "-c", "import curtain_bridge"],
        capture_output=True, text=True,
    )
    assert check.returncode == 0, "original install must still be intact and importable"


def test_apply_update_post_swap_health_failure_rolls_back(isolated_install_root, monkeypatch, tmp_path):
    """The core rollback-safety guarantee, post-swap-health-failure flavor: a
    NEW version that stages and validates cleanly (a real, valid package) but
    whose post-swap health check never responds -- simulating a version that
    imports fine standalone but fails to actually come up as a service. Must
    revert the symlink to the ORIGINAL install and restart it, reporting
    rolled_back=True, not silently leaving the swapped-but-broken version live."""
    original_target = updater.LIVE_VENV_LINK.readlink()

    restart_calls: list[str] = []

    def fake_restart() -> tuple[bool, str]:
        restart_calls.append("restart")
        return True, ""

    def fake_query_health_always_fails(timeout: float = 5.0) -> None:
        return None  # simulates the new version never coming up healthy

    monkeypatch.setattr(updater, "_restart_service", fake_restart)
    monkeypatch.setattr(updater, "_query_health", fake_query_health_always_fails)
    # Speed the test up: apply_update polls health with a 0.5s sleep between
    # up to 10 attempts (~5s) -- shrink that loop for the test without
    # weakening the assertion (it still exercises the full retry-then-give-up
    # path, just faster).
    monkeypatch.setattr(updater.time, "sleep", lambda _seconds: None)

    repo_root = Path(__file__).resolve().parents[1]
    result = updater.apply_update(str(repo_root))

    assert result.ok is False
    assert result.rolled_back is True
    assert "health check never responded" in result.message
    # Restart was called twice: once for the (failed) forward swap, once for
    # the rollback.
    assert restart_calls == ["restart", "restart"]

    # The live symlink is back to the ORIGINAL target, not the new one.
    assert updater.LIVE_VENV_LINK.readlink() == original_target
    import subprocess

    check = subprocess.run(
        [str(updater.LIVE_VENV_LINK / "bin" / "python"), "-c", "import curtain_bridge"],
        capture_output=True, text=True,
    )
    assert check.returncode == 0, "original install must be running again after rollback"


def test_apply_update_missing_source_path_fails_before_touching_anything(
    isolated_install_root,
):
    original_target = updater.LIVE_VENV_LINK.readlink()
    result = updater.apply_update("/nonexistent/path/does/not/exist")

    assert result.ok is False
    assert result.rolled_back is False
    assert updater.LIVE_VENV_LINK.readlink() == original_target


def test_apply_update_swap_failure_restores_previous_link(isolated_install_root, monkeypatch, tmp_path):
    """CR-C-flagged gap: if the symlink swap itself raises OSError (unlink
    succeeded, symlink_to failed), the previous link must be restored so the
    Pi is not left with a dangling/missing venv symlink."""
    original_target = updater.LIVE_VENV_LINK.readlink()

    real_symlink_to = Path.symlink_to
    call_count = {"n": 0}

    def flaky_symlink_to(self, target, **kwargs):
        call_count["n"] += 1
        # Fail only the FIRST symlink_to call (the forward swap attempt);
        # let the restore's own symlink_to call through.
        if call_count["n"] == 1:
            raise OSError("simulated symlink_to failure")
        return real_symlink_to(self, target, **kwargs)

    monkeypatch.setattr(Path, "symlink_to", flaky_symlink_to)

    repo_root = Path(__file__).resolve().parents[1]
    result = updater.apply_update(str(repo_root))

    assert result.ok is False
    assert result.rolled_back is False
    assert "symlink swap failed" in result.message
    # The previous link must have been restored, not left dangling.
    assert updater.LIVE_VENV_LINK.is_symlink()
    assert updater.LIVE_VENV_LINK.readlink() == original_target


def test_rollback_reports_manual_intervention_when_revert_symlink_fails(
    isolated_install_root, monkeypatch, tmp_path
):
    """CR-C-flagged gap: if _rollback's own symlink revert raises, it must
    report rolled_back=False with MANUAL INTERVENTION language -- never
    falsely claim a successful rollback."""
    monkeypatch.setattr(updater, "_restart_service", lambda: (True, ""))
    monkeypatch.setattr(updater, "_query_health", lambda timeout=5.0: None)
    monkeypatch.setattr(updater.time, "sleep", lambda _seconds: None)

    real_symlink_to = Path.symlink_to
    call_count = {"n": 0}

    def flaky_symlink_to(self, target, **kwargs):
        call_count["n"] += 1
        # Let the forward swap (1st call) succeed; fail the rollback's
        # revert attempt (2nd call).
        if call_count["n"] == 2:
            raise OSError("simulated revert failure")
        return real_symlink_to(self, target, **kwargs)

    monkeypatch.setattr(Path, "symlink_to", flaky_symlink_to)

    repo_root = Path(__file__).resolve().parents[1]
    result = updater.apply_update(str(repo_root))

    assert result.ok is False
    assert result.rolled_back is False
    assert "MANUAL INTERVENTION REQUIRED" in result.message
    assert "rollback symlink revert also failed" in result.message


def test_rollback_reports_manual_intervention_when_restart_after_revert_fails(
    isolated_install_root, monkeypatch, tmp_path
):
    """CR-C-flagged gap: if the symlink revert succeeds but the subsequent
    restart fails, _rollback must report rolled_back=False with MANUAL
    INTERVENTION language -- the symlink points at the old install again,
    but nothing confirmed it's actually running."""
    original_target = updater.LIVE_VENV_LINK.readlink()

    restart_calls: list[int] = []

    def restart_fails_on_rollback() -> tuple[bool, str]:
        restart_calls.append(len(restart_calls))
        # First call = forward-swap restart (succeeds, to get us past the
        # swap and into the health-check-triggers-rollback path). Second
        # call = rollback's own restart attempt (fails).
        if len(restart_calls) == 1:
            return True, ""
        return False, "simulated restart failure during rollback"

    monkeypatch.setattr(updater, "_restart_service", restart_fails_on_rollback)
    monkeypatch.setattr(updater, "_query_health", lambda timeout=5.0: None)
    monkeypatch.setattr(updater.time, "sleep", lambda _seconds: None)

    repo_root = Path(__file__).resolve().parents[1]
    result = updater.apply_update(str(repo_root))

    assert result.ok is False
    assert result.rolled_back is False
    assert "MANUAL INTERVENTION REQUIRED" in result.message
    assert "restart also failed" in result.message
    # The symlink itself WAS reverted even though the restart failed.
    assert updater.LIVE_VENV_LINK.readlink() == original_target


def test_cleanup_guard_rejects_corrupted_previous_target_outside_staged_root(
    isolated_install_root, monkeypatch, tmp_path
):
    """CR-C-flagged defense-in-depth check: if `previous_target` somehow
    pointed outside STAGED_ROOT (corrupted state), the cleanup step's rmtree
    guard must refuse to delete it rather than blindly removing an
    arbitrary directory."""
    # Re-point the live link directly at a directory OUTSIDE STAGED_ROOT,
    # simulating corrupted prior state, while still containing a real,
    # working curtain-bridge install so validate/swap/health can succeed
    # normally and reach the cleanup step.
    outside_dir = tmp_path / "outside-staged-root"
    outside_venv = outside_dir / "venv"
    import subprocess
    import sys

    subprocess.run([sys.executable, "-m", "venv", str(outside_venv)], check=True)
    repo_root = Path(__file__).resolve().parents[1]
    subprocess.run(
        [str(outside_venv / "bin" / "pip"), "install", "--quiet", str(repo_root)], check=True
    )
    updater.LIVE_VENV_LINK.unlink()
    updater.LIVE_VENV_LINK.symlink_to(outside_venv, target_is_directory=True)

    def fake_restart() -> tuple[bool, str]:
        return True, ""

    def fake_query_health(timeout: float = 5.0) -> dict[str, object]:
        import subprocess as sp

        result = sp.run(
            [str(updater.LIVE_VENV_LINK / "bin" / "python"), "-c",
             "from curtain_bridge.health import get_installed_version as g; print(g())"],
            capture_output=True, text=True, check=True,
        )
        return {"status": "ok", "version": result.stdout.strip(), "uptime_seconds": 0}

    monkeypatch.setattr(updater, "_restart_service", fake_restart)
    monkeypatch.setattr(updater, "_query_health", fake_query_health)

    result = updater.apply_update(str(repo_root))

    assert result.ok is True
    # The directory outside STAGED_ROOT must NOT have been deleted by the
    # cleanup step's guard.
    assert outside_dir.exists(), "cleanup must never rmtree a path outside STAGED_ROOT"


def test_rollback_with_no_previous_install_reports_manual_intervention(tmp_path, monkeypatch):
    """Edge case: a first-ever install (no seeded previous target) that fails
    post-swap has nothing to roll back TO. Must report this honestly rather
    than claiming a rollback that cannot have happened."""
    install_root = tmp_path / "curtain-bridge"
    staged_root = install_root / "staged"
    live_link = install_root / "venv"
    install_root.mkdir()
    staged_root.mkdir()
    monkeypatch.setattr(updater, "INSTALL_ROOT", install_root)
    monkeypatch.setattr(updater, "STAGED_ROOT", staged_root)
    monkeypatch.setattr(updater, "LIVE_VENV_LINK", live_link)
    # No symlink seeded at all -- genuinely first install.

    monkeypatch.setattr(updater, "_restart_service", lambda: (True, ""))
    monkeypatch.setattr(updater, "_query_health", lambda timeout=5.0: None)
    monkeypatch.setattr(updater.time, "sleep", lambda _seconds: None)

    repo_root = Path(__file__).resolve().parents[1]
    result = updater.apply_update(str(repo_root))

    assert result.ok is False
    assert result.rolled_back is False
    assert "MANUAL INTERVENTION REQUIRED" in result.message
    assert "no previous version" in result.message
