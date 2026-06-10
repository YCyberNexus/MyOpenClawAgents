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

import re
from dataclasses import dataclass
from typing import Literal


# Mirrors the bash dispatcher's defense-in-depth check on relative-path
# trigger fields (UI_ACCOUNTS_RELPATH / PRECHECK_RELPATH) and the charset rule
# of MODEL_SETTINGS_DIR. Keep the regex anchored at both ends so a single bad
# character anywhere in the path rejects the whole value (the bash version
# uses case patterns to the same effect).
_SAFE_PATH_CHARS_RE = re.compile(r"^[A-Za-z0-9_./-]+$")

# Each model tier name becomes the GitLab label ``model:<name>``; restrict it
# to label-safe characters (mirrors dispatch_prepare_tick.sh's model_tiers
# validation). Anchored at both ends so a bad character anywhere rejects it.
_MODEL_TIER_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def _validate_relpath(value: str, field_name: str) -> None:
    """Reject paths that would let a relpath trigger field escape ${REPO_PATH}.

    Shared by ``ui_accounts_relpath`` and ``precheck_relpath`` — both are
    resolved under the project checkout root ``${REPO_PATH}`` (NOT under
    ``${REPO_PATH}/${DATA_BASENAME}/``), so these rules guard against escaping
    that root. ``field_name`` selects the error prefix
    (``invalid_ui_accounts_relpath`` / ``invalid_precheck_relpath``), which
    must mirror the bash dispatcher's abort strings verbatim so operators
    recognize them across the migration.

    Same rules the legacy ``load_ui_accounts.sh`` enforces (exit code 16) and
    ``dispatch_prepare_tick.sh`` enforces for ``precheck_relpath``:
    non-empty, not absolute, no ``.`` / ``..`` segments, no whitespace,
    characters limited to ``[A-Za-z0-9_./-]``. The dispatcher-side
    validation here is the first line of defense; the bash script still
    re-validates so a manually-invoked script can't bypass the rule either.

    Strictness note: this Python validator is slightly stricter than the
    bash ``case`` patterns. Bash's pattern set does NOT explicitly reject
    trailing slash (``foo/``) or doubled slashes (``foo//bar``) — those
    would slip through and then fail later at ``[ ! -f "${POOL_FILE}" ]``.
    The Python ``split("/")`` walk rejects empty segments, so the same
    inputs fail loudly at validation time instead of producing a confusing
    "pool file missing" message. The extra strictness is a deliberate
    defense-in-depth tightening, not a contract divergence.
    """
    prefix = f"invalid_{field_name}"
    if not value:
        raise ValueError(f"{prefix}: must not be empty")
    if value.startswith("/"):
        raise ValueError(
            f"{prefix}: must be relative, got '{value}'"
        )
    segments = value.split("/")
    if any(seg in (".", "..") or seg == "" for seg in segments):
        raise ValueError(
            f"{prefix}: must not contain '.' / '..' / empty "
            f"segments, got '{value}'"
        )
    if not _SAFE_PATH_CHARS_RE.fullmatch(value):
        raise ValueError(
            f"{prefix}: characters limited to [A-Za-z0-9_./-], "
            f"got '{value}'"
        )


def _validate_model_settings_dir(value: str) -> None:
    """Validate the ``model_settings_dir`` trigger field (absolute directory).

    Mirrors the bash dispatcher's trigger-parse validation in
    ``dispatch_prepare_tick.sh`` (abort prefix ``invalid_model_settings_dir``):
    must be an absolute path, must not be exactly ``/``, no ``.`` / ``..``
    path segments, no whitespace, characters limited to ``[A-Za-z0-9_./-]``.
    The bash side folds dot-segments / whitespace / charset into one case
    pattern with one message; that message is mirrored verbatim here.
    """
    if value == "/":
        raise ValueError("invalid_model_settings_dir: must not be /")
    if not value.startswith("/"):
        raise ValueError("invalid_model_settings_dir: must be an absolute path")
    # value.split("/") on an absolute path yields a leading "" segment, which
    # is expected; only literal "." / ".." segments are rejected. Whitespace
    # and out-of-charset characters share the bash side's combined message.
    segments = value.split("/")
    if (
        any(seg in (".", "..") for seg in segments)
        or any(ch in value for ch in ("\n", "\r", "\t", " "))
        or not _SAFE_PATH_CHARS_RE.fullmatch(value)
    ):
        raise ValueError(
            "invalid_model_settings_dir: dot segments, whitespace, or "
            "unsupported characters"
        )

# Status enums kept as ``Literal`` aliases so JSON round-trips as plain strings
# while ``mypy --strict`` still catches typos. Mirrors the dispatch SKILL's
# ``state_schema.md`` §Possible status values table.
AttemptStatus = Literal[
    "in_progress",         # mid-flight; only used inside the IssueAttemptWorkflow body
    "done",                # MR created; `pr` label REPLACES `done`
    "blocked_cc",          # CC-side retryable failure; consumes one of `blocked_retry_limit`
    "blocked_dispatcher",  # dispatcher-side retryable failure (prep / spawn / stuck)
    "failed_cc",           # CC-side terminal; or `retry_count > blocked_retry_limit` from blocked_cc
    "failed_dispatcher",   # dispatcher-side terminal; `retry_count > blocked_retry_limit` from blocked_dispatcher
    "timeout",             # acpx wall-clock cap exceeded; partial work pushed, no MR
    "no_changes",          # legacy compact-reply value; normalized to `blocked_cc` by validator
]

