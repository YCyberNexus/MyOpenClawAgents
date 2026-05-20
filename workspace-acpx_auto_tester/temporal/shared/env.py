"""Bootstrap env contract for the leaf bash scripts.

Every ``scripts/*.sh`` self-bootstraps by sourcing ``env_paths.sh`` at its
top, but ``env_paths.sh`` requires a minimum envelope of env vars on every
call (see CLAUDE.md §Per-exec environment contract). The OpenClaw runtime
used to forward these via the trigger payload; under Temporal each activity
must compose them and pass them via ``env={...}`` to
``asyncio.create_subprocess_exec``.

This module produces the dict — it does **not** mutate ``os.environ``.
Mutating ``os.environ`` from inside an async activity is unsafe: concurrent
activities on the same worker would race.

Sources:
    * trigger fields (project / group / repo_parent_path / basenames) come
      from the workflow's :class:`CampaignInput`.
    * ``GITLAB_TOKEN`` comes from the worker's startup env (set by the runner
      operator; never persisted in workflow history).
    * per-attempt fields (``ISSUE_IID``, ``ATTEMPT_NUMBER``, ``BRANCH`` etc.)
      come from :class:`AttemptInput`.

Two helpers:
    * :func:`build_dispatcher_env` — minimum envelope for orchestrator-side
      activities (reconcile / clone / etc.) that do not bind to one IID.
    * :func:`build_attempt_env` — adds the per-IID + per-attempt vars on top.
"""

from __future__ import annotations

import os
from typing import Mapping

from .types import AttemptInput, CampaignInput


def _gitlab_token() -> str:
    """Read ``GITLAB_TOKEN`` from the worker env.

    Raises:
        RuntimeError: when the worker started without the secret. The
            activity that calls this will surface the failure as an
            ``ApplicationError(type=glab_auth_failed)``; this function uses
            a plain RuntimeError because ``ApplicationError`` can only be
            constructed inside an activity context.
    """
    token = os.environ.get("GITLAB_TOKEN")
    if not token:
        raise RuntimeError(
            "GITLAB_TOKEN missing in worker env. Set it before launching the worker "
            "(see workspace-acpx_auto_tester/temporal/README.md §Run a worker)."
        )
    return token


def build_dispatcher_env(inp: CampaignInput) -> dict[str, str]:
    """Compose the dispatcher-minimum env contract for an orchestrator-side
    activity.

    Mirrors CLAUDE.md "Dispatcher minimum: PROJECT, GROUP, GITLAB_TOKEN
    (plus REPO_PARENT_PATH when trigger repo_path is non-default)".
    """
    env: dict[str, str] = {
        # Inherit PATH / LANG / LC_ALL / HOME from the worker so subprocess
        # finds glab / git / acpx without us re-deriving them.
        **{k: v for k, v in os.environ.items() if k in _INHERIT_PASSTHROUGH},
        "PROJECT": inp.project,
        "GROUP": inp.group,
        "GITLAB_TOKEN": _gitlab_token(),
        "REPO_PARENT_PATH": inp.repo_parent_path,
        "RESULT_BASENAME": inp.result_basename,
        "DATA_BASENAME": inp.data_basename,
        "BRANCH": inp.branch,
        "DEV_BRANCH": inp.dev_branch,
        "MAX_CONCURRENT_SUBAGENTS": str(inp.max_concurrent_subagents),
        "MAX_ACCOUNTS_PER_ISSUE": str(inp.max_accounts_per_issue),
    }
    return env


def build_attempt_env(
    inp: CampaignInput,
    attempt: AttemptInput,
    *,
    ui_accounts_json: str | None = None,
) -> dict[str, str]:
    """Compose the per-IID env contract for a leaf activity.

    Adds ``ISSUE_IID`` / ``ATTEMPT_NUMBER`` / ``ISSUE_MODE`` / etc. on top of
    the dispatcher-minimum envelope.

    Args:
        inp: Campaign-level configuration (carries paths, branches, timeouts).
        attempt: Per-attempt parameters (carries IID, attempt number, mode).
        ui_accounts_json: JSON string of the slot's UI accounts. Passed as
            ``UI_ACCOUNTS=...``; set only for activities that render the
            executor prompt (``build_executor_prompt``).
    """
    env = build_dispatcher_env(inp)
    env.update(
        {
            "ISSUE_IID": str(attempt.iid),
            "ATTEMPT_NUMBER": str(attempt.attempt_number),
            "ISSUE_MODE": attempt.mode,
            "ISSUE_TITLE": attempt.issue_title,
            "WORK_BRANCH": attempt.work_branch,
            "ACPX_TIMEOUT_SECONDS": str(inp.acpx_timeout_seconds),
        }
    )
    if ui_accounts_json is not None:
        env["UI_ACCOUNTS"] = ui_accounts_json
    return env


# Env vars worth passing through to subprocess from the worker. Bash scripts
# rely on PATH for ``glab`` / ``git``; LANG/LC_ALL keep glab output stable;
# HOME is required by glab's config dir. SSH_AUTH_SOCK is passed for HTTPS
# token auth on some glab builds. We deliberately do NOT pass everything via
# ``env=None`` (inherit) because some operators run the worker under systemd
# with extra noise vars that would inflate every subprocess's environment.
_INHERIT_PASSTHROUGH = frozenset(
    {
        "PATH",
        "HOME",
        "LANG",
        "LC_ALL",
        "USER",
        "LOGNAME",
        "TZ",
        "TMPDIR",
        "SSH_AUTH_SOCK",
        # If the runner sets a glab config dir override; harmless when unset.
        "GLAB_CONFIG_DIR",
        "XDG_CONFIG_HOME",
    }
)


def merge_env(base: Mapping[str, str], overrides: Mapping[str, str]) -> dict[str, str]:
    """Convenience: shallow-merge two env dicts, overrides win."""
    merged = dict(base)
    merged.update(overrides)
    return merged


__all__ = [
    "build_attempt_env",
    "build_dispatcher_env",
    "merge_env",
]
