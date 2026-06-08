"""Orchestrator-side activities (A1–A6).

Called by :class:`CampaignWorkflow` before any IssueAttemptWorkflow children
are spawned. These wrap the SKILL's orchestrator-side bash scripts that
already exist:

* A1 ``reconcile_gitlab``           ← ``reconcile.sh``
* A2 ``ensure_workflow_labels``     ← ``ensure_labels.sh``
* A3 ``clone_or_pull_repo``         ← ``clone_or_pull.sh``
* A4 ``load_ui_account_pool``       ← ``${REPO_PATH}/${ui_accounts_relpath}`` JSON parser
* A4b ``allocate_attempt_number``   ← ``allocate_attempt.sh``
* A5 ``prepare_attempt_worktree``   ← ``prepare_attempt.sh``
* A6 ``build_executor_prompt``      ← ``build_prompt.sh``
* A6a ``mark_issue_doing``          ← ``set_issue_label.sh add doing``
* A6b ``record_attempt_outcome``    ← update per-issue ``state.json``

Each leaf script keeps its existing contract; the activity layer only adds
typed inputs/outputs and ApplicationError translation.
"""

from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Final

from temporalio import activity

from ..shared.env import build_attempt_env, build_dispatcher_env
from ..shared.errors import AcpxErrorType, raise_app_error
from ..shared.types import (
    AttemptInput,
    AttemptOutcome,
    CampaignInput,
    IssueLiveState,
    PreparedAttempt,
    ReconcileEvidence,
    UiAccountPoolInfo,
)
from ..shared.ui_accounts import load_pool
from .leaf import _derive_paths  # share path computation logic
from .subprocess import SCRIPTS_DIR, run_script

LOG = logging.getLogger("acpx_temporal.activities.orchestrator")


# ---------------------------------------------------------------------------
# A1 — reconcile_gitlab
# ---------------------------------------------------------------------------


@activity.defn(name="reconcile_gitlab")
async def reconcile_gitlab(camp: CampaignInput) -> ReconcileEvidence:
    """Query GitLab labels + state for the IID range and parse the resulting
    evidence file into a :class:`ReconcileEvidence`.

    IMPORTANT — exactly ONE positional parameter. temporalio's worker drops
    ALL argument type hints when ``len(arg_types) != len(args passed)``
    (see ``temporalio/worker/_activity.py``: ``if len(arg_types) != len(input):
    arg_types = None``). When that happens ``camp`` is decoded untyped and
    arrives as a raw ``dict`` instead of a ``CampaignInput`` — the exact bug a
    former trailing ``single_iid: int | None = None`` default caused, since the
    sole call site passes ``args=[inp]`` (one arg) against a two-param
    signature. Do NOT add a second/optional parameter here. A future single-IID
    reconcile must be modeled as a field on the input dataclass, not as an extra
    activity argument.
    """
    env = build_dispatcher_env(camp)
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
        camp,
        camp.issue_min_iid,
        camp.issue_max_iid,
    )


