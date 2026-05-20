"""CampaignWorkflow — the entity-style top-level workflow.

Driven by a Temporal Schedule (cron / interval) with
``ScheduleOverlapPolicy.BUFFER_ONE`` so overlapping ticks are queued, not
parallel — mirroring the legacy dispatcher's flock contract.

Each tick:

1. ``reconcile_gitlab`` activity → live label snapshot (source of truth).
2. Classify IIDs from evidence: completed / blocked / failed / timeout / open.
3. Form a batch of up to ``max_concurrent_subagents`` open IIDs the campaign
   has launch quota for, subject to ``hourly_issue_quota``,
   ``blocked_cooldown_ticks``, ``issue_iids_whitelist``, ``require_labels``.
4. For each batch IID:

   * acquire one UI account slot from :class:`AccountSemaphore`;
   * run ``prepare_attempt_worktree`` + ``build_executor_prompt`` activities;
   * start :class:`IssueAttemptWorkflow` as a child with
     ``WorkflowIDReusePolicy.REJECT_DUPLICATE`` (same IID never runs twice).

5. Await all children in this batch (single-batch invariant — no mid-batch
   top-up). Drain semaphore on each child completion.
6. After every ``ticks_before_continue_as_new`` iterations,
   :meth:`workflow.continue_as_new` to keep event history bounded.

This file intentionally implements the **core loop only** — the legacy
backlog-first ordering / cooldown promotion / launch-retry are simplified
to "form one batch, await it, return". A reviewer comment block under
``# TODO(post-PoC):`` highlights what remains.
"""

from __future__ import annotations

import logging
from datetime import timedelta
from typing import Any

from temporalio import workflow
from temporalio.common import RetryPolicy, WorkflowIDReusePolicy
from temporalio.exceptions import ChildWorkflowError
from temporalio.workflow import ChildWorkflowCancellationType, ParentClosePolicy

with workflow.unsafe.imports_passed_through():
    from ..activities.orchestrator import (
        build_executor_prompt,
        clone_or_pull_repo,
        ensure_workflow_labels,
        load_ui_account_pool,
        prepare_attempt_worktree,
        reconcile_gitlab,
    )
    from ..shared.types import (
        AttemptInput,
        AttemptOutcome,
        CampaignInput,
        CampaignSnapshot,
        CampaignSummary,
        IssueAttemptWorkflowInput,
        IssueLiveState,
        ReconcileEvidence,
    )
    from ..shared.ui_accounts import AccountSemaphore, allocate_slots
    from .issue_attempt import IssueAttemptWorkflow

LOG = logging.getLogger("acpx_temporal.workflows.campaign")


# Standard activity retry policies (mirrors plan §Activity registry).
_RP_2_ATTEMPTS = RetryPolicy(
    initial_interval=timedelta(seconds=2),
    backoff_coefficient=1.5,
    maximum_interval=timedelta(seconds=30),
    maximum_attempts=2,
)
_RP_3_ATTEMPTS = RetryPolicy(
    initial_interval=timedelta(seconds=2),
    backoff_coefficient=1.5,
    maximum_interval=timedelta(seconds=30),
    maximum_attempts=3,
)


