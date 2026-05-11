# acpx_auto_tester User Contract

Use this workspace for a recurring scheduled GitLab issue campaign.

## Scheduler Command

Send the same dispatcher command every tick. Command name: `RUN_SCHEDULED_ISSUE_CAMPAIGN`. Full input list, required vs optional fields, and override rules are in [`skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`](skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md).

Notes:

- `branch` is the **integration / target** branch (typically `master`); `dev_branch` is the **clean baseline** (typically `dev`) used to reset fresh-mode repo checkouts so Claude Code does not see past issues' spec accumulation. If your project has no separate baseline, set `dev_branch=<same-as-branch>`.
- `max_concurrent_subagents` defaults to `1`; raise it to fan out across multiple in-flight IIDs, but only up to the size of the UI account pool at `<workspace>/config/ui_accounts.env` (each in-flight subagent must hold a distinct account). The dispatcher gives each attempt its own per-attempt linked git worktree so cross-IID parallelism is safe at the working-tree level.
- `gitlab_address` is no longer required (the host is pinned at `<workspace>/config/gitlab.env`). If supplied, it is treated as a verification value — see [`skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`](skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md) §Optional inputs.

## Expected Behavior

- same dispatcher session every scheduler tick
- one dedicated session per issue
- backlog carryover
- blocked issues may be skipped temporarily and retried later
- remaining quota should be used on later issues when possible
- detailed logs are stored on disk, not in chat
