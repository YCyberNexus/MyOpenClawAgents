"""IssueAttemptWorkflow — one execution per (project, iid) per attempt.

Driven by :class:`CampaignWorkflow` as a child workflow with
``WorkflowIDReusePolicy.REJECT_DUPLICATE`` on
``id=f"issue:{project}:{iid}:att-{attempt_number:03d}"`` — Temporal Service
enforces that the same attempt is not started twice.

Replaces the executor-prompt Steps 0–10 in
``../skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md``.
Three terminal branches:

* **TIMEOUT flow** — only entered when :func:`run_claude_code_attempt`
  raises ``ApplicationError(type=acpx_timed_out)``. Stages + commits +
  pushes partial work, sets label ``timeout``, summarizes locally. NO
  Wiki, NO ``done`` / ``pr`` labels, NO MR.
* **BLOCKED_PUSH flow** — entered when :func:`run_claude_code_attempt`
  raises any other acpx failure (``acpx_failed`` / infrastructure error).
  Mirrors executor_prompt.md §blocked_push_flow: best-effort stage +
  commit + push + post-push verify of committable partial work to
  ``${WORK_BRANCH}``, then sets label ``blocked``, summarizes locally. NO
  Wiki, NO ``done`` / ``pr`` labels, NO MR. This keeps the ``blocked``
  semantics (retry budget is consumed) while still landing any generated
  files on the work branch for the reviewer.
* **FAIL flow** — any non-retryable failure of a *post-acpx* step (stage,
  commit, push, verify, wiki, label, MR, pr). Push has already happened
  (or the failing step is the push itself), so this flow only sets label
  ``blocked`` and summarizes locally — it does not re-attempt the push.
  The CampaignWorkflow may later promote ``blocked → failed`` when
  ``retry_count`` exceeds ``blocked_retry_limit``.

Determinism contract:
    Every external observation (subprocess, glab) must go through an
    Activity. The only stdlib calls inside this module that touch I/O are
    ``workflow.now()`` and ``workflow.execute_activity`` (both replay-safe).
"""

from __future__ import annotations

import logging
from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy
from temporalio.exceptions import ActivityError, ApplicationError

# Activity references must be imported under the workflow.unsafe sandbox guard
# because they pull in non-deterministic deps (asyncio.subprocess). Workflow
# code only references them by ``activity.defn`` name when scheduling.
with workflow.unsafe.imports_passed_through():
    from ..activities.leaf import (
        _local_attempt_branch,
        add_pr_label,
        commit_and_push,
        create_or_rotate_mr,
        post_push_verify,
        run_claude_code_attempt,
        stage_and_guard,
        summarize_attempt,
        sync_terminal_labels,
        transition_label_doing_to_done,
        upload_wiki_artifacts,
    )
    from ..shared.errors import AcpxErrorType
    from ..shared.types import (
        AttemptInput,
        AttemptOutcome,
        CampaignInput,
        CommitPushResult,
        IssueAttemptWorkflowInput,
        MrResult,
    )

LOG = logging.getLogger("acpx_temporal.workflows.issue_attempt")


# Use the leaf-side helper rather than re-implementing here (round-2 review
# Critical-1: same formula in two places is a drift hazard). The import lives
# inside ``workflow.unsafe.imports_passed_through()`` above so the workflow
# sandbox doesn't reject it.
_attempt_local_branch = _local_attempt_branch


# Activity-side retry policy snippets per the migration plan §Activity registry.
# Kept as module-level constants so they're easy to audit.

_RP_2_ATTEMPTS = RetryPolicy(
    initial_interval=timedelta(seconds=2),
    backoff_coefficient=1.5,
    maximum_interval=timedelta(seconds=30),
    maximum_attempts=2,
    non_retryable_error_types=[],  # taxonomy already marks non_retryable on the error
)
_RP_3_ATTEMPTS = RetryPolicy(
    initial_interval=timedelta(seconds=2),
    backoff_coefficient=1.5,
    maximum_interval=timedelta(seconds=30),
    maximum_attempts=3,
    non_retryable_error_types=[],
)
_RP_1_ATTEMPT = RetryPolicy(
    initial_interval=timedelta(seconds=2),
    backoff_coefficient=1.0,
    maximum_interval=timedelta(seconds=2),
    maximum_attempts=1,
    non_retryable_error_types=[],
)