def _parse_reconcile_evidence(
    path: str, camp: CampaignInput, min_iid: int, max_iid: int
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

    if not isinstance(digest, list):
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"reconcile evidence {path} is {type(digest).__name__}, expected a JSON array "
            "(reconcile.sh produced an empty or malformed file)",
        )

    per_iid: list[IssueLiveState] = []
    for entry in digest:
        labels = tuple(entry.get("labels", ()) or ())
        state = _read_issue_disk_state(camp, int(entry["iid"]))
        per_iid.append(
            IssueLiveState(
                iid=int(entry["iid"]),
                title=str(entry.get("title") or ""),
                is_closed_on_gitlab=bool(entry.get("is_closed_on_gitlab", False)),
                # v2: pr REPLACES done — the completion signal is the pr label.
                has_pr=bool(entry.get("has_pr", False)),
                needs_continue=bool(entry.get("needs_continue", False)),
                user_reopened=bool(entry.get("user_reopened", False)),
                has_timeout=bool(entry.get("has_timeout", False)),
                # v2: blocked / failed split by attribution side. Prefer the
                # explicit reconcile.sh fields; fall back to label membership
                # for robustness against an older evidence file.
                has_blocked_cc=bool(
                    entry.get("has_blocked_cc", "blocked-cc" in labels)
                ),
                has_blocked_dispatcher=bool(
                    entry.get("has_blocked_dispatcher", "blocked-dispatcher" in labels)
                ),
                has_failed_cc=bool(
                    entry.get("has_failed_cc", "failed-cc" in labels)
                ),
                has_failed_dispatcher=bool(
                    entry.get("has_failed_dispatcher", "failed-dispatcher" in labels)
                ),
                has_retry="retry" in labels,
                model_tier=int(entry.get("model_tier", 0) or 0),
                labels=labels,
                retry_count=int(state.get("retry_count", 0) or 0),
                blocked_at_tick=int(state.get("blocked_at_tick", -1) or -1),
            )
        )

    return ReconcileEvidence(
        queried_min_iid=min_iid,
        queried_max_iid=max_iid,
        queried_at_ms=int(activity.info().current_attempt_scheduled_time.timestamp() * 1000),
        per_iid=tuple(per_iid),
    )


def _issue_state_path(camp: CampaignInput, iid: int) -> Path:
    repo_path = f"{camp.repo_parent_path.rstrip('/')}/{camp.project}"
    return (
        Path(repo_path)
        / camp.result_basename
        / "issues"
        / f"issue-{iid}"
        / "state.json"
    )


