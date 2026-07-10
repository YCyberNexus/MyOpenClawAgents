# req_executor Usage

`req_executor` takes GitLab issue content as the Claude Code task prompt. It does not require project material directories, runtime basename fields, or UI account-pool fields.

## Driven Single Issue

`req_dispatcher` sends:

```text
RUN_SINGLE_ISSUE
project=<group>/<project>
iid=<iid>
correlation_id=<id>
dispatcher_callback_target=<target>
```

Optional:

```text
group=<group>
```

`dispatch_single_issue.sh` reads GitLab token from process env or `config/gitlab.env`, reads only the clone parent from `config/campaign_defaults.env` / ignored `config/campaign_defaults.local.env`, accepts optional `branch=`, synthesizes a one-IID scheduled trigger, and writes:

```text
${REPO_PATH}/.req_executor/issues/issue-<iid>/dispatch_origin.json
```

## Scheduled Trigger

Minimum scheduled trigger:

```text
RUN_SCHEDULED_ISSUE_CAMPAIGN
group=<group>
project=<project>
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

Common optional fields:

- `branch` (omitted means the remote default branch from `origin/HEAD`)
- `repo_path`
- `max_concurrent_subagents`
- `acpx_timeout_seconds`
- `stuck_after_minutes`
- `issue_iids`
- `require_labels`
- `require_labels_match`
- `result_note_enabled`
- `model_tiers`
- `continue_upgrade_threshold`

Do not send runtime basename, data directory, or UI account-pool fields.
Do not send the legacy `run_timeout_seconds` field. OpenClaw 2026.6.11 reads
the optional global `agents.defaults.subagents.runTimeoutSeconds` internally;
it is not visible in an individual `sessions_spawn` call.

## Runtime Layout

```text
${REPO_PATH}/.req_executor/
  _dispatcher/
  issues/issue-<iid>/
  .worktrees/issue-<iid>/
    .req_executor/issue-<iid>/output/
    .req_executor/issue-<iid>/log/attempt-NNN/
```

`run_acpx_attempt.sh` runs from `${WORKTREE_DIR}` and invokes:

```bash
acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"
```

The acpx invocation logic is intentionally centralized in that script.