@workflow.defn(name="IssueAttemptWorkflow")
class IssueAttemptWorkflow:
    """One attempt of one IID. See module docstring."""

    def __init__(self) -> None:
        # Progress tracking exposed via the ``step`` query.
        self._step: str = "init"
        # Accumulated label mutations (for the AttemptOutcome).
        self._labels_added: list[str] = []
        self._labels_removed: list[str] = []
        # Captured artifacts (filled as we go).
        self._commit_sha: str = ""
        self._mr_url: str = ""
        self._mr_action: str = "none"
        self._wiki_url: str = ""
        self._log_dir: str = ""

    # ── Queries ─────────────────────────────────────────────────────────────

    @workflow.query
    def step(self) -> str:
        return self._step

    # ── Main run ────────────────────────────────────────────────────────────

    @workflow.run
    async def run(self, inp: IssueAttemptWorkflowInput) -> AttemptOutcome:
        camp, att = inp.campaign, inp.attempt
        LOG.info(
            "IssueAttemptWorkflow iid=%d attempt=%d mode=%s",
            att.iid,
            att.attempt_number,
            att.mode,
        )

        # ── Step 1: acpx run (with heartbeat + 18120s StartToClose) ─────────
        self._step = "claude"
        try:
            acpx_res = await workflow.execute_activity(
                run_claude_code_attempt,
                args=[camp, att],
                start_to_close_timeout=timedelta(
                    seconds=camp.acpx_timeout_seconds + 120
                ),
                heartbeat_timeout=timedelta(seconds=180),
                retry_policy=_RP_1_ATTEMPT,
            )
            self._log_dir = acpx_res.log_dir
        except ActivityError as ae:
            cause = _root_application_error(ae)
            if cause is not None and cause.type == AcpxErrorType.ACPX_TIMED_OUT:
                return await self._timeout_flow(camp, att, str(cause.message))
            # Any other acpx failure (ACPX_FAILED, infrastructure error) is
            # blocked — the next attempt may succeed. Mirror executor_prompt.md
            # §blocked_push_flow: still try to force-push any committable
            # partial work the failed run left in the worktree before marking
            # the issue blocked (the FAIL flow is for post-acpx step failures,
            # where the push already ran).
            reason = (
                str(cause.message) if cause is not None else "acpx activity failed"
            )
            return await self._blocked_push_flow(camp, att, reason)

        # ── Step 2: stage_and_guard ─────────────────────────────────────────
        self._step = "stage"
        try:
            await workflow.execute_activity(
                stage_and_guard,
                args=[camp, att],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_2_ATTEMPTS,
            )
        except ActivityError as ae:
            cause = _root_application_error(ae)
            return await self._fail_flow(
                camp,
                att,
                "blocked",
                _msg(cause, default="stage_and_guard failed"),
            )

        # ── Step 3: commit_and_push ─────────────────────────────────────────
        self._step = "commit"
        try:
            push_res: CommitPushResult = await workflow.execute_activity(
                commit_and_push,
                args=[camp, att],
                start_to_close_timeout=timedelta(seconds=30),
                retry_policy=_RP_1_ATTEMPT,
            )
            self._commit_sha = push_res.commit_sha
        except ActivityError as ae:
            cause = _root_application_error(ae)
            return await self._fail_flow(
                camp, att, "blocked", _msg(cause, default="commit_and_push failed")
            )

        # ── Step 4: post_push_verify ────────────────────────────────────────
        self._step = "verify"
        try:
            await workflow.execute_activity(
                post_push_verify,
                args=[camp, att],
                start_to_close_timeout=timedelta(seconds=15),
                retry_policy=_RP_3_ATTEMPTS,
            )
        except ActivityError as ae:
            cause = _root_application_error(ae)
            return await self._fail_flow(
                camp, att, "blocked", _msg(cause, default="post_push_verify failed")
            )

        # ── Step 5: Wiki ────────────────────────────────────────────────────
        self._step = "wiki"
        try:
            self._wiki_url = await workflow.execute_activity(
                upload_wiki_artifacts,
                args=[camp, att],
                start_to_close_timeout=timedelta(seconds=20),
                retry_policy=_RP_1_ATTEMPT,
            )
        except ActivityError as ae:
            cause = _root_application_error(ae)
            return await self._fail_flow(
                camp, att, "blocked", _msg(cause, default="upload_wiki_artifacts failed")
            )

        # ── Step 6: doing → done ────────────────────────────────────────────
        self._step = "label_done"
        try:
            await workflow.execute_activity(
                transition_label_doing_to_done,
                args=[camp, att],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
            self._labels_removed.append("doing")
            self._labels_added.append("done")
        except ActivityError as ae:
            cause = _root_application_error(ae)
            return await self._fail_flow(
                camp, att, "blocked", _msg(cause, default="label doing→done failed")
            )

        # ── Step 7: MR rotate ───────────────────────────────────────────────
        self._step = "mr"
        try:
            mr_res: MrResult = await workflow.execute_activity(
                create_or_rotate_mr,
                args=[camp, att],
                start_to_close_timeout=timedelta(seconds=20),
                retry_policy=_RP_1_ATTEMPT,  # non-atomic; NEVER retry
            )
            self._mr_url = mr_res.url
            self._mr_action = mr_res.action
        except ActivityError as ae:
            cause = _root_application_error(ae)
            # MR rotate failure leaves the issue with `done` (already labeled
            # in Step 6) + `blocked`. Don't strip `done`; just append blocked.
            return await self._fail_flow(
                camp, att, "blocked", _msg(cause, default="create_or_rotate_mr failed")
            )

        # ── Step 8: add pr ──────────────────────────────────────────────────
        self._step = "pr"
        try:
            await workflow.execute_activity(
                add_pr_label,
                args=[camp, att],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
            self._labels_added.append("pr")
        except ActivityError as ae:
            cause = _root_application_error(ae)
            return await self._fail_flow(
                camp, att, "blocked", _msg(cause, default="add_pr_label failed")
            )

        # ── Step 9: summarize (post to issue for `done`) ────────────────────
        self._step = "summarize"
        summary_posted = False
        try:
            summary_posted = await workflow.execute_activity(
                summarize_attempt,
                args=[
                    camp,
                    att,
                    "done",
                    self._commit_sha,
                    self._mr_url,
                    "",
                    True,
                ],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
        except ActivityError:
            # Summarize failure is non-fatal: status stays done, summary not posted.
            LOG.warning("summarize_attempt failed; status stays done")

        self._step = "done"
        return AttemptOutcome(
            iid=att.iid,
            attempt_number=att.attempt_number,
            status="done",
            mode_actual=att.mode,
            work_branch=att.work_branch,
            local_branch=_attempt_local_branch(att.iid, att.attempt_number),
            commit_sha=self._commit_sha,
            merge_request_url=self._mr_url,
            mr_action=mr_action_literal(self._mr_action),
            wiki_url=self._wiki_url,
            labels_added=tuple(self._labels_added),
            labels_removed=tuple(self._labels_removed),
            summary_posted=summary_posted,
            block_reason="",
            log_dir=self._log_dir,
        )

    # ── FAIL flow (blocked) ─────────────────────────────────────────────────

    async def _fail_flow(
        self,
        camp: CampaignInput,
        att: AttemptInput,
        terminal_status: str,
        block_reason: str,
    ) -> AttemptOutcome:
        """Mirror executor_prompt.md §fail_flow.

        Sets blocked label (additive — does NOT strip a prior `done`),
        summarizes locally (SUMMARY_POST_TO_ISSUE=false), returns the outcome.
        """
        self._step = f"fail:{terminal_status}"
        LOG.warning(
            "IssueAttemptWorkflow iid=%d attempt=%d FAIL status=%s reason=%s",
            att.iid,
            att.attempt_number,
            terminal_status,
            block_reason[:200],
        )

        # Sync labels — best-effort; if it fails, append note to block_reason.
        try:
            await workflow.execute_activity(
                sync_terminal_labels,
                args=[camp, att, terminal_status],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
            self._labels_removed.append("doing")
            self._labels_added.append(terminal_status)
        except ActivityError as ae:
            cause = _root_application_error(ae)
            block_reason = (
                block_reason
                + f"; {terminal_status} label sync failed: {_msg(cause, default=str(ae))}"
            )

        # Local-only summary.
        try:
            await workflow.execute_activity(
                summarize_attempt,
                args=[camp, att, terminal_status, self._commit_sha, self._mr_url,
                      block_reason, False],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
        except ActivityError:
            LOG.warning("summarize_attempt failed during FAIL flow; continuing")

        return AttemptOutcome(
            iid=att.iid,
            attempt_number=att.attempt_number,
            status=terminal_status,  # type: ignore[arg-type]
            mode_actual=att.mode,
            work_branch=att.work_branch,
            local_branch=_attempt_local_branch(att.iid, att.attempt_number),
            commit_sha=self._commit_sha,
            merge_request_url=self._mr_url,
            mr_action=mr_action_literal(self._mr_action),
            wiki_url=self._wiki_url,
            labels_added=tuple(self._labels_added),
            labels_removed=tuple(self._labels_removed),
            summary_posted=False,
            block_reason=block_reason,
            log_dir=self._log_dir,
        )

    # ── TIMEOUT flow ────────────────────────────────────────────────────────

    async def _timeout_flow(
        self, camp: CampaignInput, att: AttemptInput, primary_reason: str
    ) -> AttemptOutcome:
        """Mirror executor_prompt.md §timeout_flow (steps T1–T6).

        Stage + commit_and_push + post_push_verify are BEST-EFFORT — failures
        only append to block_reason; the terminal status stays ``timeout``.
        """
        self._step = "timeout"
        # T1–T3 best-effort partial push (shared with the BLOCKED_PUSH flow).
        block_reason = await self._best_effort_partial_push(camp, att, primary_reason)

        # T4 label doing → timeout
        try:
            await workflow.execute_activity(
                sync_terminal_labels,
                args=[camp, att, "timeout"],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
            self._labels_removed.append("doing")
            self._labels_added.append("timeout")
        except ActivityError as ae:
            cause = _root_application_error(ae)
            block_reason += f"; timeout label sync failed: {_msg(cause, default=str(ae))}"

        # T5 summarize (local-only, SUMMARY_POST_TO_ISSUE=false)
        try:
            await workflow.execute_activity(
                summarize_attempt,
                args=[camp, att, "timeout", self._commit_sha, "", block_reason, False],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
        except ActivityError:
            LOG.warning("summarize_attempt failed during TIMEOUT flow; continuing")

        return AttemptOutcome(
            iid=att.iid,
            attempt_number=att.attempt_number,
            status="timeout",
            mode_actual=att.mode,
            work_branch=att.work_branch,
            local_branch=_attempt_local_branch(att.iid, att.attempt_number),
            commit_sha=self._commit_sha,
            merge_request_url="",
            mr_action="none",
            wiki_url="",
            labels_added=tuple(self._labels_added),
            labels_removed=tuple(self._labels_removed),
            summary_posted=False,
            block_reason=block_reason,
            log_dir=self._log_dir,
        )

    # ── BLOCKED_PUSH flow ───────────────────────────────────────────────────

    async def _blocked_push_flow(
        self, camp: CampaignInput, att: AttemptInput, primary_reason: str
    ) -> AttemptOutcome:
        """Mirror executor_prompt.md §blocked_push_flow (steps B1–B6).

        Entered on a non-timeout acpx failure. Best-effort stage + commit +
        push + post-push verify of committable partial work to
        ``${WORK_BRANCH}`` (B1–B3, shared with the TIMEOUT flow), then sets the
        terminal ``blocked`` label (B4) and a local-only summary (B5). The
        terminal status stays ``blocked`` regardless of whether the push
        succeeded — push diagnostics are appended to ``block_reason`` rather
        than reclassifying. No Wiki, no MR, no ``done`` / ``pr``.
        """
        self._step = "blocked_push"
        # B1–B3 best-effort partial push (shared with the TIMEOUT flow).
        block_reason = await self._best_effort_partial_push(camp, att, primary_reason)

        # B4 label doing → blocked
        try:
            await workflow.execute_activity(
                sync_terminal_labels,
                args=[camp, att, "blocked"],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
            self._labels_removed.append("doing")
            self._labels_added.append("blocked")
        except ActivityError as ae:
            cause = _root_application_error(ae)
            block_reason += (
                f"; blocked label sync failed: {_msg(cause, default=str(ae))}"
            )

        # B5 summarize (local-only, SUMMARY_POST_TO_ISSUE=false)
        try:
            await workflow.execute_activity(
                summarize_attempt,
                args=[camp, att, "blocked", self._commit_sha, "", block_reason, False],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
        except ActivityError:
            LOG.warning("summarize_attempt failed during BLOCKED_PUSH flow; continuing")

        # B6 reply
        return AttemptOutcome(
            iid=att.iid,
            attempt_number=att.attempt_number,
            status="blocked",
            mode_actual=att.mode,
            work_branch=att.work_branch,
            local_branch=_attempt_local_branch(att.iid, att.attempt_number),
            commit_sha=self._commit_sha,
            merge_request_url="",
            mr_action="none",
            wiki_url="",
            labels_added=tuple(self._labels_added),
            labels_removed=tuple(self._labels_removed),
            summary_posted=False,
            block_reason=block_reason,
            log_dir=self._log_dir,
        )

    # ── Shared best-effort partial push (TIMEOUT + BLOCKED_PUSH) ─────────────

    async def _best_effort_partial_push(
        self, camp: CampaignInput, att: AttemptInput, block_reason: str
    ) -> str:
        """Stage → commit+push → post-push verify of partial work, best-effort.

        Shared by :meth:`_timeout_flow` (steps T1–T3) and
        :meth:`_blocked_push_flow` (steps B1–B3): the two flows differ only in
        the terminal label/status applied afterward, so keeping the push logic
        in one place avoids the drift hazard of duplicating the nested
        try/except. Every failure here is non-fatal — it only appends a
        diagnostic to ``block_reason``; the caller keeps its terminal status.
        Updates :attr:`_commit_sha` when the push lands a commit.

        Returns the (possibly appended-to) ``block_reason``.
        """
        # Stage (best-effort).
        try:
            await workflow.execute_activity(
                stage_and_guard,
                args=[camp, att],
                start_to_close_timeout=timedelta(seconds=10),
                retry_policy=_RP_1_ATTEMPT,
            )
            try_push = True
        except ActivityError as ae:
            cause = _root_application_error(ae)
            if cause is not None and cause.type == AcpxErrorType.NO_CHANGES:
                block_reason += "; no staged changes to push"
            else:
                block_reason += f"; stage step failed: {_msg(cause, default=str(ae))}"
            try_push = False

        # Commit + push (best-effort).
        if try_push:
            try:
                push_res = await workflow.execute_activity(
                    commit_and_push,
                    args=[camp, att],
                    start_to_close_timeout=timedelta(seconds=30),
                    retry_policy=_RP_1_ATTEMPT,
                )
                self._commit_sha = push_res.commit_sha

                # Post-push verify (best-effort).
                try:
                    await workflow.execute_activity(
                        post_push_verify,
                        args=[camp, att],
                        start_to_close_timeout=timedelta(seconds=15),
                        retry_policy=_RP_1_ATTEMPT,
                    )
                except ActivityError as ae:
                    cause = _root_application_error(ae)
                    block_reason += (
                        f"; post-push verify failed: {_msg(cause, default=str(ae))}"
                    )

            except ActivityError as ae:
                cause = _root_application_error(ae)
                block_reason += (
                    f"; commit_and_push step failed: {_msg(cause, default=str(ae))}"
                )

        return block_reason


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _root_application_error(ae: ActivityError) -> ApplicationError | None:
    """Return the ApplicationError that an activity raised.

    The Temporal Python SDK wraps activity-raised errors as
    ``ActivityError(cause=ApplicationError(...))``. The ``cause`` attribute on
    ``ActivityError`` is the canonical accessor — walking ``__cause__`` /
    ``getattr(cause, 'cause', None)`` is wrong because ``ApplicationError``
    does not expose a ``.cause`` attribute and its ``__cause__`` is normally
    None (the activity catches the original and re-raises a typed
    ApplicationError without chaining).

    If we returned None for a real ``acpx_timed_out`` failure, every timeout
    would fall through to the FAIL flow and the TIMEOUT-flow branch (partial
    push + ``timeout`` label) would never execute. That's why this helper
    needs to be the simplest possible thing that works.
    """
    cause = ae.cause
    return cause if isinstance(cause, ApplicationError) else None


def _msg(err: ApplicationError | None, *, default: str) -> str:
    return str(err.message) if err is not None and err.message else default


def mr_action_literal(s: str) -> str:
    """Coerce string to MrAction literal at runtime — mypy already enforces."""
    return s if s in ("created", "rotated", "none") else "none"


__all__ = ["IssueAttemptWorkflow"]
