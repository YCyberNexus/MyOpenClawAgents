# Trigger Commands

`req_executor` accepts three trigger commands:

- `RUN_SCHEDULED_ISSUE_CAMPAIGN`
- `RUN_CHILD_COMPLETION_CALLBACK`
- `RUN_SINGLE_ISSUE`

The executor is task-agnostic. It reads the GitLab issue, renders the issue content into `${LOG_DIR}/prompt.txt`, and asks the outer subagent to run `scripts/run_acpx_attempt.sh` from the prepared worktree. That script owns the fixed `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` call.

Runtime state uses the fixed in-repo directory `${REPO_PATH}/.req_executor/`. There is no trigger or config field for runtime basenames, project data directories, or account-pool paths.

## Scheduled Tick

Minimum form:

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

Required fixed values:

- `non_interactive=true`
- `session_mode=per_issue`
- `scheduling_mode=quota_carryover`
- `blocked_policy=skip_and_retry`

Required scalar fields:

- `group`
- `project`
- `gitlab_token`
- `issue_min_iid`
- `issue_max_iid`
- `hourly_issue_quota`
- `max_runtime_minutes`
- `blocked_retry_limit`
- `blocked_cooldown_ticks`

Optional fields:

- `branch`: target branch. When omitted, the wrapper resolves the repository's remote default branch from `origin/HEAD`.
- `repo_path`: absolute clone parent. `env_paths.sh` derives the final repo root as `${repo_path}/${project}`. Defaults to `/data`.
- `max_concurrent_subagents`: integer >= 1. Defaults to `1`.
- `stuck_after_minutes`: integer >= 5. Defaults to `ceil(run_timeout_seconds / 60) + 30`.
- `run_timeout_seconds`: integer >= 60. Defaults to `acpx_timeout_seconds + 120`.
- `acpx_timeout_seconds`: integer >= 60. Defaults to `18000`.
- `kill_subagent_on_terminal`: legacy compatibility boolean. Defaults to `false`; terminal child sessions are preserved for diagnosis and no `subagents kill` cleanup is requested.
- `kill_subagent_on_done`: legacy compatibility boolean, only parsed for validation when `kill_subagent_on_terminal` is omitted.
- `result_note_enabled`: boolean. Defaults to `false`.
- `issue_iids`: comma-separated IID whitelist layered on top of `[issue_min_iid, issue_max_iid]`.
- `require_labels`: comma-separated live-label inclusion filter.
- `require_labels_match`: `or` or `and`; defaults to `or`.
- `claude_settings_path`: optional absolute path to a Claude settings JSON file copied into the worktree `.claude/settings.json`.
- `model_tiers`: optional ordered JSON array of `{"tier":"<suffix>","settings":"<abs path>"}`.
- `continue_upgrade_threshold`: positive integer, defaults to `2`.
- `gitlab_address`: verification-only host/protocol check against `config/gitlab.env`; new triggers should omit it.

Unsupported fields are ignored by the shell parser only if they are not referenced by wrappers; operators should not send them. In particular, do not send runtime basename, data directory, or account-pool fields.

## Callback

`RUN_CHILD_COMPLETION_CALLBACK` is sent by the runtime when a subagent returns compact JSON. It carries the terminal worker result plus the same routing identity needed to locate state. Campaign scalars are loaded from the persisted `.req_executor/_dispatcher/campaign_state.json`; callback payloads do not override scheduled fields.

## Driven Single Issue

`RUN_SINGLE_ISSUE` is the `req_dispatcher` entry point. It accepts:

- `project`
- `iid`
- or `issue_url` as an alternative source for `project` and `iid`
- `correlation_id`
- `dispatcher_callback_target`
- optional `branch`
- optional `group`

`dispatch_single_issue.sh` parses `issue_url` values containing `/-/issues/<iid>` into `project` and `iid`; if explicit `project` or `iid` are also sent, they must match the URL. It then loads GitLab token from process env or `config/gitlab.env`, loads only the clone parent from `config/campaign_defaults.env` / ignored `config/campaign_defaults.local.env`, writes `dispatch_origin.json`, synthesizes a one-IID scheduled trigger, forwards optional `branch=`, and uses the same prepare/followup machinery as scheduled runs. The scheduled wrapper resolves the target branch from `origin/HEAD` unless the trigger explicitly supplies `branch=`.
