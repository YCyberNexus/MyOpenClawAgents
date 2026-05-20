"""Asyncio wrapper around the dispatcher SKILL's leaf bash scripts.

Single shared entrypoint :func:`run_script` so every activity (A1–A16) calls
the bash side the same way:

* picks up the absolute SKILL scripts dir (resolved once at module import);
* shells out via ``asyncio.create_subprocess_exec`` with a clean ``env=...``
  dict (no PATH inheritance footguns) — see :mod:`acpx_temporal.shared.env`
  for the contract;
* streams stdout to a log file in the worker's temp dir, captures stderr
  inline for the ApplicationError payload;
* translates non-zero exits into typed :class:`ApplicationError` instances
  using the :mod:`acpx_temporal.shared.errors` taxonomy.

The wrapper is intentionally NOT a long-running PTY supervisor — that role
belongs only to ``run_acpx_attempt.sh`` (A7), which the activities handle
specially by polling the progress marker file for heartbeats. See the
docstring on :func:`run_script` for the heartbeat hook.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import shlex
import signal
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable, Mapping

from temporalio import activity

from ..shared.errors import AcpxErrorType, raise_app_error

LOG = logging.getLogger("acpx_temporal.activities.subprocess")


# ---------------------------------------------------------------------------
# Scripts directory resolution
# ---------------------------------------------------------------------------


def _resolve_scripts_dir() -> Path:
    """Resolve the dispatcher SKILL's ``scripts/`` directory.

    Two ways:
    1. ``ACPX_SCRIPTS_DIR`` env var (override for non-default deployments).
    2. Default: walk up from this file to ``workspace-acpx_auto_tester/`` and
       join ``skills/gitlab_issue_campaign_dispatcher/scripts``.

    Raises:
        RuntimeError: when the default path doesn't exist and no env override
            was provided. The worker process fails fast at first activity
            invocation rather than silently shelling out to a missing dir.
    """
    override = os.environ.get("ACPX_SCRIPTS_DIR")
    if override:
        p = Path(override).resolve()
        if not p.is_dir():
            raise RuntimeError(
                f"ACPX_SCRIPTS_DIR={override} is not an existing directory"
            )
        return p

    # __file__ is /.../workspace-acpx_auto_tester/temporal/activities/subprocess.py
    # Walk up two levels for workspace-acpx_auto_tester/, then dive into skills/.
    here = Path(__file__).resolve()
    workspace_dir = here.parents[2]  # …/workspace-acpx_auto_tester/
    p = workspace_dir / "skills" / "gitlab_issue_campaign_dispatcher" / "scripts"
    if not p.is_dir():
        raise RuntimeError(
            "Cannot locate dispatcher scripts dir. "
            f"Expected at {p} (or set ACPX_SCRIPTS_DIR)."
        )
    return p


SCRIPTS_DIR: Path = _resolve_scripts_dir()


# ---------------------------------------------------------------------------
# Result + run helpers
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ScriptResult:
    """Outcome of one ``run_script`` invocation. Captured even on failure
    because some scripts (e.g. ``stage_and_guard.sh``) signal NO_CHANGES via
    stdout, not exit code."""

    exit_code: int
    stdout: str
    stderr: str


# ── Heartbeat poll type ────────────────────────────────────────────────────
# A callable an activity can pass in to be invoked every ``heartbeat_every``
# seconds while ``run_script`` is awaiting the subprocess. The callable is
# expected to call ``temporalio.activity.heartbeat(details)``; this module
# does not assume one heartbeat payload shape.
HeartbeatFn = Callable[[], Awaitable[None]]


async def run_script(
    script_name: str,
    *,
    env: Mapping[str, str],
    args: tuple[str, ...] = (),
    cwd: str | Path | None = None,
    stdin: str | None = None,
    heartbeat: HeartbeatFn | None = None,
    heartbeat_every_s: float = 60.0,
    log_path: str | Path | None = None,
) -> ScriptResult:
    """Run ``${SCRIPTS_DIR}/<script_name>`` and return its outcome.

    Args:
        script_name: file name under ``SCRIPTS_DIR``, e.g. ``"reconcile.sh"``.
            No directory traversal allowed.
        env: env dict to pass via ``asyncio.create_subprocess_exec(env=...)``.
            See :mod:`acpx_temporal.shared.env` for the contract.
        args: positional arguments to pass to the script (already
            shell-safe — no quoting needed).
        cwd: working directory. Defaults to ``SCRIPTS_DIR``'s parent
            (i.e. the SKILL dir), matching the dispatcher's ``cd ${SKILL_DIR}``
            rule from SOUL.md §Working Directory.
        stdin: optional text fed to the subprocess on its stdin.
        heartbeat: optional async callback invoked every
            ``heartbeat_every_s`` seconds. Use this for A7
            ``run_claude_code_attempt`` whose StartToClose is 18120s.
        heartbeat_every_s: seconds between heartbeat invocations.
        log_path: optional file path where stdout+stderr are tee'd for
            offline review. When omitted, only the return value carries them.

    Returns:
        :class:`ScriptResult`. Non-zero exit codes do NOT raise here — that
        decision is the caller's, so error-type taxonomy mapping happens
        in each activity body where the surrounding context (script name +
        exit code + stdout shape) is available.

    Raises:
        ApplicationError(type=subprocess_failed, non_retryable=True): only
            when the script binary itself is missing / not executable. Any
            other behavior (non-zero exit, signal kill) is reported via
            :class:`ScriptResult` instead.
    """
    if "/" in script_name or ".." in script_name:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"refusing to run script with path-like name: {script_name!r}",
        )

    script_path = SCRIPTS_DIR / script_name
    if not script_path.is_file():
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"script not found: {script_path}",
        )

    cmd: tuple[str, ...] = ("bash", str(script_path), *args)
    use_cwd = str(cwd) if cwd is not None else str(SCRIPTS_DIR.parent)

    LOG.info(
        "exec %s (cwd=%s, env_keys=%s)",
        " ".join(shlex.quote(c) for c in cmd),
        use_cwd,
        sorted(env.keys()),
    )

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        cwd=use_cwd,
        env=dict(env),
        stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
    )

    # Feed stdin if requested. Done up front so the script never blocks on
    # read() while we sit in the heartbeat loop.
    stdin_bytes = stdin.encode("utf-8") if stdin is not None else None

    communicate_task: asyncio.Task[tuple[bytes, bytes]] = asyncio.create_task(
        proc.communicate(input=stdin_bytes)
    )

    try:
        while True:
            try:
                stdout_b, stderr_b = await asyncio.wait_for(
                    asyncio.shield(communicate_task),
                    timeout=heartbeat_every_s if heartbeat is not None else None,
                )
                break
            except asyncio.TimeoutError:
                # Heartbeat tick — subprocess still running. Re-loop the wait
                # on the SAME shielded task so we don't restart communicate().
                if heartbeat is not None:
                    try:
                        await heartbeat()
                    except asyncio.CancelledError:
                        # MUST propagate cancellation; activity cancellation is
                        # one of the Temporal-side liveness signals we depend on.
                        raise
                    except Exception:  # noqa: BLE001 — heartbeat must never crash run_script
                        LOG.exception("heartbeat callback raised; continuing")
    except asyncio.CancelledError:
        await _terminate_process(proc, script_name)
        communicate_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await communicate_task
        raise

    stdout_text = stdout_b.decode("utf-8", errors="replace") if stdout_b else ""
    stderr_text = stderr_b.decode("utf-8", errors="replace") if stderr_b else ""

    if log_path is not None:
        try:
            Path(log_path).parent.mkdir(parents=True, exist_ok=True)
            Path(log_path).write_text(
                f"$ {' '.join(shlex.quote(c) for c in cmd)}\n"
                f"=== stdout ===\n{stdout_text}\n=== stderr ===\n{stderr_text}\n",
                encoding="utf-8",
            )
        except OSError:
            LOG.exception("could not write log %s", log_path)

    # `await proc.communicate()` returns only after the process terminates,
    # so `returncode` MUST be set. If it's None here, the asyncio runtime is
    # in a bad state — fail loudly instead of returning a sentinel that the
    # caller's `if res.exit_code != 0` branch would interpret as a script
    # failure.
    if proc.returncode is None:
        raise_app_error(
            AcpxErrorType.INVARIANT_VIOLATION,
            f"subprocess {script_name} returned with returncode=None — "
            "asyncio runtime in a bad state",
        )
    exit_code = proc.returncode
    LOG.info(
        "exit %s %s (stdout=%d bytes, stderr=%d bytes)",
        script_name,
        exit_code,
        len(stdout_text),
        len(stderr_text),
    )
    return ScriptResult(exit_code=exit_code, stdout=stdout_text, stderr=stderr_text)


async def _terminate_process(
    proc: asyncio.subprocess.Process, script_name: str
) -> None:
    """Stop the child process when Temporal cancels the activity."""
    if proc.returncode is not None:
        return

    LOG.warning("activity cancelled; terminating subprocess %s", script_name)
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except PermissionError:
        proc.terminate()

    try:
        await asyncio.wait_for(proc.wait(), timeout=10.0)
    except asyncio.TimeoutError:
        LOG.warning("subprocess %s ignored terminate; killing", script_name)
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        except PermissionError:
            proc.kill()
        await proc.wait()


# ---------------------------------------------------------------------------
# Standard activity-side heartbeat factory
# ---------------------------------------------------------------------------


def make_marker_file_heartbeat(marker_path: str | Path) -> HeartbeatFn:
    """Return a heartbeat callback that reads ``marker_path``'s mtime and
    forwards it to ``temporalio.activity.heartbeat``.

    Used by A7 ``run_claude_code_attempt``: the patched
    ``run_acpx_attempt.sh`` writes ``${LOG_DIR}/acpx_progress.marker`` once
    per Claude Code step; if the file's mtime stops advancing for more than
    one heartbeat period, the activity's ``heartbeat_timeout`` will fire on
    its own — no extra logic needed here.
    """
    p = Path(marker_path)

    async def _hb() -> None:
        try:
            stat = p.stat()
            details = {"last_seen_ms": int(stat.st_mtime * 1000)}
        except FileNotFoundError:
            details = {"last_seen_ms": 0}
        # ``activity.heartbeat`` is sync but only valid inside an activity
        # execution context. ``run_script`` wraps the heartbeat call in a
        # try/except so a missing context (e.g. unit tests) does not crash.
        try:
            activity.heartbeat(details)
        except RuntimeError:
            pass

    return _hb


__all__ = [
    "HeartbeatFn",
    "ScriptResult",
    "SCRIPTS_DIR",
    "make_marker_file_heartbeat",
    "run_script",
]