def _read_issue_disk_state(camp: CampaignInput, iid: int) -> dict[str, object]:
    path = _issue_state_path(camp, iid)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _campaign_tick_path(camp: CampaignInput) -> Path:
    """Dispatcher-level file holding the monotonic campaign tick counter.

    Lives next to the legacy ``campaign_state.json`` location
    (``${REPO_PATH}/${result_basename}/_dispatcher/``) so the two schedulers
    share the same on-disk neighbourhood without colliding on a file name.
    """
    repo_path = f"{camp.repo_parent_path.rstrip('/')}/{camp.project}"
    return (
        Path(repo_path)
        / camp.result_basename
        / "_dispatcher"
        / "campaign_tick.json"
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
# A2b — self_heal_safety_bin
# ---------------------------------------------------------------------------


@activity.defn(name="self_heal_safety_bin")
async def self_heal_safety_bin() -> tuple[str, ...]:
    """Restore +x on every regular file under ``scripts/safety_bin/``.

    Mirrors ``_dispatch_lib.sh::ensure_safety_bin_executable``: some
    deployment pipelines (rsync without ``-p``, tar extraction under a
    restrictive umask, ``core.fileMode=false``) strip the execute bit when
    shipping this workspace to the runner. ``run_acpx_attempt.sh`` then
    asserts ``[ -x safety_bin/rm ]`` before invoking ``acpx`` and exits 2 in
    FAIL flow before any business logic runs.

    Restoring the bit here keeps the no-fallback rule intact at the business
    layer while preventing a deployment-side regression from blocking every
    subagent. No-op when files are already executable (steady state). Symlinks
    are skipped to avoid chmod following the link out of ``safety_bin/``.

    Returns:
        Tuple of file basenames that were healed (empty in steady state). The
        return value is used only for logging / Schedule history visibility.
    """
    healed: list[str] = []
    safety_bin = SCRIPTS_DIR / "safety_bin"
    if not safety_bin.is_dir():
        return tuple(healed)

    for entry in safety_bin.iterdir():
        try:
            # is_symlink() must be checked BEFORE is_file() because is_file()
            # follows symlinks; a link pointing outside safety_bin/ should be
            # skipped even when the target is a regular executable.
            if entry.is_symlink() or not entry.is_file():
                continue
            if os.access(entry, os.X_OK):
                continue
            mode = entry.stat().st_mode
            # ``0o111`` sets the three execute bits directly; unlike bash
            # ``chmod +x`` this is umask-agnostic — correct here because
            # we want to recover the exact bits deployment dropped.
            entry.chmod(mode | 0o111)
            healed.append(entry.name)
            LOG.info("self-heal: chmod +x %s (deployment dropped mode bit)", entry)
        except OSError as exc:
            LOG.warning("self_heal_safety_bin: chmod %s failed: %s", entry, exc)
    return tuple(healed)


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


def _pool_is_configured(camp: CampaignInput) -> bool:
    """True when this deployment opted into UI test accounts.

    Mirrors the bash dispatcher's ``[ -n "${UI_ACCOUNTS_RELPATH}" ]`` gate in
    ``dispatch_prepare_tick.sh`` §14: the pool is **opt-in**, so an empty
    ``ui_accounts_relpath`` means "skip the whole UI-account flow". The
    ``ACPX_UI_ACCOUNTS_PATH`` local-test escape hatch forces the pool on even
    when the relpath is empty, so it counts as configured too.

    Note: this gate (used by :func:`load_ui_account_pool`) reads ``os.environ``
    while :func:`build_executor_prompt` instead gates on ``att.ui_account_count``.
    The two stay consistent because all per-IID activities of a tick share one
    worker host via worktree affinity (``task_queue=workflow.info().task_queue``)
    and production deployments never set ``ACPX_UI_ACCOUNTS_PATH`` (the relpath
    drives everything), so the two signals cannot disagree.
    """
    return bool(os.environ.get("ACPX_UI_ACCOUNTS_PATH")) or bool(
        camp.ui_accounts_relpath
    )


def _resolve_pool_path(camp: CampaignInput) -> Path:
    """Resolve the pool JSON path from CampaignInput (with env override).

    The test-team-owned account pool lives inside the cloned project repo at
    ``${REPO_PATH}/${ui_accounts_relpath}``, i.e. the relpath is resolved under
    the project checkout root, NOT under ``${REPO_PATH}/${DATA_BASENAME}/``.
    This mirrors ``load_ui_accounts.sh``'s derivation (``POOL_FILE=
    "${REPO_PATH}/${UI_ACCOUNTS_RELPATH}"``) so the Python read of the pool
    stays in lock-step with the bash read. The relpath may itself begin with
    ``${DATA_BASENAME}/`` (e.g. ``ifp-data/ifp_users.json``), but that prefix
    must be part of the trigger value — it is no longer auto-prepended here.

    ``ACPX_UI_ACCOUNTS_PATH`` is honored as an absolute-path escape hatch for
    local tests; in production deployments the trigger drives the path.

    Precondition: only call this when :func:`_pool_is_configured` is True. The
    UI account pool is opt-in (an empty ``ui_accounts_relpath`` skips the
    flow), so an empty relpath reaching this point is a caller bug, not a
    runtime input — without the guard ``repo_path / ""`` would resolve to the
    project checkout root itself and fail later with a confusing
    "not a file" error.

    Extracted as a sync helper so :func:`build_executor_prompt` can read the
    pool inline (via :func:`shared.ui_accounts.load_pool`) without invoking
    the ``load_ui_account_pool`` activity recursively. Calling one activity
    from inside another binds the inner call to the outer's RetryPolicy,
    which would let a ``POOL_EMPTY`` (intentionally non-retryable on its own
    activity) inherit the outer's two-attempts policy. See round-2 review
    Critical-2.
    """
    override = os.environ.get("ACPX_UI_ACCOUNTS_PATH")
    if override:
        p = Path(override)
        if not p.is_absolute():
            raise_app_error(
                AcpxErrorType.INVALID_REPO_PATH,
                f"ACPX_UI_ACCOUNTS_PATH must be absolute, got {override!r}",
            )
        return p
    if not camp.ui_accounts_relpath:
        raise_app_error(
            AcpxErrorType.INVARIANT_VIOLATION,
            "_resolve_pool_path called with empty ui_accounts_relpath; the UI "
            "account pool is opt-in and callers must gate on "
            "_pool_is_configured()",
        )
    repo_path = Path(camp.repo_parent_path.rstrip("/")) / camp.project
    return repo_path / camp.ui_accounts_relpath


@activity.defn(name="load_ui_account_pool")
async def load_ui_account_pool(camp: CampaignInput) -> UiAccountPoolInfo:
    """Parse the project's UI account JSON pool and return only its size.

    The legacy dispatcher's ``load_ui_accounts.sh`` divides the pool into
    per-IID slots; under Temporal that math moves into
    :func:`shared.ui_accounts.allocate_slots` (pure, deterministic) so the
    activity only returns a non-secret summary. Credentials stay worker-local
    and are read directly inside :func:`build_executor_prompt`.

    Opt-in: when ``ui_accounts_relpath`` is empty (and no ``ACPX_UI_ACCOUNTS_PATH``
    override), the deployment does not use UI test accounts, so this skips the
    read and reports an empty pool — mirroring ``dispatch_prepare_tick.sh`` §14,
    which skips ``load_ui_accounts.sh`` entirely and records ``POOL_SIZE=0`` when
    ``UI_ACCOUNTS_RELPATH`` is empty. Downstream, :func:`shared.ui_accounts.allocate_slots`
    hands out count-0 slots and :func:`build_executor_prompt` omits the prompt's
    ``# UI test accounts`` section.

    Args:
        camp: CampaignInput used to derive the pool path
            ``${REPO_PATH}/${ui_accounts_relpath}`` when the pool is
            configured. Must run after :func:`clone_or_pull_repo` so the
            repo is on disk.
    """
    if not _pool_is_configured(camp):
        return UiAccountPoolInfo(count=0)
    return UiAccountPoolInfo(count=len(load_pool(_resolve_pool_path(camp))))


# ---------------------------------------------------------------------------
# A4b — allocate_attempt_number
# ---------------------------------------------------------------------------


@activity.defn(name="allocate_attempt_number")
async def allocate_attempt_number(camp: CampaignInput, iid: int) -> int:
    """Allocate the next attempt number through the existing durable script.

    The previous Temporal PoC derived ``attempt_number`` from workflow-local
    retry counters, which reset when each Schedule firing created a fresh
    CampaignWorkflow execution. Reusing ``allocate_attempt.sh`` keeps the
    monotonic per-IID counter in the existing per-issue state file and preserves
    the legacy "dispatcher allocates once, executor only consumes" contract.
    """
    env = build_dispatcher_env(camp)
    env["IID"] = str(iid)
    res = await run_script("allocate_attempt.sh", env=env)
    if res.exit_code != 0:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"allocate_attempt.sh exit {res.exit_code}: {res.stderr[-500:]}",
        )
    value = res.stdout.strip().splitlines()[-1].strip()
    try:
        attempt_number = int(value)
    except ValueError:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"allocate_attempt.sh stdout did not end with an integer: {res.stdout!r}",
        )
    if attempt_number < 1:
        raise_app_error(
            AcpxErrorType.INVARIANT_VIOLATION,
            f"allocate_attempt.sh returned invalid attempt number {attempt_number}",
        )
    return attempt_number


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
    **inside this activity** by reading the project JSON pool from
    ``${REPO_PATH}/${ui_accounts_relpath}`` on the worker
    host, slicing by ``att.ui_account_index_start`` /
    ``att.ui_account_count``, and feeding legacy ``{"u": "...", "p": "..."}``
    JSON into the ``UI_ACCOUNTS=`` env var that ``build_prompt.sh`` reads.
    The calling workflow only passes integer slot indices — plaintext
    passwords never enter Temporal workflow history.

    Opt-in: a count-0 slot means either the deployment opted out of UI test
    accounts (empty ``ui_accounts_relpath`` → empty pool → count-0 slots) or
    this slot drew no credentials. In both cases skip the pool read and pass
    no ``UI_ACCOUNTS`` env var so ``build_prompt.sh`` omits the ``# UI test
    accounts`` section. This is behaviorally identical to the bash dispatcher:
    ``dispatch_prepare_tick.sh`` §18 assigns ``UI_ACCOUNTS_JSON="[]"`` to
    count-0 IIDs, and ``build_prompt.sh`` defaults ``ACCOUNT_COUNT=0`` and gates
    the section on ``[ "${ACCOUNT_COUNT}" -gt 0 ]`` — so both an empty ``"[]"``
    and an unset ``UI_ACCOUNTS`` produce the same omitted section.

    We call :func:`shared.ui_accounts.load_pool` directly (sync) rather than
    ``await load_ui_account_pool()`` because awaiting another ``@activity.defn``
    from inside an activity body executes it within the *current* activity's
    retry / heartbeat context, which would let a ``POOL_EMPTY`` raised by the
    inner call inherit this activity's RetryPolicy. See round-2 review
    Critical-2.
    """
    ui_accounts_json: str | None
    if att.ui_account_count == 0:
        ui_accounts_json = None
    else:
        pool = load_pool(_resolve_pool_path(camp))
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
                {"u": acc.username, "p": acc.password}
                for acc in slot_accounts
            ]
        )

    env = build_attempt_env(camp, att, ui_accounts_json=ui_accounts_json)
    paths = _derive_paths(camp, att)
    env.update(paths)

    # v2: inject the model resolved by resolve_model_tier in PREPARE so acpx
    # runs under it. An empty model_name means the model dimension is not in
    # use, and build_prompt.sh omits its `# Model tier` section.
    if att.model_name:
        env["MODEL_NAME"] = att.model_name
        env["MODEL_TIER"] = str(att.model_tier)

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
# A6a — mark_issue_doing
# ---------------------------------------------------------------------------


@activity.defn(name="mark_issue_doing")
async def mark_issue_doing(camp: CampaignInput, att: AttemptInput) -> None:
    """Transition the GitLab issue into the in-progress workflow state.

    This preserves the legacy Phase 4 label contract: entry labels such as
    ``todo`` / ``retry`` / ``new`` / ``continue`` / ``blocked`` are removed by
    ``set_issue_label.sh add doing`` before the attempt is allowed to run.
    Trigger ``require_labels`` are one-shot entry labels too, so matched labels
    are removed explicitly before adding ``doing``.
    """
    env = build_attempt_env(camp, att)
    env.update(_derive_paths(camp, att))

    current_labels = set(att.issue_labels)
    for label in camp.require_labels:
        if label not in current_labels:
            continue
        remove_res = await run_script(
            "set_issue_label.sh",
            env=env,
            args=("remove", label),
        )
        if remove_res.exit_code != 0:
            raise_app_error(
                AcpxErrorType.SUBPROCESS_FAILED,
                "set_issue_label.sh remove required label "
                f"{label!r} exit {remove_res.exit_code}: {remove_res.stderr[-500:]}",
            )

    res = await run_script("set_issue_label.sh", env=env, args=("add", "doing"))
    if res.exit_code != 0:
        raise_app_error(
            AcpxErrorType.SUBPROCESS_FAILED,
            f"set_issue_label.sh add doing exit {res.exit_code}: {res.stderr[-500:]}",
        )


# ---------------------------------------------------------------------------
# A6b — record_attempt_outcome
# ---------------------------------------------------------------------------


@activity.defn(name="record_attempt_outcome")
async def record_attempt_outcome(
    camp: CampaignInput,
    att: AttemptInput,
    outcome: AttemptOutcome,
    final_status: str,
    tick_seq: int,
    consume_retry: bool = True,
) -> int:
    """Persist terminal attempt status into the existing per-issue state file.

    Temporal history is the durable scheduler record, but the legacy scripts
    still rely on ``allocate_attempt.sh``'s ``state.json`` for monotonic attempt
    allocation. Keeping terminal status and retry budget in the same file lets
    fresh Schedule firings honor ``blocked_cooldown_ticks`` and
    ``blocked_retry_limit`` without storing secrets in workflow history.

    Returns the post-write retry_count.
    """
    state_path = _issue_state_path(camp, att.iid)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state = _read_issue_disk_state(camp, att.iid)
    retry_count = int(state.get("retry_count", 0) or 0)

    # v2 statuses are per-side: blocked_cc / blocked_dispatcher / failed_cc /
    # failed_dispatcher. Both blocked_* and failed_* consume retry budget;
    # blocked_* additionally parks the IID at this tick for the cooldown clock.
    is_blocked = final_status.startswith("blocked")
    is_failed = final_status.startswith("failed")
    if final_status == "done":
        retry_count = 0
        blocked_at_tick: int | None = None
    elif (is_blocked or is_failed) and consume_retry:
        retry_count += 1
        blocked_at_tick = tick_seq if is_blocked else None
    elif is_blocked:
        blocked_at_tick = tick_seq
    else:
        # timeout parks the IID and does not consume retry budget.
        blocked_at_tick = None

    state.update(
        {
            "iid": att.iid,
            "status": final_status,
            "mode": outcome.mode_actual,
            "attempts_total": max(
                int(state.get("attempts_total", 0) or 0),
                att.attempt_number,
            ),
            "latest_attempt_number": att.attempt_number,
            "latest_attempt_dir": str(state_path.parent),
            "retry_count": retry_count,
            "block_reason": outcome.block_reason or None,
            "commit_sha": outcome.commit_sha or None,
            "merge_request_url": outcome.merge_request_url or None,
            "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
    )
    if blocked_at_tick is None:
        state.pop("blocked_at_tick", None)
    else:
        state["blocked_at_tick"] = blocked_at_tick

    tmp = state_path.with_name(f".{state_path.name}.tmp")
    tmp.write_text(
        json.dumps(state, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    tmp.replace(state_path)
    return retry_count


# ---------------------------------------------------------------------------
# A6c — resolve_and_stamp_model_tier (§6 model upgrade, in PREPARE)
# ---------------------------------------------------------------------------

# Hard-trigger statuses (§6): a CC-side re-arm raises the model tier. The
# dispatcher-side blocked_dispatcher / failed_dispatcher are deliberately
# excluded — raising the model never helps an infrastructure failure. Stored as
# the Python enum values (underscored); the prior status read from state.json
# uses the same values (record_attempt_outcome writes them).
_MODEL_HARD_TRIGGER_STATUSES: Final[frozenset[str]] = frozenset(
    {"blocked_cc", "timeout", "failed_cc"}
)


def _resolve_model_decision(
    labels: tuple[str, ...],
    prior_status: str,
    continue_count: int,
    model_tiers: tuple[str, ...],
    upgrade_continue_threshold: int,
) -> dict[str, object]:
    """Pure model-tier decision (§6) — the Python twin of
    ``_dispatch_lib.sh::resolve_model_tier``.

    UPGRADE? = hard ∪ soft:
        hard: ``prior_status`` ∈ { blocked_cc, timeout, failed_cc }.
        soft: ``quality:low`` present ∨ ``continue_count >= threshold``
              (threshold > 0) ∨ an automated quality score below threshold
              (a black box — NOT implemented here; the hook is left as a
              documented placeholder so a future scorer can OR into ``soft``).
    A capped tier (already the highest model) stays at max even when UPGRADE?
    fires; when capped and ``quality:low`` is present it is still consumed (it
    can do no further work, so it must not linger as noise). A brand-new issue
    with no model label resolves to TIER_0 and the caller stamps the lowest
    ``model:{tier}`` on first PREPARE — soft/hard triggers do NOT raise the tier
    on that first stamp; they act only once a model label already exists.

    Returns a dict with the same keys the bash helper emits.
    """
    n = len(model_tiers)
    # Current tier = HIGHEST-ranked model:{name} label present whose name is in
    # model_tiers (defensive against config drift that leaves >1 model label).
    # A label naming a tier outside model_tiers (e.g. model_tiers shortened) is
    # ignored, so found_tier is always in [0, n-1].
    found_indices = [
        model_tiers.index(label[len("model:"):])
        for label in labels
        if label.startswith("model:") and label[len("model:"):] in model_tiers
    ]
    found_tier: int | None = max(found_indices) if found_indices else None
    has_model_label = found_tier is not None
    # Clamp current_tier into [0, n-1] so a stale/out-of-range label can never
    # index model_tiers out of bounds at model_name resolution.
    current_tier = min(max(found_tier, 0), n - 1) if found_tier is not None else 0

    hard = prior_status in _MODEL_HARD_TRIGGER_STATUSES
    soft = ("quality:low" in labels) or (
        upgrade_continue_threshold > 0 and continue_count >= upgrade_continue_threshold
    )
    want_upgrade = hard or soft

    # §6: a brand-new issue (no model label yet) MUST be stamped at the lowest
    # tier on first PREPARE — soft/hard triggers only raise the tier once the
    # issue already carries a model label. So an upgrade requires has_model_label.
    raw_target = (
        current_tier + 1
        if (has_model_label and want_upgrade and current_tier < n - 1)
        else current_tier
    )
    target_tier = min(max(raw_target, 0), n - 1)
    upgraded = target_tier > current_tier
    model_name = model_tiers[target_tier]
    has_quality_low = "quality:low" in labels
    at_cap = current_tier >= n - 1
    return {
        "current_tier": current_tier,
        "has_model_label": has_model_label,
        "target_tier": target_tier,
        "model_name": model_name,
        "model_label": f"model:{model_name}",
        "upgrade": upgraded,
        "hard_trigger": hard,
        "soft_trigger": soft,
        # quality:low is one-shot — consume it when an upgrade landed OR when the
        # tier is already capped (it can do no further work, so it must not
        # linger as permanent noise). NOT consumed when there is still headroom
        # but no upgrade fired this round.
        "consume_quality_low": has_quality_low and (upgraded or at_cap),
    }


@activity.defn(name="resolve_and_stamp_model_tier")
async def resolve_and_stamp_model_tier(
    camp: CampaignInput, att: AttemptInput
) -> tuple[str, int]:
    """Resolve this attempt's model tier (§6), stamp the resolved
    ``model:{tier}`` label (and consume ``quality:low`` on an upgrade), persist
    the resolved tier + ``continue_count`` into the per-issue state cache, and
    return ``(model_name, model_tier)`` for injection into build_prompt.

    Called by the CampaignWorkflow in PREPARE, AFTER ``mark_issue_doing`` (which
    never clears the orthogonal model dimension) and BEFORE
    ``build_executor_prompt`` + the child spawn. The label is the source of
    truth; the state.json mirror only feeds the next tick's soft-trigger read.
    """
    env = build_attempt_env(camp, att)
    env.update(_derive_paths(camp, att))

    state = _read_issue_disk_state(camp, att.iid)
    prior_status = str(state.get("status", "") or "")
    # in_progress is a mid-flight marker, never a prior outcome.
    if prior_status == "in_progress":
        prior_status = ""
    prior_continue_count = int(state.get("continue_count", 0) or 0)
    # A continue-mode re-arm counts toward the soft trigger's accumulation.
    continue_count_now = prior_continue_count + (1 if att.mode == "continue" else 0)

    decision = _resolve_model_decision(
        labels=att.issue_labels,
        prior_status=prior_status,
        continue_count=continue_count_now,
        model_tiers=camp.model_tiers,
        upgrade_continue_threshold=camp.model_upgrade_continue_threshold,
    )
    model_name = str(decision["model_name"])
    target_tier = int(decision["target_tier"])  # type: ignore[arg-type]
    model_label = str(decision["model_label"])

    # Stamp the resolved model:{tier} when it changed (upgrade) or when the
    # issue has no model label yet (first PREPARE → lowest tier). The single
    # `add` removes the other model:{tier} labels via the model-dimension
    # exclusivity in set_issue_label.sh, leaving every work label untouched.
    if decision["upgrade"] or not decision["has_model_label"]:
        res = await run_script(
            "set_issue_label.sh", env=env, args=("add", model_label)
        )
        if res.exit_code != 0:
            LOG.warning(
                "iid=%d model label add %s failed (non-fatal): %s",
                att.iid,
                model_label,
                res.stderr[-300:],
            )

    # quality:low is one-shot — drop it once an upgrade it triggered has landed.
    if decision["consume_quality_low"]:
        res = await run_script(
            "set_issue_label.sh", env=env, args=("remove", "quality:low")
        )
        if res.exit_code != 0:
            LOG.warning(
                "iid=%d quality:low removal failed (non-fatal): %s",
                att.iid,
                res.stderr[-300:],
            )

    # Persist the resolved tier + continue accumulation into the state cache so
    # the NEXT tick's soft-trigger read sees them. The label remains the source
    # of truth; this is only the dispatcher progress mirror.
    state_path = _issue_state_path(camp, att.iid)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state.update(
        {
            "model_tier": target_tier,
            "model_name": model_name,
            "continue_count": continue_count_now,
        }
    )
    tmp = state_path.with_name(f".{state_path.name}.tmp")
    tmp.write_text(
        json.dumps(state, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    tmp.replace(state_path)

    return (model_name, target_tier)


@activity.defn(name="bump_campaign_tick_seq")
async def bump_campaign_tick_seq(camp: CampaignInput) -> int:
    """Atomically increment and return the campaign-level monotonic tick number.

    ``blocked_cooldown_ticks`` measures elapsed *scheduled wake-ups*: a blocked
    IID must sit out N ticks before it is re-dispatched. The cooldown gate in
    :class:`CampaignWorkflow` therefore needs a tick number that survives across
    Schedule firings. But the Temporal integration starts one fresh workflow
    *execution* per tick (see ``CampaignInput.ticks_before_continue_as_new``),
    so an in-memory counter always reads 1 and the cooldown would compare
    ``1 - blocked_at_tick(=1) == 0`` forever — silently disabling blocked-retry.

    This activity mirrors the legacy dispatcher's persisted
    ``campaign_state.json.tick_seq`` (``dispatch_prepare_tick.sh``:
    ``tick_seq: ((.tick_seq // 0) + 1)``): read the prior value from a
    dispatcher-level JSON file, increment, write back atomically, return the new
    value. ``ScheduleOverlapPolicy.BUFFER_ONE`` guarantees ticks never overlap,
    so no inter-tick lock is required. Must run after ``clone_or_pull_repo`` so
    the dispatcher directory under ``${REPO_PATH}`` exists. The caller schedules
    this with ``maximum_attempts=1`` (no activity-level retry), so the only
    double-increment window is a worker crash after the atomic ``tmp.replace``
    but before the result is acked, which forces a workflow-task replay that
    re-runs the activity. That is harmless: the counter stays monotonic, so the
    cooldown clock merely advances slightly faster — it never stalls.
    """
    path = _campaign_tick_path(camp)
    path.parent.mkdir(parents=True, exist_ok=True)
    prior = 0
    try:
        prior = int(
            json.loads(path.read_text(encoding="utf-8")).get("tick_seq", 0) or 0
        )
    except (OSError, json.JSONDecodeError, ValueError, TypeError):
        prior = 0
    new_seq = prior + 1
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(
        json.dumps({"tick_seq": new_seq}, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    tmp.replace(path)
    return new_seq


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
    "allocate_attempt_number",
    "bump_campaign_tick_seq",
    "clone_or_pull_repo",
    "ensure_workflow_labels",
    "load_ui_account_pool",
    "mark_issue_doing",
    "prepare_attempt_worktree",
    "record_attempt_outcome",
    "reconcile_gitlab",
    "resolve_and_stamp_model_tier",
    "self_heal_safety_bin",
]
