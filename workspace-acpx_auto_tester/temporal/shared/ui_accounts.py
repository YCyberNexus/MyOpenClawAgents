"""UI account pool: load + slot allocation + workflow-side semaphore.

The system under test logs out an account when it logs in twice, so every
concurrent acpx subagent must hold a distinct credential. The OpenClaw
dispatcher allocated accounts per tick via ``load_ui_accounts.sh``; under
Temporal we move slot allocation into workflow code so the assignment is
deterministic + persisted in event history.

Public surface:

* :func:`load_pool` — parses the test-team-owned JSON pool file (default
  path ``${REPO_PATH}/${DATA_BASENAME}/ifp-common/ifp_users.json``;
  override via the trigger's ``ui_accounts_relpath``). Called by the
  ``load_ui_account_pool`` activity (file I/O is non-deterministic and
  forbidden from workflow code).
* :func:`allocate_slots` — pure function: ``(pool_size, max_concurrent_subagents,
  max_accounts_per_issue) -> list[(index_start, count)]``. Safe to call from
  workflow code.
* :class:`AccountSemaphore` — workflow-side bookkeeping. Acquires return the
  exact ``(index_start, count)`` tuple to bind to one IID; the workflow stores
  the binding so callback-side drain releases the right slot.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .errors import AcpxErrorType, raise_app_error
from .types import UiAccount


# ---------------------------------------------------------------------------
# Pool loading (activity-side only — uses real filesystem)
# ---------------------------------------------------------------------------


def load_pool(config_path: str | Path) -> tuple[UiAccount, ...]:
    """Parse the test-team-owned JSON pool file into :class:`UiAccount` entries.

    File format (mirrors ``load_ui_accounts.sh`` parsing):
    ``[{"username": "F100001", "password": "123456", "name": "..."}, ...]``.
    Only ``username`` / ``password`` are consumed; extra keys are ignored.

    Args:
        config_path: absolute path to the pool JSON. The caller composes this
            as ``${REPO_PATH}/${DATA_BASENAME}/${ui_accounts_relpath}``
            (default subpath ``ifp-common/ifp_users.json``).

    Returns:
        Tuple of accounts in JSON-array order. Index in the tuple is the
        ``ui_account_index_start`` referenced by allocations.

    Raises:
        ApplicationError(type=pool_empty): when the file is missing,
            unreadable, malformed, has the wrong top-level shape, contains
            entries that fail the same checks the legacy bash script runs
            (missing/empty username/password, colon in username, newline in
            either field), or has zero valid entries. The bash script
            distinguishes exit codes 10/11/12; here all of them collapse to
            ``pool_empty`` because the Temporal taxonomy already marks this
            type non-retryable and the message text carries the specifics.
    """
    p = Path(config_path)
    try:
        raw = p.read_text(encoding="utf-8")
    except OSError as exc:
        raise_app_error(
            AcpxErrorType.POOL_EMPTY,
            f"could not read UI account pool at {p}: {exc}",
        )

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise_app_error(
            AcpxErrorType.POOL_EMPTY,
            f"UI account pool at {p} is not valid JSON: {exc}",
        )

    if not isinstance(parsed, list):
        raise_app_error(
            AcpxErrorType.POOL_EMPTY,
            f"UI account pool at {p}: top-level JSON must be an array",
        )

    accounts: list[UiAccount] = []
    for i, entry in enumerate(parsed):
        if not isinstance(entry, dict):
            raise_app_error(
                AcpxErrorType.POOL_EMPTY,
                f"UI account pool at {p}: entry {i} must be an object",
            )
        username = entry.get("username")
        password = entry.get("password")
        if username is None or password is None:
            missing = [k for k in ("username", "password") if entry.get(k) is None]
            raise_app_error(
                AcpxErrorType.POOL_EMPTY,
                f"UI account pool at {p}: entry {i} missing key(s) {missing}",
            )
        if not isinstance(username, str) or not isinstance(password, str):
            raise_app_error(
                AcpxErrorType.POOL_EMPTY,
                f"UI account pool at {p}: entry {i} username/password must be "
                f"strings, got {type(username).__name__}/{type(password).__name__}",
            )
        if not username or not password:
            raise_app_error(
                AcpxErrorType.POOL_EMPTY,
                f"UI account pool at {p}: entry {i} has empty username/password",
            )
        if ":" in username or any(ch in username for ch in ("\n", "\r")):
            raise_app_error(
                AcpxErrorType.POOL_EMPTY,
                f"UI account pool at {p}: entry {i} username must not contain "
                "colon or newline",
            )
        if any(ch in password for ch in ("\n", "\r")):
            raise_app_error(
                AcpxErrorType.POOL_EMPTY,
                f"UI account pool at {p}: entry {i} password must not contain "
                "newline",
            )
        accounts.append(
            UiAccount(
                index=len(accounts),
                username=username,
                password=password,
            )
        )

    if not accounts:
        raise_app_error(
            AcpxErrorType.POOL_EMPTY,
            f"UI account pool at {p} has no entries",
        )
    return tuple(accounts)


# ---------------------------------------------------------------------------
# Slot allocation (pure — safe inside workflow code)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class _SlotPlan:
    """Per-slot (index_start, count) computed by :func:`allocate_slots`."""

    index_start: int
    count: int


def allocate_slots(
    pool_size: int,
    max_concurrent_subagents: int,
    max_accounts_per_issue: int,
) -> tuple[_SlotPlan, ...]:
    """Divide a pool of size ``pool_size`` into exactly ``max_concurrent_subagents``
    slots, front-loading the integer remainder onto the earliest slots, then
    cap each slot at ``max_accounts_per_issue``.

    Mirrors CLAUDE.md §Concurrency and UI-account allocation:

        "raw slot size = floor(pool_size / max_concurrent_subagents) with the
        integer remainder front-loaded onto the first slots, then each slot
        is capped by max_accounts_per_issue (e.g. default cap 14:
        pool=50, max=4 → 13,13,12,12; pool=40, max=1 → 14; pool=3, max=2 → 2,1)."

    Args:
        pool_size: total credentials available.
        max_concurrent_subagents: how many slots to divide the pool into.
        max_accounts_per_issue: per-slot upper bound (defaults to 14 upstream).

    Returns:
        Tuple of length ``max_concurrent_subagents`` describing each slot.

    Raises:
        ValueError: when inputs would violate the post-override invariants
            (mirrors the dispatcher's "pool_too_small" / "invalid_max_*"
            abort strings).
    """
    if max_concurrent_subagents < 1:
        raise ValueError("invalid_max_concurrent_subagents: must be >= 1")
    if max_accounts_per_issue < 1:
        raise ValueError("invalid_max_accounts_per_issue: must be >= 1")
    if pool_size < max_concurrent_subagents:
        raise ValueError(
            "ui_account_pool_too_small: "
            f"pool={pool_size} max_concurrent_subagents={max_concurrent_subagents}"
        )

    base = pool_size // max_concurrent_subagents
    remainder = pool_size % max_concurrent_subagents
    slots: list[_SlotPlan] = []
    cursor = 0
    for k in range(max_concurrent_subagents):
        raw = base + (1 if k < remainder else 0)
        capped = min(raw, max_accounts_per_issue)
        slots.append(_SlotPlan(index_start=cursor, count=capped))
        cursor += capped
    return tuple(slots)


# ---------------------------------------------------------------------------
# Workflow-side semaphore (deterministic inside workflow context)
# ---------------------------------------------------------------------------


class AccountSemaphore:
    """In-workflow bookkeeping for the UI account pool.

    Why not :class:`asyncio.Semaphore`?
        ``asyncio.Semaphore`` works inside Temporal workflow context, but it
        doesn't tell us *which* slot was acquired. We need the slot index
        (not just permission to proceed) so that the per-IID activities can
        be passed the right ``ui_account_index_start`` + ``ui_account_count``.

    Why not block on acquire?
        The CampaignWorkflow already enforces the single-batch-in-flight
        invariant by counting ``pending_subagents``; it never tries to start
        more children than slots exist. So :meth:`acquire` is non-blocking —
        it just returns the next free slot or raises if none.

    Usage::

        sem = AccountSemaphore(slots)              # at top of tick
        ...
        slot = sem.acquire_for(iid)                # before start_child_workflow
        ...
        sem.release(iid)                           # after child returns

    The state map (``iid -> _SlotPlan``) is persisted naturally in the
    workflow's event history because Python attribute writes inside workflow
    code are deterministic.
    """

    def __init__(self, slots: tuple[_SlotPlan, ...]) -> None:
        self._slots: list[_SlotPlan] = list(slots)
        self._held: dict[int, _SlotPlan] = {}
        self._free: list[_SlotPlan] = list(slots)

    @property
    def slot_count(self) -> int:
        return len(self._slots)

    @property
    def in_use_count(self) -> int:
        return len(self._held)

    def acquire_for(self, iid: int) -> _SlotPlan:
        """Reserve the next free slot for ``iid``. Idempotent: if ``iid``
        already holds a slot, return that slot.

        Raises:
            RuntimeError: when no free slot exists. Mirrors the
                ``single-batch-in-flight invariant`` from SOUL.md — callers
                must check :attr:`in_use_count` before acquiring.
        """
        existing = self._held.get(iid)
        if existing is not None:
            return existing
        if not self._free:
            raise RuntimeError(
                f"AccountSemaphore exhausted: cannot acquire for iid={iid}; "
                f"in_use={self.in_use_count} slot_count={self.slot_count}"
            )
        slot = self._free.pop(0)
        self._held[iid] = slot
        return slot

    def release(self, iid: int) -> None:
        """Return ``iid``'s slot to the free pool. No-op if ``iid`` does not
        currently hold a slot (idempotent for crash-recovery)."""
        slot = self._held.pop(iid, None)
        if slot is not None:
            self._free.append(slot)

    def held_by(self, iid: int) -> _SlotPlan | None:
        return self._held.get(iid)


__all__ = [
    "AccountSemaphore",
    "allocate_slots",
    "load_pool",
]
