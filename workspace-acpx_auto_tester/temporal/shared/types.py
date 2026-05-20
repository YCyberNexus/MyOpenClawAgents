"""Frozen dataclasses shared between workflows, activities, and CLI.

Why ``@dataclass(frozen=True)`` instead of pydantic models:
    The Temporal Python SDK's built-in JSON data converter serializes
    ``dataclasses.dataclass`` instances natively. Pydantic v2 needs a custom
    data converter to round-trip cleanly through workflow boundaries. The
    pydantic dependency in ``pyproject.toml`` is reserved for CLI-side
    validation of inbound JSON (``client.py`` parses operator-supplied
    ``--input-file`` JSON), not for workflow payloads.

Determinism:
    These objects are constructed inside workflow code; do not put
    non-deterministic factory defaults here (no ``datetime.now`` /
    ``uuid.uuid4`` ``default_factory``). Workflow code that needs a wall-clock
    timestamp must use ``workflow.now()`` instead.

Mirrors:
    * ``CampaignInput`` mirrors RUN_SCHEDULED_ISSUE_CAMPAIGN trigger fields
      (see ``references/trigger_command.md``).
    * ``AttemptOutcome`` mirrors the §Compact Subagent Reply schema
      (see ``references/state_schema.md``).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

# Status enums kept as ``Literal`` aliases so JSON round-trips as plain strings
# while ``mypy --strict`` still catches typos. Mirrors the dispatch SKILL's
# ``state_schema.md`` §Possible status values table.
AttemptStatus = Literal[
    "in_progress",  # mid-flight; only used inside the IssueAttemptWorkflow body
    "done",         # MR created, both `done` and `pr` labels added
    "blocked",      # retryable failure; consumes one of `blocked_retry_limit`
    "failed",       # non-recoverable, or `retry_count > blocked_retry_limit`
    "timeout",      # acpx wall-clock cap exceeded; partial work pushed, no MR
    "no_changes",   # legacy compact-reply value; normalized to `blocked` by validator
]

CampaignStatus = Literal["running", "waiting_for_callbacks", "completed"]

AttemptMode = Literal["fresh", "continue"]

MrAction = Literal["created", "rotated", "none"]

LabelMatch = Literal["or", "and"]


# ---------------------------------------------------------------------------
# Campaign-level inputs (the post-override "tick parameters")
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CampaignInput:
    """Mirror of the RUN_SCHEDULED_ISSUE_CAMPAIGN trigger field set.

    Defaults follow ``references/trigger_command.md`` "Optional inputs" /
    "Trigger-input override" tables. Required fields have no default so a
    misconfigured Schedule fails loudly at Workflow start.
    """

    # ── Required (from trigger) ─────────────────────────────────────────────
    project: str
    group: str
    branch: str                       # integration / target branch (typically "master")
    dev_branch: str                   # clean baseline (typically "dev"); set equal to branch to disable
    issue_min_iid: int                # inclusive
    issue_max_iid: int                # inclusive
    hourly_issue_quota: int           # per-tick LAUNCH count (async-callback semantics)
    max_runtime_minutes: int          # tick wall-clock budget (only the orchestrator phase)
    blocked_retry_limit: int          # how many blocked outcomes consume the retry budget
    blocked_cooldown_ticks: int       # scheduled-wakes a blocked IID waits before retry

    # ── Optional with default (mirror state_schema fresh-init values) ───────
    repo_parent_path: str = "/data"               # ${REPO_PATH} = repo_parent_path/<project>
    result_basename: str = "ifp-result"
    data_basename: str = "ifp-data"
    max_concurrent_subagents: int = 1
    max_accounts_per_issue: int = 14
    stuck_after_minutes: int = 330
    run_timeout_seconds: int = 18120              # acpx_timeout_seconds + 120
    acpx_timeout_seconds: int = 18000             # 300 min / 5 h
    kill_subagent_on_terminal: bool = True
    issue_iids_whitelist: tuple[int, ...] = ()    # tuple (frozen-friendly)
    require_labels: tuple[str, ...] = ()
    require_labels_match: LabelMatch = "or"

    # ── Workflow-internal tunables (not in the legacy trigger) ──────────────
    ticks_before_continue_as_new: int = 200
    """Reserved for a future long-lived entity workflow mode.

    The current Schedule integration starts one CampaignWorkflow per tick, so
    event history is naturally bounded by that tick.
    """

    # Secrets are NOT inputs. ``gitlab_token`` is sourced from the worker's
    # env (forwarded to ``glab_auth.sh`` by ``activities/subprocess.py``).
    # Putting it on ``CampaignInput`` would persist it into Temporal event
    # history.

    def validated(self) -> "CampaignInput":
        """Return ``self`` unchanged after enforcing the same invariants the
        legacy ``dispatch_prepare_tick.sh`` enforces in shell.

        Raises:
            ValueError: with a message that mirrors the dispatcher's abort
                strings (e.g. ``"invalid_max_concurrent_subagents"``) so
                operators recognize them across the migration.
        """
        if self.issue_min_iid < 1:
            raise ValueError("issue_min_iid must be >= 1")
        if self.issue_max_iid < self.issue_min_iid:
            raise ValueError("issue_max_iid must be >= issue_min_iid")
        if self.hourly_issue_quota < 0:
            raise ValueError("hourly_issue_quota must be >= 0")
        if self.max_runtime_minutes < 1:
            raise ValueError("max_runtime_minutes must be >= 1")
        if self.blocked_retry_limit < 0:
            raise ValueError("blocked_retry_limit must be >= 0")
        if self.blocked_cooldown_ticks < 0:
            raise ValueError("blocked_cooldown_ticks must be >= 0")
        if self.max_concurrent_subagents < 1:
            raise ValueError("invalid_max_concurrent_subagents: must be >= 1")
        if self.max_accounts_per_issue < 1:
            raise ValueError("invalid_max_accounts_per_issue: must be >= 1")
        if self.stuck_after_minutes < 5:
            raise ValueError("invalid_stuck_after_minutes: must be >= 5")
        if self.acpx_timeout_seconds < 60:
            raise ValueError("invalid_acpx_timeout_seconds: must be >= 60")
        if self.run_timeout_seconds < 60:
            raise ValueError("invalid_run_timeout_seconds: must be >= 60")
        if self.run_timeout_seconds < self.acpx_timeout_seconds + 120:
            raise ValueError("run_timeout_seconds_below_acpx_timeout_seconds_plus_120")
        if self.require_labels_match not in ("or", "and"):
            raise ValueError("invalid_require_labels_match")
        return self


# ---------------------------------------------------------------------------
# Per-attempt inputs (one per IssueAttemptWorkflow execution)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class AttemptInput:
    """One IssueAttemptWorkflow execution = one attempt of one IID.

    The campaign workflow allocates `attempt_number` monotonically per IID
    before starting the child; the child does not increment a counter (avoids
    double-counting on workflow restart).
    """

    project: str
    group: str
    iid: int
    attempt_number: int
    mode: AttemptMode                # "fresh" or "continue"
    ui_account_index_start: int      # 0-based offset into config/ui_accounts.env
    ui_account_count: int            # post-cap slot size for THIS attempt
    repo_parent_path: str
    result_basename: str
    data_basename: str
    branch: str
    dev_branch: str
    work_branch: str                 # f"issue/{iid}-auto-fix"
    acpx_timeout_seconds: int

    # Issue metadata read from glab at Phase 4 prep (was previously embedded
    # into the executor prompt via build_prompt.sh). Carried through here so
    # the activities don't re-fetch on every step.
    issue_title: str = ""
    issue_url: str = ""
    issue_labels: tuple[str, ...] = ()


# ---------------------------------------------------------------------------
# Per-attempt outcome (returned by IssueAttemptWorkflow.run)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class AttemptOutcome:
    """Mirror of the §Compact Subagent Reply schema. The IssueAttemptWorkflow
    return value replaces the per-attempt JSON line the subagent used to emit.
    """

    iid: int
    attempt_number: int
    status: AttemptStatus
    mode_actual: AttemptMode
    work_branch: str
    local_branch: str
    commit_sha: str = ""
    merge_request_url: str = ""
    mr_action: MrAction = "none"
    wiki_url: str = ""
    labels_added: tuple[str, ...] = ()
    labels_removed: tuple[str, ...] = ()
    summary_posted: bool = False
    block_reason: str = ""
    log_dir: str = ""


# ---------------------------------------------------------------------------
# Reconcile evidence (returned by reconcile_gitlab activity)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class IssueLiveState:
    """Reconciled live state for one IID from GitLab (the source of truth).

    Mirrors the per-IID digest produced by ``scripts/reconcile.sh`` evidence
    file. Boolean signals are the ones the campaign body actually branches on.
    """

    iid: int
    title: str
    is_closed_on_gitlab: bool   # hard terminal — never schedule
    has_done_pr: bool           # both `done` and `pr` present → completed
    needs_continue: bool        # opened + has `continue`/`contiune` → reviewer resume
    user_reopened: bool         # opened + missing `done`+`pr` + no `failed/blocked/continue`
    has_timeout: bool           # opened + has `timeout` label → parked, no auto-retry
    has_blocked: bool
    has_failed: bool
    has_retry: bool
    labels: tuple[str, ...]
    retry_count: int = 0
    blocked_at_tick: int = -1


@dataclass(frozen=True)
class ReconcileEvidence:
    """Snapshot of all IIDs in the queried range at the moment reconcile ran.

    The ``CampaignWorkflow`` body keeps the most recent evidence as a local
    variable (not as workflow state) and re-fetches every tick.
    """

    queried_min_iid: int
    queried_max_iid: int
    queried_at_ms: int          # workflow.now().timestamp() * 1000 at activity start
    per_iid: tuple[IssueLiveState, ...]


# ---------------------------------------------------------------------------
# Intermediate dataclasses returned by individual activities
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class UiAccount:
    """One row of config/ui_accounts.env."""

    index: int                  # 0-based; stable across reads (file order)
    username: str
    password: str


@dataclass(frozen=True)
class UiAccountPoolInfo:
    """Non-secret summary of the UI account pool.

    Workflows must not receive usernames/passwords because Activity return
    values are stored in Temporal history. Activities that need credentials
    read the pool directly on the worker host.
    """

    count: int


@dataclass(frozen=True)
class UiAccountSlot:
    """Per-IID slot computed by ``shared/ui_accounts.py``."""

    iid: int
    index_start: int            # 0-based offset into the pool
    count: int                  # post-cap slot size


@dataclass(frozen=True)
class PreparedAttempt:
    """Return value of ``prepare_attempt_worktree`` activity."""

    iid: int
    attempt_number: int
    mode_actual: AttemptMode                # may have downgraded continue → fresh
    mode_downgraded_from: AttemptMode | None
    worktree_dir: str                       # absolute path
    log_dir: str                            # absolute path
    output_dir: str                         # absolute path
    local_attempt_branch: str               # e.g. "issue/14-auto-fix-att002"


@dataclass(frozen=True)
class AcpxResult:
    """Return value of ``run_claude_code_attempt`` activity."""

    exit_code: int                          # 0 success; 124/137 wall-clock timeout
    timed_out: bool                         # True iff exit in {124, 137}
    log_dir: str                            # absolute path; for downstream evidence


@dataclass(frozen=True)
class StagedDiff:
    """Return value of ``stage_and_guard`` activity. Empty diff is non-retryable."""

    has_changes: bool
    changed_files: int
    diff_summary: str                       # short text from `git diff --stat`


@dataclass(frozen=True)
class CommitPushResult:
    """Return value of ``commit_and_push`` activity."""

    commit_sha: str
    local_branch: str
    pushed_to: str                          # remote branch (work_branch)


@dataclass(frozen=True)
class MrResult:
    """Return value of ``create_or_rotate_mr`` activity."""

    url: str
    action: MrAction                        # "created" / "rotated"
    prior_mrs_closed: tuple[str, ...] = ()  # URLs of MRs closed before creating the new one


@dataclass(frozen=True)
class LabelsState:
    """Live label state returned by label-mutation activities for audit."""

    labels: tuple[str, ...]


# ---------------------------------------------------------------------------
# Campaign-level summary (returned by CampaignWorkflow.run)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CampaignSummary:
    """Returned by ``CampaignWorkflow.run`` when the campaign reaches the
    end of one scheduled tick.

    For a campaign that's still rolling, operators normally inspect the same
    fields through ``workflow.query`` ``pending_status`` while the tick is
    active, and use Schedule history for past tick summaries.
    """

    final_tick_seq: int
    completed_iids: tuple[int, ...]
    failed_iids: tuple[int, ...]
    timeout_iids: tuple[int, ...]
    blocked_iids: tuple[int, ...]
    pending_iids: tuple[int, ...] = ()


# ---------------------------------------------------------------------------
# CampaignWorkflow snapshot (returned by `pending_status` query)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CampaignSnapshot:
    """Point-in-time view returned by ``CampaignWorkflow.pending_status``.

    Workflow queries must return JSON-serializable data; a dataclass works.
    """

    tick_seq: int
    pending_iids: tuple[int, ...]
    active_ui_accounts_in_use: int
    completed_iids: tuple[int, ...]
    failed_iids: tuple[int, ...]
    timeout_iids: tuple[int, ...]
    blocked_iids: tuple[int, ...]
    last_reconcile_at_ms: int = 0


# ---------------------------------------------------------------------------
# IssueAttemptWorkflow input wrapper
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class IssueAttemptWorkflowInput:
    """Input for :class:`IssueAttemptWorkflow.run`. Bundles the parent
    :class:`CampaignInput` (so leaf activities can resolve paths) and the
    per-attempt :class:`AttemptInput`.

    Two reasons we wrap them instead of passing two args:
        * ``temporal workflow start --input-file`` accepts one JSON value.
        * Workflow queries / event-history reading is simpler with a single
          input object.
    """

    campaign: CampaignInput
    attempt: AttemptInput


# Re-export everything so callers can ``from acpx_temporal.shared.types import *``
# without importing each name. (mypy --strict still resolves them by name.)
__all__ = [
    "IssueAttemptWorkflowInput",
    "AttemptInput",
    "AttemptMode",
    "AttemptOutcome",
    "AttemptStatus",
    "AcpxResult",
    "CampaignInput",
    "CampaignSnapshot",
    "CampaignStatus",
    "CampaignSummary",
    "CommitPushResult",
    "IssueLiveState",
    "LabelMatch",
    "LabelsState",
    "MrAction",
    "MrResult",
    "PreparedAttempt",
    "ReconcileEvidence",
    "StagedDiff",
    "UiAccount",
    "UiAccountPoolInfo",
    "UiAccountSlot",
]
