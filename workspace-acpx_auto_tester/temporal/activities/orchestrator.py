"""Orchestrator-side activities (A1–A6).

Called by :class:`CampaignWorkflow` before any IssueAttemptWorkflow children
are spawned. These wrap the SKILL's orchestrator-side bash scripts that
already exist:

* A1 ``reconcile_gitlab``           ← ``reconcile.sh``
* A2 ``ensure_workflow_labels``     ← ``ensure_labels.sh``
* A3 ``clone_or_pull_repo``         ← ``clone_or_pull.sh``
* A4 ``load_ui_account_pool``       ← ``load_ui_accounts.sh`` + parser
* A5 ``prepare_attempt_worktree``   ← ``prepare_attempt.sh``
* A6 ``build_executor_prompt``      ← ``build_prompt.sh``

Each leaf script keeps its existing contract; the activity layer only adds
typed inputs/outputs and ApplicationError translation.
"""

from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path
from typing import Final

from temporalio import activity

from ..shared.env import build_attempt_env, build_dispatcher_env
from ..shared.errors import AcpxErrorType, raise_app_error
from ..shared.types import (
    AttemptInput,
    CampaignInput,
    IssueLiveState,
    PreparedAttempt,
    ReconcileEvidence,
    UiAccount,
)
from ..shared.ui_accounts import load_pool
from .leaf import _derive_paths  # share path computation logic
from .subprocess import run_script

LOG = logging.getLogger("acpx_temporal.activities.orchestrator")


# ---------------------------------------------------------------------------
# A1 — reconcile_gitlab
# ---------------------------------------------------------------------------


@activity.defn(name="reconcile_gitlab")
async def reconcile_gitlab(
    camp: CampaignInput,
    *,
    single_iid: int | None = None,
) -> ReconcileEvidence:
    """Query GitLab labels + state for the IID range and parse the resulting
    evidence file into a :class:`ReconcileEvidence`.

    ``single_iid`` narrows the range to one IID — used on the callback path
    in the legacy dispatcher; the Temporal version uses it for spot-checks.
    """
    env = build_dispatcher_env(camp)
    if single_iid is not None:
        env["IID_LIST"] = str(single_iid)
        env["MIN_IID"] = str(single_iid)
        env["MAX_IID"] = str(single_iid)
    else:
        env["MIN_IID"] = str(camp.issue_min_iid)
        env["MAX_IID"] = str(camp.issue_max_iid)

    res = await run_script("reconcile.sh", env=env)
    if res.exit_code != 0:
        msg = res.stderr.lower()
        if "401" in msg or "unauthorized" in msg or "auth" in msg:
            raise_app_error(
                AcpxErrorType.GLAB_AUTH_FAILED,
                f"reconcile.sh auth error: {res.stderr[-500:]}",
            )
        if "503" in msg or "504" in msg or "transient" in msg or "rate" in msg:
            raise_app_error(
                AcpxErrorType.GITLAB_TRANSIENT,
                f"reconcile.sh transient error: {res.stderr[-500:]}",
            )
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"reconcile.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )

    # Convention: reconcile.sh prints the absolute path of the evidence JSON
    # file on its last stdout line.
    evidence_path = res.stdout.strip().splitlines()[-1].strip()
    return _parse_reconcile_evidence(
        evidence_path,
        camp.issue_min_iid if single_iid is None else single_iid,
        camp.issue_max_iid if single_iid is None else single_iid,
    )


def _parse_reconcile_evidence(
    path: str, min_iid: int, max_iid: int
) -> ReconcileEvidence:
    """Read the evidence JSON written by ``reconcile.sh`` into a typed
    :class:`ReconcileEvidence`. The evidence file shape is documented in
    ``scripts/reconcile.sh`` (a list of per-IID digests)."""
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"could not read reconcile evidence {path}: {exc}",
        )
    try:
        digest = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"reconcile evidence {path} not valid JSON: {exc}",
        )

    per_iid: list[IssueLiveState] = []
    for entry in digest if isinstance(digest, list) else []:
        labels = tuple(entry.get("labels", ()) or ())
        per_iid.append(
            IssueLiveState(
                iid=int(entry["iid"]),
                is_closed_on_gitlab=bool(entry.get("is_closed_on_gitlab", False)),
                has_done_pr=bool(entry.get("has_done_pr", False)),
                needs_continue=bool(entry.get("needs_continue", False)),
                user_reopened=bool(entry.get("user_reopened", False)),
                has_timeout=bool(entry.get("has_timeout", False)),
                has_blocked="blocked" in labels,
                has_failed="failed" in labels,
                has_retry="retry" in labels,
                labels=labels,
            )
        )

    return ReconcileEvidence(
        queried_min_iid=min_iid,
        queried_max_iid=max_iid,
        queried_at_ms=int(activity.info().current_attempt_scheduled_time.timestamp() * 1000),
        per_iid=tuple(per_iid),
    )


