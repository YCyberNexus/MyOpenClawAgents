# UiAutoTester Workspace Notes

This workspace implements a quota-carryover GitLab issue campaign with blocked skip-and-retry.

## Agent Identity

- Agent name: `UiAutoTester`
- Dispatcher session: `agent:UiAutoTester:main`

## Execution Model

This workspace is intentionally split into two skills:

1. `gitlab_issue_campaign_dispatcher`
   - lightweight scheduler-facing dispatcher
   - reads and updates campaign state
   - manages per-tick quota
   - handles backlog carryover
   - skips blocked issues temporarily and retries them later
   - creates or resumes one dedicated session per issue

2. `gitlab_single_issue_executor`
   - heavy single-issue executor
   - runs only inside a dedicated issue session
   - must never be reused for another issue

## Required Capabilities

The agent configuration should allow:
- `read`
- `write`
- `edit`
- `exec`
- `sessions_history`
- `sessions_spawn`

## Session Naming Recommendation

Dedicated issue session pattern:
- `issue-<project>-<iid>`

Examples:
- `issue-px_ifp_hulat-1`
- `issue-px_ifp_hulat-2`

## Disk State Layout

- campaign state:
  - `/data/<project>/openclaw_state/campaign_state.json`
- issue state:
  - `/data/<project>/openclaw_state/issues/issue-<iid>.json`
- logs:
  - `/data/<project>/openclaw_log/issue-<iid>/`
