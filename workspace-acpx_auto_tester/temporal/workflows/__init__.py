"""Workflow definitions. Two workflows total:

* :class:`acpx_temporal.workflows.campaign.CampaignWorkflow` — long-lived
  entity workflow driven by a Temporal Schedule, refreshes via
  ``continue_as_new``.
* :class:`acpx_temporal.workflows.issue_attempt.IssueAttemptWorkflow` — one
  child per ``(project, iid)`` per attempt, ID-deduped via
  ``WorkflowIDReusePolicy.REJECT_DUPLICATE``.
"""
