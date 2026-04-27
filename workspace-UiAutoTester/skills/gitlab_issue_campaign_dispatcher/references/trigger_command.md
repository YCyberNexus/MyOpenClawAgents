# Trigger Command (Dispatcher)

The scheduler always sends the same command:

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

## Required inputs

| Field                   | Notes                                                                 |
| ----------------------- | --------------------------------------------------------------------- |
| `gitlab_address`        | Full URL with scheme + port. Example: `http://gitlab-b.pxsemic.tech:30000` |
| `group`                 | GitLab group slug                                                     |
| `project`               | GitLab project slug                                                   |
| `branch`                | Default integration branch (typically `master`)                       |
| `hulat_dir`             | String passed through to Claude Code prompt. **Not a working dir.**   |
| `gitlab_token`          | Token used by `glab auth login`                                       |
| `issue_min_iid`         | Integer, inclusive                                                    |
| `issue_max_iid`         | Integer, inclusive                                                    |
| `hourly_issue_quota`    | Integer. **Sequential count, not parallelism.**                       |
| `max_runtime_minutes`   | Integer wall-clock budget for this tick                               |
| `blocked_retry_limit`   | Integer                                                               |
| `blocked_cooldown_ticks`| Integer                                                               |

## Expected fixed values

```text
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
```

If any of these is missing or different, abort the tick with a short summary; do not silently substitute defaults.

## Trigger-input override

Every scalar above is authoritative for the current tick. The dispatcher MUST overwrite the disk copy in `campaign_state.json` with the trigger values before running the algorithm. Stale values from disk MUST NOT be used.

This applies in particular to: `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`.