# Wire-format mapping between the Python status enum (underscored, mypy-friendly)
# and the GitLab work label (hyphenated). The label is the source of truth; the
# Python enum is the in-process representation. ``timeout`` / ``done`` /
# ``in_progress`` / ``no_changes`` have no per-side hyphen and map 1:1.
STATUS_TO_LABEL: dict[str, str] = {
    "blocked_cc": "blocked-cc",
    "blocked_dispatcher": "blocked-dispatcher",
    "failed_cc": "failed-cc",
    "failed_dispatcher": "failed-dispatcher",
    "timeout": "timeout",
}

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
    # Relative path of the test-team-owned UI account pool JSON file,
    # resolved under the project checkout root ${REPO_PATH}/. Mirrors trigger
    # field `ui_accounts_relpath`, which is **opt-in with no default**: the
    # empty string means "this deployment does not use UI test accounts".
    # In that mode the whole pool flow is skipped — ``load_ui_account_pool``
    # returns an empty pool, ``allocate_slots`` hands out count-0 slots, and
    # ``build_executor_prompt`` omits the prompt's ``# UI test accounts``
    # section — matching the LLM/bash dispatcher exactly (see
    # ``scripts/dispatch_prepare_tick.sh`` §14 + ``build_prompt.sh``). The
    # carry-forward semantics the bash dispatcher gets from persisted
    # ``campaign_state.json`` are provided here by Temporal's Schedule input.
    ui_accounts_relpath: str = ""
    # Relative path of the project-team-owned environment-precheck manifest,
    # resolved under the project checkout root ${REPO_PATH}/ (same resolution
    # and validation rules as `ui_accounts_relpath`). Mirrors trigger field
    # `precheck_relpath`, which is **opt-in with no default**: the empty string
    # means "this deployment does not run the environment precheck" and the
    # whole §16b-equivalent gate is skipped. The carry-forward semantics the
    # bash dispatcher gets from persisted ``campaign_state.json`` are provided
    # here by Temporal's Schedule input (every firing re-delivers the full
    # input). See ``references/precheck_manifest.md``.
    precheck_relpath: str = ""
    max_concurrent_subagents: int = 1
    max_accounts_per_issue: int = 14
    # The two timeout fields below use the sentinel value ``0`` to mean
    # "derive from acpx_timeout_seconds". __post_init__ fills them in so all
    # downstream readers (workflows, schedule, validation) see the resolved
    # value regardless of whether the caller passed it explicitly.
    #   run_timeout_seconds  ← acpx_timeout_seconds + 120
    #   stuck_after_minutes  ← ceil(run_timeout_seconds / 60) + 30
    # This mirrors the bash dispatcher's per-tick defaulting in
    # ``scripts/dispatch_prepare_tick.sh`` (see references/trigger_command.md).
    stuck_after_minutes: int = 0                  # derived; see __post_init__
    run_timeout_seconds: int = 0                  # derived; see __post_init__
    acpx_timeout_seconds: int = 18000             # 300 min / 5 h
    kill_subagent_on_terminal: bool = True
    issue_iids_whitelist: tuple[int, ...] = ()    # tuple (frozen-friendly)
    require_labels: tuple[str, ...] = ()
    require_labels_match: LabelMatch = "or"

    # ── v2 model-tier dimension (§6) ────────────────────────────────────────
    # model_tiers: ordered model identifiers from lowest (TIER_0, the default
    # for a new issue) to the capped highest. Each name N maps to the GitLab
    # label ``model:N``. Defaults to the 3-tier example flash → pro → max.
    # model_upgrade_continue_threshold: the soft-trigger ``continue``
    # accumulation count N at/above which resolve_model_tier raises the tier.
    model_tiers: tuple[str, ...] = ("flash", "pro", "max")
    model_upgrade_continue_threshold: int = 2
    # model_settings_dir: absolute path to the directory holding the per-tier
    # Claude Code settings files (`<tier>-settings.json`). When configured, the
    # resolved model tier selects `${model_name}-settings.json`, which the
    # `apply_model_settings` activity copies to
    # ${WORKTREE_DIR}/.claude/settings.json so `acpx claude exec` actually runs
    # on the tier's model. Empty (the default) = legacy behavior: no copy, the
    # tier is only a prompt-text hint, and effective tiers = the full
    # model_tiers list. The bash dispatcher's **per-tick** semantics (omitting
    # the field on a tick reverts that tick to legacy, no carry-forward
    # restore) are natural under Temporal: every Schedule firing re-delivers
    # the complete input and there is no persisted-state restore at all.
    # Supersedes the removed `claude_settings_path` single fixed-file override.
    model_settings_dir: str = ""
    # effective_model_tiers: the EFFECTIVE upgrade ladder for THIS tick — the
    # ordered subset of model_tiers whose `<tier>-settings.json` exists under
    # model_settings_dir (tier auto-discovery). NOT an operator/trigger field:
    # the CampaignWorkflow overwrites it every tick via dataclasses.replace
    # after the `derive_effective_tiers` activity runs, so every downstream
    # activity argument carries the same per-tick value (reconcile's integer
    # model_tier index and resolve_model_tier's ladder consume it; the FULL
    # model_tiers list keeps feeding ensure_labels.sh / set_issue_label.sh).
    # Empty (the default) = not yet derived → consumers fall back to
    # model_tiers.
    effective_model_tiers: tuple[str, ...] = ()

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

    def __post_init__(self) -> None:
        # Fill derived defaults for the timeout chain so callers only need to
        # pass ``acpx_timeout_seconds`` to retune the whole chain. ``frozen=True``
        # forbids normal attribute assignment, so we use the documented
        # ``object.__setattr__`` escape hatch. Idempotent: when this object is
        # rehydrated from JSON (Temporal data converter) the previously derived
        # non-zero values are kept as-is, so derivation never runs twice with
        # different inputs.
        if self.run_timeout_seconds == 0:
            object.__setattr__(
                self, "run_timeout_seconds", self.acpx_timeout_seconds + 120
            )
        if self.stuck_after_minutes == 0:
            # Ceiling division: (n + 59) // 60 == math.ceil(n / 60) for n > 0.
            object.__setattr__(
                self,
                "stuck_after_minutes",
                (self.run_timeout_seconds + 59) // 60 + 30,
            )

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
        if len(self.model_tiers) < 1:
            raise ValueError("invalid_model_tiers: must list at least one model")
        if any(not _MODEL_TIER_NAME_RE.fullmatch(name) for name in self.model_tiers):
            raise ValueError(
                "invalid_model_tiers: tier names limited to [A-Za-z0-9_.-]"
            )
        if self.model_upgrade_continue_threshold < 0:
            raise ValueError(
                "invalid_model_upgrade_continue_threshold: must be a non-negative integer"
            )
        # UI account pool is opt-in: an empty ``ui_accounts_relpath`` means the
        # deployment does not use UI test accounts, so the whole pool flow is
        # skipped downstream and there is nothing to validate. Only enforce the
        # relative-path safety rules when a value is actually configured.
        if self.ui_accounts_relpath:
            _validate_relpath(self.ui_accounts_relpath, "ui_accounts_relpath")
        # Environment precheck is opt-in the same way: empty = skipped.
        if self.precheck_relpath:
            _validate_relpath(self.precheck_relpath, "precheck_relpath")
        # model_settings_dir is opt-in: empty = legacy behavior (no settings
        # copy, effective = full). Validated with the bash dispatcher's
        # absolute-path rules when configured.
        if self.model_settings_dir:
            _validate_model_settings_dir(self.model_settings_dir)
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

    # v2 model tier resolved by ``resolve_model_tier`` in PREPARE, before the
    # attempt starts (§6). ``model_name`` is the element of the trigger's
    # ordered model list this attempt runs under; ``model_tier`` is its 0-based
    # index. Injected into build_prompt.sh as MODEL_NAME / MODEL_TIER so acpx
    # runs under the resolved model. Empty ``model_name`` (the default) means
    # the model dimension is not in use and build_prompt omits its section.
    model_name: str = ""
    model_tier: int = 0


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
    is_closed_on_gitlab: bool       # hard terminal — never schedule
    has_pr: bool                    # `pr` present → completed (v2: pr REPLACES done)
    needs_continue: bool            # opened + has `continue`/`contiune` → reviewer resume
    user_reopened: bool             # opened + missing `pr` + no `failed-*/blocked-*/continue`
    has_timeout: bool               # opened + has `timeout` label → parked, no auto-retry
    has_blocked_cc: bool            # `blocked-cc` present (CC-side retryable failure)
    has_blocked_dispatcher: bool    # `blocked-dispatcher` present (dispatcher-side retryable failure)
    has_failed_cc: bool             # `failed-cc` present (CC-side terminal)
    has_failed_dispatcher: bool     # `failed-dispatcher` present (dispatcher-side terminal)
    has_retry: bool
    model_tier: int                 # current model:{tier} as 0-based index into the EFFECTIVE tier
                                    # ladder (effective_model_tiers, falling back to model_tiers when
                                    # auto-discovery is off); no matching label → 0
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
    """One entry from the project's UI account JSON pool
    (``${REPO_PATH}/${ui_accounts_relpath}``)."""

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
    # v2: failed split by attribution side. blocked stays a single bucket
    # (cc + dispatcher) — the per-side distinction lives on the live label.
    failed_cc_iids: tuple[int, ...]
    failed_dispatcher_iids: tuple[int, ...]
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
    failed_cc_iids: tuple[int, ...]
    failed_dispatcher_iids: tuple[int, ...]
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
    "STATUS_TO_LABEL",
    "UiAccount",
    "UiAccountPoolInfo",
    "UiAccountSlot",
]
