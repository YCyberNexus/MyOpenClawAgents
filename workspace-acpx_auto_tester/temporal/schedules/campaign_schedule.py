"""Helpers to build the Temporal :class:`Schedule` for ``CampaignWorkflow``.

Kept in its own module so ``client.py`` and any deployment glue can import
it without pulling in the Worker. The chosen :class:`ScheduleOverlapPolicy`
is ``BUFFER_ONE`` — mirrors the legacy dispatcher's ``flock`` contract:
ticks queue up at most one deep, never run in parallel.
"""

from __future__ import annotations

from datetime import timedelta

from temporalio.client import (
    Schedule,
    ScheduleActionStartWorkflow,
    ScheduleIntervalSpec,
    ScheduleOverlapPolicy,
    SchedulePolicy,
    ScheduleSpec,
)
from temporalio.common import WorkflowIDReusePolicy
from temporalio.workflow import ParentClosePolicy

from ..shared.types import CampaignInput


def build_campaign_schedule(
    *,
    schedule_id: str,
    task_queue: str,
    interval: timedelta,
    input_payload: CampaignInput,
    note: str = "",
) -> Schedule:
    """Return a :class:`Schedule` ready to pass to ``client.create_schedule``.

    Args:
        schedule_id: stable identifier (e.g. ``"campaign:px_ifp_hulat"``).
        task_queue: must match the worker's task queue
            (``"acpx-worktree-<NODE_ID>"``). The Schedule launches the
            workflow on this queue; the workflow then launches children on
            the same queue via ``workflow.info().task_queue``.
        interval: tick cadence — e.g. ``timedelta(minutes=55)``.
        input_payload: the :class:`CampaignInput` the workflow receives.
        note: free-text annotation surfaced in Temporal Web UI.
    """
    tick_timeout = max(
        interval * 4,
        timedelta(minutes=input_payload.stuck_after_minutes + 30),
    )
    return Schedule(
        action=ScheduleActionStartWorkflow(
            workflow="CampaignWorkflow",
            args=[input_payload],
            id=f"{schedule_id}:run",
            task_queue=task_queue,
            id_reuse_policy=WorkflowIDReusePolicy.ALLOW_DUPLICATE,
            execution_timeout=tick_timeout,
        ),
        spec=ScheduleSpec(intervals=[ScheduleIntervalSpec(every=interval)]),
        policy=SchedulePolicy(
            overlap=ScheduleOverlapPolicy.BUFFER_ONE,
            catchup_window=timedelta(minutes=10),
        ),
    )


# ParentClosePolicy is re-exported here so callers don't have to dig through
# temporalio.workflow imports just to compose the matching enum value.
__all__ = ["ParentClosePolicy", "build_campaign_schedule"]
