"""Error taxonomy for activities and workflows.

Activities raise :class:`temporalio.exceptions.ApplicationError` with a
``type`` string drawn from :class:`AcpxErrorType`. The IssueAttemptWorkflow
catches by ``e.type`` to route between the FAIL flow, TIMEOUT flow, and
retry-by-cooldown path. Workflows do not raise these errors directly — they
catch them, translate into an :class:`AttemptOutcome`, and return cleanly.

The plan's §Activity registry pins which ``type`` strings are marked
``non_retryable`` per activity; this module's :func:`raise_app_error` helper
defers to that decision by accepting an explicit ``non_retryable`` flag.

Why ``ApplicationError``:
    Temporal differentiates retryable transient failures from terminal
    contract violations by the ``non_retryable`` flag on
    :class:`ApplicationError`. Setting ``non_retryable_error_types`` on the
    activity's ``RetryPolicy`` references these ``type`` strings exactly, so
    new error types must be added in both places.
"""

from __future__ import annotations

from enum import StrEnum
from typing import NoReturn

from temporalio.exceptions import ApplicationError


class AcpxErrorType(StrEnum):
    """Closed enum of error ``type`` strings used by acpx_auto_tester_temporal
    activities. The names mirror the migration plan §Activity registry rows;
    the wire string is the lowercase identifier (StrEnum default).
    """

    # ── Bootstrap / auth ────────────────────────────────────────────────────
    GLAB_AUTH_FAILED = "glab_auth_failed"
    INVALID_REPO_PATH = "invalid_repo_path"

    # ── Reconcile / labels ──────────────────────────────────────────────────
    GLAB_ISSUE_NOT_FOUND = "glab_issue_not_found"
    GLAB_WIKI_FORBIDDEN = "glab_wiki_forbidden"
    GITLAB_TRANSIENT = "gitlab_transient"  # retryable

    # ── UI account pool ─────────────────────────────────────────────────────
    POOL_EMPTY = "pool_empty"
    POOL_TOO_SMALL = "pool_too_small"

    # ── Worktree / prepare ──────────────────────────────────────────────────
    WORKTREE_LEASE_CONFLICT = "worktree_lease_conflict"
    DEV_BRANCH_MISSING = "dev_branch_missing"

    # ── acpx (Claude Code) ──────────────────────────────────────────────────
    ACPX_TIMED_OUT = "acpx_timed_out"     # exit 124/137 → TIMEOUT flow (non-retryable)
    ACPX_FAILED = "acpx_failed"           # any other non-zero exit (non-retryable)

    # ── stage / push ────────────────────────────────────────────────────────
    NO_CHANGES = "no_changes"             # stage produced empty diff (non-retryable)
    LEASE_CONFLICT = "lease_conflict"     # --force-with-lease rejected (non-retryable)
    PUSH_REJECTED = "push_rejected"       # protected branch / hook rejection (non-retryable)
    PROTECTED_BRANCH = "protected_branch"
    REF_NOT_FOUND = "ref_not_found"       # post_push_verify could not fetch remote ref

    # ── MR rotate (close-then-create is non-atomic) ─────────────────────────
    MR_ROTATE_FAILED = "mr_rotate_failed"  # always non-retryable

    # ── Generic ─────────────────────────────────────────────────────────────
    SUBPROCESS_FAILED = "subprocess_failed"  # unexpected non-zero from a leaf script
    INVARIANT_VIOLATION = "invariant_violation"


# The subset of ``AcpxErrorType`` values that MUST be marked non-retryable on
# every activity that can raise them. Used by ``shared/retry_policies.py``
# (added in Step 3) when building each activity's ``RetryPolicy``.
NON_RETRYABLE_ERROR_TYPES: frozenset[str] = frozenset(
    {
        AcpxErrorType.ACPX_TIMED_OUT,
        AcpxErrorType.ACPX_FAILED,
        AcpxErrorType.NO_CHANGES,
        AcpxErrorType.LEASE_CONFLICT,
        AcpxErrorType.PUSH_REJECTED,
        AcpxErrorType.PROTECTED_BRANCH,
        AcpxErrorType.REF_NOT_FOUND,
        AcpxErrorType.MR_ROTATE_FAILED,
        AcpxErrorType.GLAB_AUTH_FAILED,
        AcpxErrorType.GLAB_ISSUE_NOT_FOUND,
        AcpxErrorType.GLAB_WIKI_FORBIDDEN,
        AcpxErrorType.INVALID_REPO_PATH,
        AcpxErrorType.POOL_EMPTY,
        AcpxErrorType.POOL_TOO_SMALL,
        AcpxErrorType.WORKTREE_LEASE_CONFLICT,
        AcpxErrorType.DEV_BRANCH_MISSING,
        AcpxErrorType.INVARIANT_VIOLATION,
    }
)


def raise_app_error(
    error_type: AcpxErrorType,
    message: str,
    *,
    non_retryable: bool | None = None,
    details: tuple[object, ...] = (),
) -> NoReturn:
    """Raise an :class:`ApplicationError` tagged with ``error_type``.

    If ``non_retryable`` is omitted, it defaults to membership in
    :data:`NON_RETRYABLE_ERROR_TYPES` — so callers that omit the flag get the
    correct retry semantics automatically.

    Args:
        error_type: One of :class:`AcpxErrorType`. Determines the ``type``
            field on the raised :class:`ApplicationError`.
        message: Human-readable description; surfaced into ``block_reason``
            when the workflow catches.
        non_retryable: Optional override. Default = membership in
            :data:`NON_RETRYABLE_ERROR_TYPES`.
        details: Extra structured detail payloads attached to the exception
            (Temporal will serialize them into history).

    Raises:
        ApplicationError: Always — this function never returns.
    """
    if non_retryable is None:
        non_retryable = error_type in NON_RETRYABLE_ERROR_TYPES
    raise ApplicationError(
        message,
        *details,
        type=str(error_type),
        non_retryable=non_retryable,
    )


__all__ = [
    "AcpxErrorType",
    "NON_RETRYABLE_ERROR_TYPES",
    "raise_app_error",
]
