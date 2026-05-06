# Trigger Command (Dispatcher)

The scheduler always sends the same command. Minimum (recommended) form:

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

Older triggers may also include `gitlab_address=...`. That is still accepted — see "Optional inputs" below.

## Required inputs

| Field                   | Notes                                                                 |
| ----------------------- | --------------------------------------------------------------------- |
| `group`                 | GitLab group slug                                                     |
| `project`               | GitLab project slug                                                   |
| `branch`                | **Integration / target branch** (typically `master`). MRs are opened against this branch; spec accumulation happens here. |
| `dev_branch`            | **Clean baseline branch** (typically `dev`). Fresh-mode worktrees are checked out from `origin/${dev_branch}` so Claude Code starts from a clean tree without past spec accumulation. If the project does not maintain a separate clean baseline, set `dev_branch=<same-as-branch>` to fall back to single-branch behavior. |
| `hulat_dir`             | String passed through to Claude Code prompt. **Not a working dir.**   |
| `gitlab_token`          | Token used by `glab auth login` against the deployment-pinned host    |
| `issue_min_iid`         | Integer, inclusive                                                    |
| `issue_max_iid`         | Integer, inclusive                                                    |
| `hourly_issue_quota`    | Integer. **Per-tick completion count, not parallelism.** Independent of `max_concurrent_subagents`. |
| `max_runtime_minutes`   | Integer wall-clock budget for this tick                               |
| `blocked_retry_limit`   | Integer                                                               |
| `blocked_cooldown_ticks`| Integer                                                               |

## Optional inputs

| Field                       | Notes                                                                                                                                              |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gitlab_address`            | Pure verification value. The host is pinned in `<workspace>/config/gitlab.env`; it is never derived from this field. If supplied, `scripts/glab_auth.sh` checks that it resolves to the same `host:port` and protocol as the pin and aborts on mismatch (exit 13). If omitted, the pin is used unconditionally. New triggers should omit this field. |
| `max_concurrent_subagents`  | Integer ≥ 1, defaults to `1` if omitted. Upper bound on concurrent issue subagents this dispatcher may have in flight at the same time. **Different IIDs only — two attempts for the same IID never run concurrently regardless of this value.** Independent of `hourly_issue_quota` (which counts terminal completions per tick). When `=1`, behavior is identical to the legacy strictly-serial model. See SOUL.md "Subagent Concurrency Policy" and SKILL.md "Concurrency Policy" for the full contract. |

## Expected fixed values

```text
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
```

If any of these is missing or different, abort the tick with a short summary; do not silently substitute defaults.

## Trigger-input override

Every scalar in "Required inputs" above is authoritative for the current tick. The dispatcher MUST overwrite the disk copy in `campaign_state.json` with the trigger values before running the algorithm. Stale values from disk MUST NOT be used.

This applies in particular to: `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`.

`max_concurrent_subagents` (when supplied) is also applied as an override using the same rule: write the trigger value into `campaign_state.json.max_concurrent_subagents`. When the trigger omits it, the dispatcher MUST default the field to `1` for the tick AND persist that default so the disk schema stays consistent across versions.

`gitlab_address` (when supplied) is NOT applied as an override — it is used only for the cross-check above. The pin in `<workspace>/config/gitlab.env` is the single source of truth for host / protocol.

## Child worker trigger

The dispatcher no longer sends `RUN_SINGLE_ISSUE_SESSION`. After `scripts/prepare_issue_environment.sh` writes `${ISSUE_ROOT}/handoff.json` and `${LOG_DIR}/subagent_task.md`, the dispatcher wakes the dedicated issue session with:

```text
RUN_PREPARED_ISSUE_WORKER
handoff_file=<absolute path to ${ISSUE_ROOT}/handoff.json>
project=<project>
group=<group>
issue_iid=<iid>
attempt_number=<dispatcher-allocated attempt number>
branch=<branch>
dev_branch=<dev_branch>
hulat_dir=<hulat_dir>
gitlab_token=<token>
blocked_retry_limit=<limit>
non_interactive=true
```

The `sessions_spawn` call that sends this payload MUST be a thread-bound dedicated-session spawn: `mode="session"` and `thread=true`, targeting session name `issue-<project>-<iid>`.

The worker payload must tell the worker not to read SKILL.md or references, not to call `sessions_spawn` / `sessions_history`, and to run the self-contained command in `${LOG_DIR}/subagent_task.md`.
