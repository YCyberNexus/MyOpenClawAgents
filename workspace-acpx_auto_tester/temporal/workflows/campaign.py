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
        bump_campaign_tick_seq,
        clone_or_pull_repo,
        ensure_workflow_labels,
        load_ui_account_pool,
        mark_issue_doing,
        prepare_attempt_worktree,
        record_attempt_outcome,
        reconcile_gitlab,
        resolve_and_stamp_model_tier,
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
        # v2: failed split by attribution side. blocked stays a single bucket
        # (cc + dispatcher) — the per-side distinction lives on the live label.
        self._completed: set[int] = set()
        self._failed_cc: set[int] = set()
        self._failed_dispatcher: set[int] = set()
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
            failed_cc_iids=tuple(sorted(self._failed_cc)),
            failed_dispatcher_iids=tuple(sorted(self._failed_dispatcher)),
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
        # A bad trigger/config must fail THIS tick loudly and terminally, the
        # way the bash dispatcher's ``emit_chat_failure`` does — not wedge the
        # workflow task in an infinite retry. ``validated()`` raises a bare
        # ``ValueError``; Temporal would treat that as a (retryable) workflow
        # task failure and replay it forever. Re-raising as a non-retryable
        # ``ApplicationError`` (a ``FailureError``) fails the workflow execution
        # cleanly, surfacing the dispatcher's exact abort string. The next
        # Schedule firing starts a fresh execution that fails again until the
        # operator fixes the input.
        try:
            inp = inp.validated()
        except ValueError as exc:
            raise ApplicationError(
                str(exc), type="invalid_campaign_input", non_retryable=True
            ) from exc
        self._set_scope_from_input(inp)
        tick_started_at = workflow.now()

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

        # ── Monotonic tick counter ──────────────────────────────────────────
        # blocked_cooldown_ticks counts elapsed scheduled wake-ups, so it needs
        # a tick number that persists across Schedule firings. Each firing is a
        # fresh workflow execution (the in-memory ``self._tick_seq`` would always
        # read 1), so we read+increment a dispatcher-level counter on disk,
        # mirroring the legacy ``campaign_state.json.tick_seq``. Runs after
        # clone_or_pull so the dispatcher directory under ${REPO_PATH} exists.
        # Single-shot (no retry) like the other non-idempotent state writes.
        self._tick_seq = await workflow.execute_activity(
            bump_campaign_tick_seq,
            args=[inp],
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=RetryPolicy(maximum_attempts=1),
        )
        LOG.info("CampaignWorkflow tick=%d project=%s", self._tick_seq, inp.project)

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
        ``has_failed_*`` / ``has_blocked_*`` / ``has_timeout`` — a reviewer who
        relabels a closed-failed issue with ``continue`` is explicitly asking
        the agent to resume that IID. Same precedence rule lives in the
        legacy reconcile.sh / dispatch_prepare_tick.sh.
        """
        self._completed.clear()
        self._failed_cc.clear()
        self._failed_dispatcher.clear()
        self._timeout.clear()
        self._blocked.clear()
        self._open.clear()

        for entry in ev.per_iid:
            has_failed_any = entry.has_failed_cc or entry.has_failed_dispatcher
            has_blocked_any = entry.has_blocked_cc or entry.has_blocked_dispatcher
            if entry.is_closed_on_gitlab:
                self._completed.add(entry.iid)
            elif entry.needs_continue:
                # Reviewer asked to resume — wins over every other label state.
                self._open.add(entry.iid)
            elif entry.has_pr:
                # v2: pr REPLACES done — the completion signal is the pr label.
                self._completed.add(entry.iid)
            elif entry.has_timeout and not entry.has_retry:
                self._timeout.add(entry.iid)
            elif has_failed_any or entry.retry_count > inp.blocked_retry_limit:
                # Route to the matching per-side failed bucket. The promotion
                # (blocked-* → failed-*) may not have landed on the live label
                # yet when retry_count just crossed the limit, so attribute by
                # ANY in-scope per-side signal: an explicit failed-dispatcher OR
                # a still-present blocked-dispatcher means the dispatcher side;
                # otherwise CC side (the common case). This keeps a
                # dispatcher-side exhaustion from being miscounted as a CC-side
                # failure, which would otherwise feed the model-upgrade signal.
                if entry.has_failed_dispatcher or entry.has_blocked_dispatcher:
                    self._failed_dispatcher.add(entry.iid)
                else:
                    self._failed_cc.add(entry.iid)
            elif has_blocked_any and not entry.has_retry:
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
        # allocate_slots raises a bare ValueError on the dispatcher's
        # "ui_account_pool_too_small" / "invalid_max_*" conditions. As with
        # validated() above, convert it to a non-retryable ApplicationError so
        # the misconfigured tick fails the workflow loudly (with the exact abort
        # string) instead of wedging the workflow task in an infinite retry.
        try:
            slots = allocate_slots(
                pool_size=pool_size,
                max_concurrent_subagents=inp.max_concurrent_subagents,
                max_accounts_per_issue=inp.max_accounts_per_issue,
            )
        except ValueError as exc:
            raise ApplicationError(
                str(exc), type="ui_account_allocation_failed", non_retryable=True
            ) from exc
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

                # v2 resolve_model_tier (§6): runs AFTER mark_issue_doing (which
                # never clears the orthogonal model dimension) and BEFORE
                # build_executor_prompt. It stamps the resolved model:{tier}
                # label, consumes quality:low on an upgrade, and returns the
                # model name to inject into the executor prompt.
                model_name, model_tier = await workflow.execute_activity(
                    resolve_and_stamp_model_tier,
                    args=[inp, att],
                    start_to_close_timeout=timedelta(seconds=15),
                    retry_policy=_RP_2_ATTEMPTS,
                )
                att = replace(att, model_name=model_name, model_tier=model_tier)

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

        # Await every child handle directly. ``workflow.start_child_workflow``
        # returns an awaitable ChildWorkflowHandle (an asyncio.Task-like
        # object); ``await handle`` yields the child's return value and raises
        # ChildWorkflowError if the child failed. Do NOT call ``handle.result()``
        # — that is the synchronous ``asyncio.Future.result()`` and raises
        # ``InvalidStateError: Result is not set`` because the child has not
        # completed yet at the moment of the call.
        for handle, iid, att, entry in child_handles:
            try:
                outcome: AttemptOutcome = await handle
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
                # A child workflow failing before it returns an outcome — and a
                # scope eviction — are both dispatcher-side conditions (§4), so
                # they map to blocked_dispatcher (promoting to failed_dispatcher
                # when the retry budget is exhausted).
                final_status = (
                    "failed_dispatcher"
                    if (not scope_evicted and self._retry_count[iid] > inp.blocked_retry_limit)
                    else "blocked_dispatcher"
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
                if final_status == "failed_dispatcher":
                    self._failed_dispatcher.add(iid)
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
                # Scope eviction is a dispatcher-side decision → blocked_dispatcher.
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
                        args=[inp, att, "blocked_dispatcher"],
                        start_to_close_timeout=timedelta(seconds=10),
                        retry_policy=RetryPolicy(maximum_attempts=1),
                    )
                except ActivityError as ae:
                    block_reason = (
                        block_reason
                        + "; blocked-dispatcher label sync failed: "
                        f"{_activity_error_message(ae, default=str(ae))}"
                    )
                synthetic = replace(
                    outcome,
                    status="blocked_dispatcher",
                    block_reason=block_reason,
                )
                await self._record_outcome(
                    inp,
                    att,
                    synthetic,
                    "blocked_dispatcher",
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
            elif outcome.status == "failed_cc":
                self._failed_cc.add(iid)
                await self._record_outcome(inp, att, outcome, "failed_cc")
            elif outcome.status == "failed_dispatcher":
                self._failed_dispatcher.add(iid)
                await self._record_outcome(inp, att, outcome, "failed_dispatcher")
            else:
                # blocked_cc / blocked_dispatcher (and legacy no_changes which
                # the bash normalizer maps to blocked_cc). Promote to the
                # matching per-side failed status when the retry budget is
                # exhausted: blocked_cc → failed_cc, blocked_dispatcher →
                # failed_dispatcher (§5).
                blocked_status = (
                    "blocked_dispatcher"
                    if outcome.status == "blocked_dispatcher"
                    else "blocked_cc"
                )
                self._blocked.add(iid)
                self._retry_count[iid] = entry.retry_count + 1
                self._blocked_at_tick[iid] = self._tick_seq
                if self._retry_count[iid] > inp.blocked_retry_limit:
                    promoted_status = (
                        "failed_dispatcher"
                        if blocked_status == "blocked_dispatcher"
                        else "failed_cc"
                    )
                    LOG.info(
                        "iid=%d promoted %s → %s (retry=%d > limit=%d)",
                        iid,
                        blocked_status,
                        promoted_status,
                        self._retry_count[iid],
                        inp.blocked_retry_limit,
                    )
                    self._blocked.discard(iid)
                    if promoted_status == "failed_dispatcher":
                        self._failed_dispatcher.add(iid)
                    else:
                        self._failed_cc.add(iid)
                    self._blocked_at_tick.pop(iid, None)
                    await workflow.execute_activity(
                        sync_terminal_labels,
                        args=[inp, att, promoted_status],
                        start_to_close_timeout=timedelta(seconds=10),
                        retry_policy=RetryPolicy(maximum_attempts=1),
                    )
                    await self._record_outcome(inp, att, outcome, promoted_status)
                else:
                    await self._record_outcome(inp, att, outcome, blocked_status)

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
        """Mirror legacy prep_blocked for prepare/label/prompt failures.

        Per-IID prep failures are dispatcher-side (§4) → blocked_dispatcher,
        promoting to failed_dispatcher once the retry budget is exhausted.
        """
        iid = att.iid
        self._open.discard(iid)
        self._retry_count[iid] = entry.retry_count + 1
        self._blocked_at_tick[iid] = self._tick_seq
        final_status = (
            "failed_dispatcher"
            if self._retry_count[iid] > inp.blocked_retry_limit
            else "blocked_dispatcher"
        )

        if final_status == "failed_dispatcher":
            self._failed_dispatcher.add(iid)
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
            failed_cc_iids=tuple(sorted(self._failed_cc)),
            failed_dispatcher_iids=tuple(sorted(self._failed_dispatcher)),
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


# Work labels that, if present alongside `continue`, force fresh mode instead
# of continue mode (a reviewer accidentally left another work-state signal). v2
# per-side blocked-*/failed-* replace the single blocked/failed. model:{tier}
# and quality:low are orthogonal and intentionally NOT in this set.
_CONTINUE_RESET_LABELS = frozenset(
    {
        "todo",
        "retry",
        "new",
        "doing",
        "blocked-cc",
        "blocked-dispatcher",
        "failed-cc",
        "failed-dispatcher",
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
