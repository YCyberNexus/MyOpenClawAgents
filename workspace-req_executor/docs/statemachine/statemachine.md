# Superseded State Machine

This historical diagram has been superseded by the current `req_executor`
contract documented under:

- `skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`
- `skills/gitlab_issue_campaign_dispatcher/references/state_schema.md`
- `skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md`

Current behavior is issue-driven: the issue/wiki carries task context, runtime
state lives under `.req_executor/`, and the target branch is resolved from
`origin/HEAD` when a scheduled trigger omits `branch=`.
