# cctester User Contract

Use this workspace for a recurring scheduled GitLab issue campaign.

## Scheduler Command

Send the same dispatcher command every time:

```text
RUN_SCHEDULED_ISSUE_CAMPAIGN
group=<group>
project=<project>
branch=<branch>
dev_branch=<dev_branch>
hulat_dir=<hulat_dir>
gitlab_token=<token>
issue_min_iid=<min_iid>
issue_max_iid=<max_iid>
hourly_issue_quota=<quota>
max_runtime_minutes=<minutes>
blocked_retry_limit=<limit>
blocked_cooldown_ticks=<cooldown>
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
```

`branch` is the **integration / target** branch (typically `master`). `dev_branch` is the **clean baseline** branch (typically `dev`) used to check out fresh-mode worktrees, so Claude Code never sees past issues' spec accumulation in its working tree. If your project does not maintain a separate baseline, set `dev_branch=<same-as-branch>` to fall back to single-branch behavior.

`gitlab_address` is no longer required in the trigger. The GitLab host is pinned at `<workspace>/config/gitlab.env` on the runner; the agent uses that as the single source of truth. If you do include `gitlab_address` for legacy reasons, it is treated as a verification value — the agent aborts the tick if it disagrees with the deployment pin, and never silently switches hosts.

## Expected Behavior

- same dispatcher session every scheduler tick
- one dedicated session per issue
- backlog carryover
- blocked issues may be skipped temporarily and retried later
- remaining quota should be used on later issues when possible
- detailed logs are stored on disk, not in chat
