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
   * run ``prepare_attempt_worktree`` + ``mark_issue_doing`` +
     ``build_executor_prompt`` activities;
   * start :class:`IssueAttemptWorkflow` as a child with
     ``WorkflowIDReusePolicy.REJECT_DUPLICATE`` (same IID never runs twice).

5. Await all children in this batch (single-batch invariant — no mid-batch
   top-up). Drain semaphore on each child completion.
6. Persist per-IID terminal outcome into the existing issue state cache so
   later Schedule firings retain attempt numbering and blocked retry budget.
"""

from __future__ import annotations

import logging
from dataclasses import replace
from datetime import timedelta
from typing import Any

from temporalio import workflow
from temporalio.common import RetryPolicy, WorkflowIDReusePolicy
from temporalio.exceptions import ActivityError, ApplicationError, ChildWorkflowError
from temporalio.workflow import ChildWorkflowCancellationType, ParentClosePolicy

with workflow.unsafe.imports_passed_through():
    from ..activities.orchestrator import (
        allocate_attempt_number,
        build_executor_prompt,
        clone_or_pull_repo,
        ensure_workflow_labels,
        load_ui_account_pool,
        mark_issue_doing,
        prepare_attempt_worktree,
        record_attempt_outcome,
        reconcile_gitlab,
        self_heal_safety_bin,
    )
    from ..activities.leaf import sync_terminal_labels
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
        self._open: set[int] = set()
        # Temporal-owned equivalent of legacy pending_subagents: IIDs whose
        # child workflow has been started and not yet drained.
        self._pending: set[int] = set()
        self._active_ui_accounts_in_use: int = 0
        self._child_handles: dict[int, Any] = {}
        self._scope_min_iid: int | None = None
        self._scope_max_iid: int | None = None
        self._scope_iids_whitelist: tuple[int, ...] = ()
        self._scope_evicted_iids: set[int] = set()
        # Tick-local mirrors of retry bookkeeping. Cross-tick values are loaded
        # from per-issue state during reconcile.
        self._retry_count: dict[int, int] = {}
        self._blocked_at_tick: dict[int, int] = {}

    # ── Signals ─────────────────────────────────────────────────────────────

    @workflow.signal
    def pause(self) -> None:
        self._paused = True

    @workflow.signal
    def resume(self) -> None:
        self._paused = False

    @workflow.signal
    async def update_scope(
        self,
        issue_min_iid: int,
        issue_max_iid: int,
        issue_iids_whitelist: tuple[int, ...] = (),
    ) -> None:
        """Apply a new hard IID scope to already-running child workflows.

        Legacy scheduled ticks scope-evicted ``pending_subagents`` before the
        waiting-for-callbacks gate. Under Temporal, the pending set is the child
        workflow handles kept in this parent. A scope update signal gives the
        same control plane a way to cancel any in-flight child that no longer
        belongs to ``issue_iids ∩ [issue_min_iid, issue_max_iid]``.
        """
        if issue_min_iid < 1 or issue_max_iid < issue_min_iid:
            LOG.warning(
                "ignored invalid scope update min=%s max=%s",
                issue_min_iid,
                issue_max_iid,
            )
            return

        self._scope_min_iid = issue_min_iid
        self._scope_max_iid = issue_max_iid
        self._scope_iids_whitelist = tuple(sorted(set(issue_iids_whitelist)))

        for iid in tuple(sorted(self._pending)):
            if self._scope_contains_iid(iid):
                continue
            self._scope_evicted_iids.add(iid)
            handle = self._child_handles.get(iid)
            if handle is None:
                continue
            cancel = getattr(handle, "cancel", None)
            if cancel is None:
                LOG.warning("child handle for iid=%d has no cancel() method", iid)
                continue
            try:
                maybe_awaitable = cancel()
                if hasattr(maybe_awaitable, "__await__"):
                    await maybe_awaitable
            except Exception as exc:  # noqa: BLE001 - signal must not fail workflow
                LOG.warning("scope-evict cancel failed iid=%d: %s", iid, exc)

    # ── Queries ─────────────────────────────────────────────────────────────

    @workflow.query
    def pending_status(self) -> CampaignSnapshot:
        return CampaignSnapshot(
            tick_seq=self._tick_seq,
            pending_iids=tuple(sorted(self._pending)),
            active_ui_accounts_in_use=self._active_ui_accounts_in_use,
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

        GitLab labels remain the source of truth for issue workflow state.
        The existing per-issue ``state.json`` stores only counters GitLab
        labels do not encode: monotonic attempt number, retry_count, and
        blocked_at_tick.
        """
        inp = inp.validated()
        self._set_scope_from_input(inp)
        self._tick_seq += 1
        tick_started_at = workflow.now()
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
        # Restore +x on scripts/safety_bin/* before any acpx run. Equivalent
        # to dispatch_prepare_tick.sh's ensure_safety_bin_executable call;
        # without it a deployment that drops the mode bit blocks every
        # subsequent IssueAttemptWorkflow at run_acpx_attempt.sh's
        # `[ -x safety_bin/rm ]` fail-fast.
        await workflow.execute_activity(
            self_heal_safety_bin,
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=RetryPolicy(maximum_attempts=1),
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
        self._classify(inp, evidence)

        if workflow.now() - tick_started_at >= timedelta(minutes=inp.max_runtime_minutes):
            LOG.info(
                "CampaignWorkflow tick=%d exhausted max_runtime_minutes=%d before batching",
                self._tick_seq,
                inp.max_runtime_minutes,
            )
            return self._final_summary()

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

    def _classify(self, inp: CampaignInput, ev: ReconcileEvidence) -> None:
        """Re-derive IID buckets from reconcile evidence — GitLab labels are
        the source of truth; per-issue disk state only carries retry/cooldown
        counters that GitLab labels do not encode.

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
        self._open.clear()

        for entry in ev.per_iid:
            if entry.is_closed_on_gitlab:
                self._completed.add(entry.iid)
            elif entry.needs_continue:
                # Reviewer asked to resume — wins over every other label state.
                self._open.add(entry.iid)
            elif entry.has_done_pr:
                self._completed.add(entry.iid)
            elif entry.has_timeout and not entry.has_retry:
                self._timeout.add(entry.iid)
            elif entry.has_failed or entry.retry_count > inp.blocked_retry_limit:
                self._failed.add(entry.iid)
            elif entry.has_blocked and not entry.has_retry:
                self._blocked.add(entry.iid)
            else:
                self._open.add(entry.iid)

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
        candidates: list[IssueLiveState] = []
        seen: set[int] = set()
        limit = min(inp.max_concurrent_subagents, inp.hourly_issue_quota)
        if limit <= 0:
            return candidates

        def admit(entry: IssueLiveState) -> None:
            if len(candidates) >= limit:
                return
            if entry.iid in seen or entry.iid in self._completed or entry.iid in self._pending:
                return
            blocked_at = self._blocked_at_tick.get(entry.iid, entry.blocked_at_tick)
            if blocked_at >= 0:
                elapsed = self._tick_seq - blocked_at
                if elapsed < inp.blocked_cooldown_ticks:
                    return
            if not _whitelist_ok(entry, inp):
                return
            if not _required_labels_ok(entry.labels, inp):
                return
            seen.add(entry.iid)
            candidates.append(entry)
            return

        def collect_phase(entries: list[IssueLiveState]) -> bool:
            for entry in entries:
                admit(entry)
                if len(candidates) >= limit:
                    return True
            return False

        # By-priority scan over evidence.
        if collect_phase(
            [entry for entry in ev.per_iid if _attempt_mode_for_entry(entry) == "continue"]
        ):
            return candidates
        if collect_phase([entry for entry in ev.per_iid if entry.user_reopened]):
            return candidates
        if collect_phase(
            [entry for entry in sorted(ev.per_iid, key=lambda e: e.iid) if entry.iid in self._open]
        ):
            return candidates
        collect_phase(
            [entry for entry in sorted(ev.per_iid, key=lambda e: e.iid) if entry.iid in self._blocked]
        )

        return candidates

    async def _run_batch(
        self, inp: CampaignInput, batch: list[IssueLiveState]
    ) -> None:
        """Run one batch: prep + spawn N children, await all, drain semaphore.

        Single-batch-in-flight invariant: we always await every child handle
        before this method returns; the tick's `_classify` already accounts
        for any in-flight state from a prior tick.
        """
        # Discover pool size only. Account secrets stay worker-local and never
        # enter workflow history. The activity reads the test-team-owned JSON
        # pool inside the cloned project repo, so it must run after the
        # bootstrap clone_or_pull_repo activity above.
        pool_info = await workflow.execute_activity(
            load_ui_account_pool,
            args=[inp],
            start_to_close_timeout=timedelta(seconds=5),
            retry_policy=RetryPolicy(maximum_attempts=1),
        )
        pool_size = pool_info.count
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
        child_handles: list[
            tuple[
                workflow.ChildWorkflowHandle[Any, AttemptOutcome],
                int,
                AttemptInput,
                IssueLiveState,
            ]
        ] = []

        for entry in batch:
            slot = sem.acquire_for(entry.iid)
            self._active_ui_accounts_in_use = sem.in_use_count
            mode: str = _attempt_mode_for_entry(entry)
            try:
                attempt_number = await workflow.execute_activity(
                    allocate_attempt_number,
                    args=[inp, entry.iid],
                    start_to_close_timeout=timedelta(seconds=10),
                    retry_policy=RetryPolicy(maximum_attempts=1),
                )
            except ActivityError:
                sem.release(entry.iid)
                self._active_ui_accounts_in_use = sem.in_use_count
                raise

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
                issue_title=entry.title or f"issue-{entry.iid}",
                issue_url="",
                issue_labels=entry.labels,
            )

            try:
                prepared = await workflow.execute_activity(
                    prepare_attempt_worktree,
                    args=[inp, att],
                    start_to_close_timeout=timedelta(seconds=60),
                    retry_policy=_RP_2_ATTEMPTS,
                )
                if prepared.mode_actual != att.mode:
                    att = replace(att, mode=prepared.mode_actual)

                await workflow.execute_activity(
                    mark_issue_doing,
                    args=[inp, att],
                    start_to_close_timeout=timedelta(seconds=10),
                    retry_policy=RetryPolicy(maximum_attempts=1),
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
            except ActivityError as ae:
                sem.release(entry.iid)
                self._active_ui_accounts_in_use = sem.in_use_count
                await self._record_pre_child_blocked(
                    inp,
                    att,
                    entry,
                    "dispatcher prep failed: "
                    f"{_activity_error_message(ae, default=str(ae))}",
                )
                continue

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
            self._pending.add(entry.iid)
            self._child_handles[entry.iid] = handle
            child_handles.append((handle, entry.iid, att, entry))

        # Await every child via ``.result()`` (the canonical Temporal Python
        # SDK accessor for child outcomes).
        for handle, iid, att, entry in child_handles:
            try:
                outcome: AttemptOutcome = await handle.result()
            except ChildWorkflowError as cwe:
                LOG.warning("child workflow iid=%d failed: %s", iid, cwe)
                scope_evicted = iid in self._scope_evicted_iids
                self._open.discard(iid)
                self._pending.discard(iid)
                self._child_handles.pop(iid, None)
                if scope_evicted:
                    self._retry_count[iid] = entry.retry_count
                else:
                    self._retry_count[iid] = entry.retry_count + 1
                self._blocked_at_tick[iid] = self._tick_seq
                sem.release(iid)
                self._active_ui_accounts_in_use = sem.in_use_count
                final_status = (
                    "failed"
                    if (not scope_evicted and self._retry_count[iid] > inp.blocked_retry_limit)
                    else "blocked"
                )
                block_reason = (
                    "pending IID outside current trigger scope "
                    "issue_iids∩[issue_min_iid,issue_max_iid]"
                    if scope_evicted
                    else f"child workflow failed before returning outcome: {cwe}"
                )
                synthetic = AttemptOutcome(
                    iid=iid,
                    attempt_number=att.attempt_number,
                    status=final_status,  # type: ignore[arg-type]
                    mode_actual=att.mode,
                    work_branch=att.work_branch,
                    local_branch=f"{att.work_branch}-att{att.attempt_number:03d}",
                    block_reason=block_reason,
                )
                if final_status == "failed":
                    self._failed.add(iid)
                    self._blocked_at_tick.pop(iid, None)
                else:
                    self._blocked.add(iid)
                try:
                    await workflow.execute_activity(
                        sync_terminal_labels,
                        args=[inp, att, final_status],
                        start_to_close_timeout=timedelta(seconds=10),
                        retry_policy=RetryPolicy(maximum_attempts=1),
                    )
                except ActivityError as ae:
                    if scope_evicted:
                        synthetic = replace(
                            synthetic,
                            block_reason=(
                                synthetic.block_reason
                                + "; blocked label sync failed: "
                                f"{_activity_error_message(ae, default=str(ae))}"
                            ),
                        )
                    else:
                        LOG.warning(
                            "failed to sync %s label for failed child iid=%d",
                            final_status,
                            iid,
                        )
                await self._record_outcome(
                    inp,
                    att,
                    synthetic,
                    final_status,
                    consume_retry=not scope_evicted,
                )
                self._scope_evicted_iids.discard(iid)
                continue

            self._open.discard(iid)
            self._pending.discard(iid)
            self._child_handles.pop(iid, None)
            scope_evicted = iid in self._scope_evicted_iids
            sem.release(iid)
            self._active_ui_accounts_in_use = sem.in_use_count
            if scope_evicted:
                self._retry_count[iid] = entry.retry_count
                self._blocked_at_tick[iid] = self._tick_seq
                self._blocked.add(iid)
                block_reason = (
                    "pending IID outside current trigger scope "
                    "issue_iids∩[issue_min_iid,issue_max_iid]"
                )
                try:
                    await workflow.execute_activity(
                        sync_terminal_labels,
                        args=[inp, att, "blocked"],
                        start_to_close_timeout=timedelta(seconds=10),
                        retry_policy=RetryPolicy(maximum_attempts=1),
                    )
                except ActivityError as ae:
                    block_reason = (
                        block_reason
                        + "; blocked label sync failed: "
                        f"{_activity_error_message(ae, default=str(ae))}"
                    )
                synthetic = replace(
                    outcome,
                    status="blocked",
                    block_reason=block_reason,
                )
                await self._record_outcome(
                    inp,
                    att,
                    synthetic,
                    "blocked",
                    consume_retry=False,
                )
                self._scope_evicted_iids.discard(iid)
                continue
            self._scope_evicted_iids.discard(iid)
            if outcome.status == "done":
                self._completed.add(iid)
                self._retry_count.pop(iid, None)
                self._blocked_at_tick.pop(iid, None)
                await self._record_outcome(inp, att, outcome, "done")
            elif outcome.status == "timeout":
                self._timeout.add(iid)
                await self._record_outcome(inp, att, outcome, "timeout")
            elif outcome.status == "failed":
                self._failed.add(iid)
                await self._record_outcome(inp, att, outcome, "failed")
            else:  # blocked / no_changes (normalized to blocked)
                self._blocked.add(iid)
                self._retry_count[iid] = entry.retry_count + 1
                self._blocked_at_tick[iid] = self._tick_seq
                # Promote to failed when the persisted retry budget is exhausted.
                if self._retry_count[iid] > inp.blocked_retry_limit:
                    LOG.info(
                        "iid=%d promoted blocked → failed (retry=%d > limit=%d)",
                        iid,
                        self._retry_count[iid],
                        inp.blocked_retry_limit,
                    )
                    self._blocked.discard(iid)
                    self._failed.add(iid)
                    self._blocked_at_tick.pop(iid, None)
                    await workflow.execute_activity(
                        sync_terminal_labels,
                        args=[inp, att, "failed"],
                        start_to_close_timeout=timedelta(seconds=10),
                        retry_policy=RetryPolicy(maximum_attempts=1),
                    )
                    await self._record_outcome(inp, att, outcome, "failed")
                else:
                    await self._record_outcome(inp, att, outcome, "blocked")

    async def _record_outcome(
        self,
        inp: CampaignInput,
        att: AttemptInput,
        outcome: AttemptOutcome,
        final_status: str,
        *,
        consume_retry: bool = True,
    ) -> int:
        return await workflow.execute_activity(
            record_attempt_outcome,
            args=[inp, att, outcome, final_status, self._tick_seq, consume_retry],
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=RetryPolicy(maximum_attempts=1),
        )

    async def _record_pre_child_blocked(
        self,
        inp: CampaignInput,
        att: AttemptInput,
        entry: IssueLiveState,
        block_reason: str,
    ) -> None:
        """Mirror legacy prep_blocked for prepare/label/prompt failures."""
        iid = att.iid
        self._open.discard(iid)
        self._retry_count[iid] = entry.retry_count + 1
        self._blocked_at_tick[iid] = self._tick_seq
        final_status = (
            "failed" if self._retry_count[iid] > inp.blocked_retry_limit else "blocked"
        )

        if final_status == "failed":
            self._failed.add(iid)
            self._blocked.discard(iid)
            self._blocked_at_tick.pop(iid, None)
        else:
            self._blocked.add(iid)

        try:
            await workflow.execute_activity(
                sync_terminal_labels,
                args=[inp, att, final_status],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=RetryPolicy(maximum_attempts=1),
            )
        except ActivityError as ae:
            block_reason = (
                block_reason
                + f"; {final_status} label sync failed: "
                f"{_activity_error_message(ae, default=str(ae))}"
            )

        synthetic = AttemptOutcome(
            iid=iid,
            attempt_number=att.attempt_number,
            status=final_status,  # type: ignore[arg-type]
            mode_actual=att.mode,
            work_branch=att.work_branch,
            local_branch=f"{att.work_branch}-att{att.attempt_number:03d}",
            block_reason=block_reason,
        )
        await self._record_outcome(inp, att, synthetic, final_status)

    def _final_summary(self) -> CampaignSummary:
        return CampaignSummary(
            final_tick_seq=self._tick_seq,
            completed_iids=tuple(sorted(self._completed)),
            failed_iids=tuple(sorted(self._failed)),
            timeout_iids=tuple(sorted(self._timeout)),
            blocked_iids=tuple(sorted(self._blocked)),
            pending_iids=tuple(sorted(self._open | self._pending)),
        )

    def _set_scope_from_input(self, inp: CampaignInput) -> None:
        self._scope_min_iid = inp.issue_min_iid
        self._scope_max_iid = inp.issue_max_iid
        self._scope_iids_whitelist = inp.issue_iids_whitelist

    def _scope_contains_iid(self, iid: int) -> bool:
        if self._scope_min_iid is None or self._scope_max_iid is None:
            return True
        if iid < self._scope_min_iid or iid > self._scope_max_iid:
            return False
        if self._scope_iids_whitelist and iid not in self._scope_iids_whitelist:
            return False
        return True


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


_CONTINUE_RESET_LABELS = frozenset(
    {
        "todo",
        "retry",
        "new",
        "doing",
        "blocked",
        "failed",
        "timeout",
        "done",
        "pr",
    }
)


def _attempt_mode_for_entry(entry: IssueLiveState) -> str:
    """Continue only when continue/contiune is the sole workflow-state signal.

    If a reviewer accidentally leaves another workflow label next to continue,
    use fresh mode. That matches the requested reset semantics while preserving
    custom non-workflow labels such as priority or team tags.
    """
    if not entry.needs_continue:
        return "fresh"
    if set(entry.labels) & _CONTINUE_RESET_LABELS:
        return "fresh"
    return "continue"


def _activity_error_message(ae: ActivityError, *, default: str) -> str:
    cause = ae.cause
    if isinstance(cause, ApplicationError) and cause.message:
        return str(cause.message)
    return default


__all__ = ["CampaignWorkflow"]