# ---------------------------------------------------------------------------
# A2 — ensure_workflow_labels
# ---------------------------------------------------------------------------


@activity.defn(name="ensure_workflow_labels")
async def ensure_workflow_labels(camp: CampaignInput) -> tuple[str, ...]:
    """Idempotent: ``ensure_labels.sh`` creates any missing workflow labels.
    Returns the labels that were created this run (for logging)."""
    res = await run_script("ensure_labels.sh", env=build_dispatcher_env(camp))
    if res.exit_code != 0:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"ensure_labels.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )
    return tuple(
        line.removeprefix("created:").strip()
        for line in res.stdout.splitlines()
        if line.startswith("created:")
    )


# ---------------------------------------------------------------------------
# A3 — clone_or_pull_repo
# ---------------------------------------------------------------------------


@activity.defn(name="clone_or_pull_repo")
async def clone_or_pull_repo(camp: CampaignInput) -> str:
    """Ensure ``${REPO_PATH}`` exists and ``origin`` is fetched. Returns the
    canonical repo path so the parent can pass it back."""
    res = await run_script(
        "clone_or_pull.sh",
        env=build_dispatcher_env(camp),
        heartbeat_every_s=30.0,
        heartbeat=_idle_heartbeat,
    )
    if res.exit_code != 0:
        msg = res.stderr.lower()
        # Parenthesized for clarity (review I1): "invalid_repo_path" alone
        # OR (path AND invalid) — explicit precedence.
        if ("invalid_repo_path" in msg) or ("path" in msg and "invalid" in msg):
            raise_app_error(
                AcpxErrorType.INVALID_REPO_PATH,
                f"clone_or_pull.sh rejected path: {res.stderr[-500:]}",
            )
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"clone_or_pull.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )
    return f"{camp.repo_parent_path.rstrip('/')}/{camp.project}"


# ---------------------------------------------------------------------------
# A4 — load_ui_account_pool
# ---------------------------------------------------------------------------


def _resolve_pool_path() -> Path:
    """Resolve ``<workspace>/config/ui_accounts.env`` with env override.

    Extracted as a sync helper so :func:`build_executor_prompt` can read the
    pool inline (via :func:`shared.ui_accounts.load_pool`) without invoking
    the ``load_ui_account_pool`` activity recursively. Calling one activity
    from inside another binds the inner call to the outer's RetryPolicy,
    which would let a ``POOL_EMPTY`` (intentionally non-retryable on its own
    activity) inherit the outer's two-attempts policy. See round-2 review
    Critical-2.
    """
    workspace_dir = Path(__file__).resolve().parents[2]
    pool_path = workspace_dir / "config" / "ui_accounts.env"
    override = os.environ.get("ACPX_UI_ACCOUNTS_PATH")
    if override:
        pool_path = Path(override)
    return pool_path


@activity.defn(name="load_ui_account_pool")
async def load_ui_account_pool() -> tuple[UiAccount, ...]:
    """Parse ``<workspace>/config/ui_accounts.env`` into a tuple of accounts.

    The legacy dispatcher's ``load_ui_accounts.sh`` divides the pool into
    per-IID slots; under Temporal that math moves into
    :func:`shared.ui_accounts.allocate_slots` (pure, deterministic) so the
    activity only returns the raw pool.
    """
    return load_pool(_resolve_pool_path())


# ---------------------------------------------------------------------------
# A5 — prepare_attempt_worktree
# ---------------------------------------------------------------------------

# prepare_attempt.sh prints "mode_actual\nlocal_branch" on stdout.
_PREPARE_OUTPUT_RE: Final[re.Pattern[str]] = re.compile(
    r"^(?P<mode>fresh|continue)\s*\n(?P<branch>\S+)\s*$",
    re.MULTILINE,
)