@workflow.defn(name="CampaignWorkflow")
class CampaignWorkflow:
    """Entity-style long-lived workflow. See module docstring."""

    def __init__(self) -> None:
        self._tick_seq: int = 0
        self._paused: bool = False
        self._last_reconcile_ms: int = 0
        # IID classification — re-derived from reconcile each tick.
        self._completed: set[int] = set()
        self._failed: set[int] = set()
        self._timeout: set[int] = set()
        self._blocked: set[int] = set()
        self._pending: set[int] = set()
        # Retry budget bookkeeping (replaces issue_state.retry_count + blocked_at_tick).
        # Lives only within one tick execution — see TODO(post-PoC) in `run`.
        self._retry_count: dict[int, int] = {}
        self._blocked_at_tick: dict[int, int] = {}

    # ── Signals ─────────────────────────────────────────────────────────────

    @workflow.signal
    def pause(self) -> None:
        self._paused = True

    @workflow.signal
    def resume(self) -> None:
        self._paused = False

    # ── Queries ─────────────────────────────────────────────────────────────

    @workflow.query
    def pending_status(self) -> CampaignSnapshot:
        return CampaignSnapshot(
            tick_seq=self._tick_seq,
            pending_iids=tuple(sorted(self._pending)),
            active_ui_accounts_in_use=0,  # filled in tick body when sem is alive
            completed_iids=tuple(sorted(self._completed)),
            failed_iids=tuple(sorted(self._failed)),
            timeout_iids=tuple(sorted(self._timeout)),
            blocked_iids=tuple(sorted(self._blocked)),
            last_reconcile_at_ms=self._last_reconcile_ms,
        )

    # ── Main run ────────────────────────────────────────────────────────────

    @workflow.run
    async def run(self, inp: CampaignInput) -> CampaignSummary:
        """One Schedule firing = one execution of this method = one tick.

        Each tick:
        1. ensure labels + clone-or-pull (idempotent bootstrap);
        2. reconcile GitLab → classify IIDs;
        3. early-return if all IIDs in range are completed;
        4. form a batch and run it to completion;
        5. return a summary.

        Cross-tick state (retry_count, blocked_at_tick) is **not** persisted
        in this workflow instance because the next tick is a fresh execution.
        v1 derives status from reconcile labels each tick — ``blocked``/
        ``failed``/``timeout`` are GitLab labels, so the source of truth
        re-classifies us automatically. The ``_retry_count`` /
        ``_blocked_at_tick`` instance attributes still exist but only matter
        within the current tick's ``_run_batch`` for the promotion-to-failed
        decision after the children of THIS batch return.

        TODO(post-PoC): persist ``retry_count`` across ticks. Options:
        Workflow Search Attributes on the IssueAttemptWorkflow id-chain, or
        a sidecar GitLab label like ``retries:N``. CLAUDE.md §Source of
        Truth Policy mandates GitLab is canonical, so the label-based path
        is cleanest.
        """
        inp = inp.validated()
        self._tick_seq += 1
        LOG.info("CampaignWorkflow tick=%d project=%s", self._tick_seq, inp.project)

        # Honour pause signal between Schedule firings — the operator can
        # pause the Schedule itself OR signal an in-flight CampaignWorkflow.
        if self._paused:
            LOG.info("CampaignWorkflow paused; returning empty summary")
            return self._final_summary()

        # ── Bootstrap (idempotent) ──────────────────────────────────────────
        await workflow.execute_activity(
            ensure_workflow_labels,
            args=[inp],
            start_to_close_timeout=timedelta(seconds=20),
            retry_policy=_RP_2_ATTEMPTS,
        )
        await workflow.execute_activity(
            clone_or_pull_repo,
            args=[inp],
            start_to_close_timeout=timedelta(seconds=300),
            heartbeat_timeout=timedelta(seconds=60),
            retry_policy=_RP_2_ATTEMPTS,
        )

        # ── Reconcile + classify ────────────────────────────────────────────
        evidence = await self._reconcile(inp)
        self._classify(evidence)

        # ── Batch + run ─────────────────────────────────────────────────────
        # "Nothing to do this tick" = no IID survives the eligibility scan.
        # We do not track a separate "campaign completed" terminal because
        # GitLab labels are the source of truth: a fully-completed campaign
        # produces an empty batch every tick, and the Schedule can be paused
        # by the operator. (TODO post-PoC: emit a Workflow Search Attribute
        # so operators can observe "campaign done" from the Web UI.)
        batch = self._select_batch(inp, evidence)
        if batch:
            await self._run_batch(inp, batch)

        return self._final_summary()

    # ── Helpers ─────────────────────────────────────────────────────────────

    async def _reconcile(self, inp: CampaignInput) -> ReconcileEvidence:
        ev = await workflow.execute_activity(
            reconcile_gitlab,
            args=[inp],
            start_to_close_timeout=timedelta(seconds=60),
            retry_policy=_RP_3_ATTEMPTS,
        )
        self._last_reconcile_ms = ev.queried_at_ms
        return ev

    def _classify(self, ev: ReconcileEvidence) -> None:
        """Re-derive IID buckets from reconcile evidence — GitLab labels are
        the source of truth, disk cache is gone.

        Ordering note (per reviewer I2): ``needs_continue`` wins over
        ``has_failed`` / ``has_blocked`` / ``has_timeout`` — a reviewer who
        relabels a closed-failed issue with ``continue`` is explicitly asking
        the agent to resume that IID. Same precedence rule lives in the
        legacy reconcile.sh / dispatch_prepare_tick.sh.
        """
        self._completed.clear()
        self._failed.clear()
        self._timeout.clear()
        self._blocked.clear()
        self._pending.clear()

        for entry in ev.per_iid:
            if entry.is_closed_on_gitlab:
                self._completed.add(entry.iid)
            elif entry.needs_continue:
                # Reviewer asked to resume — wins over every other label state.
                self._pending.add(entry.iid)
            elif entry.has_done_pr:
                self._completed.add(entry.iid)
            elif entry.has_timeout:
                self._timeout.add(entry.iid)
            elif entry.has_failed:
                self._failed.add(entry.iid)
            elif entry.has_blocked and not entry.has_retry:
                self._blocked.add(entry.iid)
            else:
                self._pending.add(entry.iid)

    def _select_batch(
        self, inp: CampaignInput, ev: ReconcileEvidence
    ) -> list[IssueLiveState]:
        """Pick up to ``max_concurrent_subagents`` IIDs to run this tick.

        Order:
            1. Continue-mode IIDs (reviewer asked to resume).
            2. Reopened IIDs (lost their done+pr labels).
            3. Fresh new IIDs (ascending from ``next_new_iid``).
            4. Blocked-with-cooldown-elapsed IIDs (only after no backlog).
        """
        # TODO(post-PoC): blocked_cooldown_ticks / retry budget promotion to
        # `failed` once retry_count > blocked_retry_limit. v0 keeps it simple.
        candidates: list[IssueLiveState] = []
        seen: set[int] = set()

        def admit(entry: IssueLiveState) -> bool:
            if entry.iid in seen or entry.iid in self._completed:
                return False
            if not _whitelist_ok(entry, inp):
                return False
            if not _required_labels_ok(entry.labels, inp):
                return False
            seen.add(entry.iid)
            candidates.append(entry)
            return len(candidates) >= inp.max_concurrent_subagents

        # By-priority scan over evidence.
        for entry in ev.per_iid:
            if entry.needs_continue and admit(entry):
                return candidates
        for entry in ev.per_iid:
            if entry.user_reopened and admit(entry):
                return candidates
        for entry in sorted(ev.per_iid, key=lambda e: e.iid):
            if entry.iid in self._pending and admit(entry):
                return candidates

        return candidates

    async def _run_batch(
        self, inp: CampaignInput, batch: list[IssueLiveState]
    ) -> None:
        """Run one batch: prep + spawn N children, await all, drain semaphore.

        Single-batch-in-flight invariant: we always await every child handle
        before this method returns; the tick's `_classify` already accounts
        for any in-flight state from a prior tick.
        """
        # Discover pool size cheaply — we don't need passwords in workflow
        # context (those are a secret; activities read them on the worker
        # side). load_ui_account_pool returns the full pool; we only consult
        # its length here.
        pool = await workflow.execute_activity(
            load_ui_account_pool,
            start_to_close_timeout=timedelta(seconds=5),
            retry_policy=RetryPolicy(maximum_attempts=1),
        )
        pool_size = len(pool)
        slots = allocate_slots(
            pool_size=pool_size,
            max_concurrent_subagents=inp.max_concurrent_subagents,
            max_accounts_per_issue=inp.max_accounts_per_issue,
        )
        sem = AccountSemaphore(slots)

        # Prepare each IID sequentially (the legacy prepare_attempt.sh holds
        # repo.lock; concurrent invocations would serialize on bash flock).
        # Then start children with WAIT_CANCELLATION_COMPLETED so a tick
        # cancellation drains gracefully.
        child_handles: list[tuple[workflow.ChildWorkflowHandle[Any, AttemptOutcome], int]] = []

        for entry in batch:
            slot = sem.acquire_for(entry.iid)
            mode: str = "continue" if entry.needs_continue else "fresh"
            attempt_number = self._retry_count.get(entry.iid, 0) + 1

            att = AttemptInput(
                project=inp.project,
                group=inp.group,
                iid=entry.iid,
                attempt_number=attempt_number,
                mode=mode,  # type: ignore[arg-type]
                ui_account_index_start=slot.index_start,
                ui_account_count=slot.count,
                repo_parent_path=inp.repo_parent_path,
                result_basename=inp.result_basename,
                data_basename=inp.data_basename,
                branch=inp.branch,
                dev_branch=inp.dev_branch,
                work_branch=f"issue/{entry.iid}-auto-fix",
                acpx_timeout_seconds=inp.acpx_timeout_seconds,
                issue_title="",
                issue_url="",
                issue_labels=entry.labels,
            )

            await workflow.execute_activity(
                prepare_attempt_worktree,
                args=[inp, att],
                start_to_close_timeout=timedelta(seconds=60),
                retry_policy=_RP_2_ATTEMPTS,
            )

            # SECURITY: pass slot indices only — the build_executor_prompt
            # activity de-references passwords from the env-mounted pool on
            # the worker side, so plaintext credentials never enter
            # workflow event history.
            await workflow.execute_activity(
                build_executor_prompt,
                args=[inp, att],
                start_to_close_timeout=timedelta(seconds=30),
                retry_policy=_RP_2_ATTEMPTS,
            )

            # WorkflowIDReusePolicy.REJECT_DUPLICATE rejects any *existing*
            # workflow with the same id — including completed ones. To allow
            # retries (attempt 2 of the same IID) we embed attempt_number
            # into the id, so two distinct attempts are two distinct ids.
            # Same-attempt-double-spawn is impossible because Semaphore +
            # single-batch invariant guarantees we never run the same IID
            # twice in one tick.
            handle = await workflow.start_child_workflow(
                IssueAttemptWorkflow.run,
                args=[IssueAttemptWorkflowInput(campaign=inp, attempt=att)],
                id=f"issue:{inp.project}:{entry.iid}:att-{attempt_number:03d}",
                id_reuse_policy=WorkflowIDReusePolicy.REJECT_DUPLICATE,
                execution_timeout=timedelta(minutes=inp.stuck_after_minutes),
                parent_close_policy=ParentClosePolicy.ABANDON,
                cancellation_type=ChildWorkflowCancellationType.WAIT_CANCELLATION_COMPLETED,
                task_queue=workflow.info().task_queue,  # worktree affinity
            )
            child_handles.append((handle, entry.iid))

        # Await every child via ``.result()`` (the canonical Temporal Python
        # SDK accessor for child outcomes).
        for handle, iid in child_handles:
            try:
                outcome: AttemptOutcome = await handle.result()
            except ChildWorkflowError as cwe:
                LOG.warning("child workflow iid=%d failed: %s", iid, cwe)
                self._retry_count[iid] = self._retry_count.get(iid, 0) + 1
                self._blocked_at_tick[iid] = self._tick_seq
                sem.release(iid)
                continue

            sem.release(iid)
            if outcome.status == "done":
                self._completed.add(iid)
                self._retry_count.pop(iid, None)
                self._blocked_at_tick.pop(iid, None)
            elif outcome.status == "timeout":
                self._timeout.add(iid)
            elif outcome.status == "failed":
                self._failed.add(iid)
            else:  # blocked / no_changes (normalized to blocked)
                self._blocked.add(iid)
                self._retry_count[iid] = self._retry_count.get(iid, 0) + 1
                self._blocked_at_tick[iid] = self._tick_seq
                # Promote to failed when retry budget exhausted within this
                # tick. Cross-tick promotion would require persisted
                # retry_count (TODO post-PoC).
                if self._retry_count[iid] > inp.blocked_retry_limit:
                    LOG.info(
                        "iid=%d promoted blocked → failed (retry=%d > limit=%d)",
                        iid,
                        self._retry_count[iid],
                        inp.blocked_retry_limit,
                    )
                    self._blocked.discard(iid)
                    self._failed.add(iid)

    def _final_summary(self) -> CampaignSummary:
        return CampaignSummary(
            final_tick_seq=self._tick_seq,
            completed_iids=tuple(sorted(self._completed)),
            failed_iids=tuple(sorted(self._failed)),
            timeout_iids=tuple(sorted(self._timeout)),
            blocked_iids=tuple(sorted(self._blocked)),
            pending_iids=tuple(sorted(self._pending)),
        )


# ---------------------------------------------------------------------------
# Pure-function filters (safe inside workflow context)
# ---------------------------------------------------------------------------


def _whitelist_ok(entry: IssueLiveState, inp: CampaignInput) -> bool:
    if not inp.issue_iids_whitelist:
        return True
    return entry.iid in inp.issue_iids_whitelist


def _required_labels_ok(labels: tuple[str, ...], inp: CampaignInput) -> bool:
    if not inp.require_labels:
        return True
    label_set = set(labels)
    if inp.require_labels_match == "and":
        return all(req in label_set for req in inp.require_labels)
    return any(req in label_set for req in inp.require_labels)


__all__ = ["CampaignWorkflow"]
