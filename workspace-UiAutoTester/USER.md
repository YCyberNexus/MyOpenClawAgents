# UiAutoTester User Contract

Use this workspace for a recurring scheduled GitLab issue campaign.

## Scheduler Command

Send the same dispatcher command every time:

```text
RUN_SCHEDULED_ISSUE_CAMPAIGN
gitlab_address=<gitlab-address>
group=<group>
project=<project>
branch=<branch>
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

## Expected Behavior

- same dispatcher session every scheduler tick
- one dedicated session per issue
- backlog carryover
- blocked issues may be skipped temporarily and retried later
- remaining quota should be used on later issues when possible
- detailed logs are stored on disk, not in chat