@activity.defn(name="prepare_attempt_worktree")
async def prepare_attempt_worktree(
    camp: CampaignInput, att: AttemptInput
) -> PreparedAttempt:
    """Create-or-reuse the shared per-issue linked worktree at
    ``${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>/`` and check out
    ``BASE_REF`` (``origin/${dev_branch}`` for fresh, ``origin/${work_branch}``
    for continue).
    """
    env = build_attempt_env(camp, att)
    paths = _derive_paths(camp, att)
    env.update(paths)

    res = await run_script("prepare_attempt.sh", env=env)
    if res.exit_code != 0:
        msg = res.stderr.lower()
        if "dev_branch" in msg and ("missing" in msg or "not found" in msg):
            raise_app_error(
                AcpxErrorType.DEV_BRANCH_MISSING,
                f"prepare_attempt.sh dev_branch missing: {res.stderr[-500:]}",
            )
        if "lease" in msg or "lock" in msg or "concurrent" in msg:
            raise_app_error(
                AcpxErrorType.WORKTREE_LEASE_CONFLICT,
                f"prepare_attempt.sh lease conflict: {res.stderr[-500:]}",
            )
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"prepare_attempt.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )

    lines = [ln.strip() for ln in res.stdout.splitlines() if ln.strip()]
    if len(lines) < 2:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"prepare_attempt.sh stdout malformed: {res.stdout!r}",
        )
    mode_actual_raw, local_branch = lines[0], lines[1]
    if mode_actual_raw not in ("fresh", "continue"):
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"prepare_attempt.sh emitted unknown mode {mode_actual_raw!r}",
        )

    mode_downgraded = (
        att.mode if (att.mode != mode_actual_raw and att.mode == "continue") else None
    )

    return PreparedAttempt(
        iid=att.iid,
        attempt_number=att.attempt_number,
        mode_actual=mode_actual_raw,  # type: ignore[arg-type]
        mode_downgraded_from=mode_downgraded,  # type: ignore[arg-type]
        worktree_dir=paths["WORKTREE_DIR"],
        log_dir=paths["LOG_DIR"],
        output_dir=paths["OUTPUT_DIR"],
        local_attempt_branch=paths["LOCAL_ATTEMPT_BRANCH"],
    )


# ---------------------------------------------------------------------------
# A6 — build_executor_prompt
# ---------------------------------------------------------------------------


@activity.defn(name="build_executor_prompt")
async def build_executor_prompt(
    camp: CampaignInput,
    att: AttemptInput,
) -> str:
    """Render ``${LOG_DIR}/prompt.txt`` via ``build_prompt.sh``.

    Returns the absolute path to the rendered prompt — the same path
    ``run_acpx_attempt.sh`` reads via ``-f``.

    Security note (review B6): UI account credentials are de-referenced
    **inside this activity** by reading
    ``<workspace>/config/ui_accounts.env`` on the worker host, slicing by
    ``att.ui_account_index_start`` / ``att.ui_account_count``, and feeding
    JSON into the ``UI_ACCOUNTS=`` env var that ``build_prompt.sh`` reads.
    The calling workflow only passes integer slot indices — plaintext
    passwords never enter Temporal workflow history.

    We call :func:`shared.ui_accounts.load_pool` directly (sync) rather than
    ``await load_ui_account_pool()`` because awaiting another ``@activity.defn``
    from inside an activity body executes it within the *current* activity's
    retry / heartbeat context, which would let a ``POOL_EMPTY`` raised by the
    inner call inherit this activity's RetryPolicy. See round-2 review
    Critical-2.
    """
    pool = load_pool(_resolve_pool_path())
    slot_start = att.ui_account_index_start
    slot_end = slot_start + att.ui_account_count
    if slot_end > len(pool):
        raise_app_error(
            AcpxErrorType.POOL_TOO_SMALL,
            f"UI account slot [{slot_start}, {slot_end}) exceeds pool size {len(pool)}",
        )
    slot_accounts = pool[slot_start:slot_end]
    ui_accounts_json = json.dumps(
        [
            {"index": acc.index, "username": acc.username, "password": acc.password}
            for acc in slot_accounts
        ]
    )

    env = build_attempt_env(camp, att, ui_accounts_json=ui_accounts_json)
    paths = _derive_paths(camp, att)
    env.update(paths)

    res = await run_script("build_prompt.sh", env=env)
    if res.exit_code != 0:
        msg = res.stderr.lower()
        if "not found" in msg or "404" in msg:
            raise_app_error(
                AcpxErrorType.GLAB_ISSUE_NOT_FOUND,
                f"build_prompt.sh issue not found: {res.stderr[-500:]}",
            )
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"build_prompt.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )
    # Convention: build_prompt.sh prints the absolute path of prompt.txt on stdout.
    return res.stdout.strip().splitlines()[-1].strip()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _idle_heartbeat() -> None:
    """No-progress heartbeat for long-running scripts (e.g. ``clone_or_pull.sh``
    first clone). Just keeps Temporal's heartbeat clock fresh."""
    try:
        activity.heartbeat({"keepalive": True})
    except RuntimeError:
        pass


__all__ = [
    "build_executor_prompt",
    "clone_or_pull_repo",
    "ensure_workflow_labels",
    "load_ui_account_pool",
    "prepare_attempt_worktree",
    "reconcile_gitlab",
]
