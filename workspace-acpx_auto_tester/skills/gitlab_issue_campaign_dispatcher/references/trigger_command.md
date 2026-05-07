# Trigger Commands (Dispatcher)

The orchestrator handles **two** trigger commands:

- `RUN_SCHEDULED_ISSUE_CAMPAIGN` — sent by the scheduler on every tick (Phases 1–5)
- `RUN_CHILD_COMPLETION_CALLBACK` — sent by the runtime when a subagent's terminal compact JSON is available (Phase 6)

## Scheduled-tick trigger: `RUN_SCHEDULED_ISSUE_CAMPAIGN`

Minimum (recommended) form:

```text
RUN_SCHEDULED_ISSUE_CAMPAIGN
group=<group>
project=<project>
branch=<branch>
dev_branch=<dev_branch>
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

Older triggers may also include `gitlab_address=...` and/or `hulat_dir=...`. Both are still accepted but ignored — `gitlab_address` is now a verification-only field (see "Optional inputs" below), and as of `SKILL_VERSION 2026-05-07.0` `hulat_dir` is no longer used because the test team committed `hulat/` to the repo (the dispatcher derives `HULAT_DIR=${REPO_PATH}/hulat`). Schedulers do NOT need to be updated to drop the field.

## Required inputs

| Field                   | Notes                                                                 |
| ----------------------- | --------------------------------------------------------------------- |
| `group`                 | GitLab group slug                                                     |
| `project`               | GitLab project slug                                                   |
| `branch`                | **Integration / target branch** (typically `master`). MRs are opened against this branch; spec accumulation happens here. |
| `dev_branch`            | **Clean baseline branch** (typically `dev`). Fresh-mode worktrees are checked out from `origin/${dev_branch}` so Claude Code starts from a clean tree without past spec accumulation. If the project does not maintain a separate clean baseline, set `dev_branch=<same-as-branch>` to fall back to single-branch behavior. |
| `gitlab_token`          | Token used by `glab auth login` against the deployment-pinned host    |
| `issue_min_iid`         | Integer, inclusive                                                    |
| `issue_max_iid`         | Integer, inclusive                                                    |
| `hourly_issue_quota`    | Integer. **In async-callback mode this is the per-scheduled-tick LAUNCH count** (how many `sessions_spawn` calls the orchestrator may issue this tick), NOT the completion count. Terminal completions are recorded on callback wake-ups, which do not consume launch budget. Independent of `max_concurrent_subagents` (which caps concurrent in-flight subagents). |
| `max_runtime_minutes`   | Integer wall-clock budget for this tick                               |
| `blocked_retry_limit`   | Integer                                                               |
| `blocked_cooldown_ticks`| Integer                                                               |

## Optional inputs

| Field                       | Notes                                                                                                                                              |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gitlab_address`            | Pure verification value. The host is pinned in `<workspace>/config/gitlab.env`; it is never derived from this field. If supplied, `scripts/glab_auth.sh` checks that it resolves to the same `host:port` and protocol as the pin and aborts on mismatch (exit 13). If omitted, the pin is used unconditionally. New triggers should omit this field. |
| `max_concurrent_subagents`  | Integer ≥ 1, defaults to `1` if omitted. Upper bound on concurrent issue subagents this orchestrator may have in flight at the same time (i.e., upper bound on `len(pending_subagents)`). **Different IIDs only — two attempts for the same IID never run concurrently regardless of this value.** Independent of `hourly_issue_quota`. When `=1`, exactly one subagent is in flight at any moment. See SOUL.md "Subagent Concurrency Policy" and SKILL.md "Concurrency Policy" for the full contract. |
| `stuck_after_minutes`       | Integer ≥ 5, defaults to `90`. A pending subagent that has not received a `RUN_CHILD_COMPLETION_CALLBACK` within this many minutes of `spawned_at` is evicted at the top of the next scheduled wake-up (synthesized as a Phase 6 blocked reply with `block_reason="no callback received within stuck_after_minutes"`). Bumping this number is appropriate when subagent runs are routinely close to `runTimeoutSeconds=3600` (60 minutes). Set lower (e.g. 30) only if you are confident the runtime delivers callbacks within seconds of subagent termination. |

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

`stuck_after_minutes` (when supplied) overrides the persisted value the same way `max_concurrent_subagents` does.

---

## Callback trigger: `RUN_CHILD_COMPLETION_CALLBACK`

Sent by the OpenClaw runtime when a subagent's terminal compact JSON is available. One callback per subagent termination. Wakes the same orchestrator session that issued the original `sessions_spawn`.

Recommended payload form:

```text
RUN_CHILD_COMPLETION_CALLBACK
project=<project>
group=<group>
gitlab_token=<token>
iid=<iid>
attempt_number=<attempt_number>
run_id=<runId from the launch ack>
child_session_key=<childSessionKey from the launch ack>
worker_status=<done|no_changes|blocked|failed>
worker_result_json=<the entire compact JSON line the subagent emitted>
```

### Required fields

| Field                | Notes                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------- |
| `project`            | GitLab project slug — needed for `glab` reconciliation on the callback path                    |
| `group`              | GitLab group slug                                                                              |
| `gitlab_token`       | Token for `glab auth login` against the deployment-pinned host                                 |
| `iid`                | The IID this callback is about. The orchestrator uses this to match a `pending_subagents` entry. |
| `attempt_number`     | Must equal `pending_subagents[iid].attempt_number`. Mismatch → callback treated as stale.       |
| `worker_result_json` | The exact compact JSON string the subagent emitted on its last turn (per `state_schema.md` §Compact Subagent Reply). The orchestrator parses THIS to drive Phase 6, not the loose `worker_status` field. |

### Optional but recommended

| Field                 | Notes                                                                                          |
| --------------------- | ---------------------------------------------------------------------------------------------- |
| `run_id`              | Must equal `pending_subagents[iid].run_id`. Mismatch → log a warning but still process by `iid`+`attempt_number` (the runtime may have allocated multiple runIds during retries — `iid`+`attempt_number` is the canonical identity). |
| `child_session_key`   | For audit / debugging only. Not load-bearing.                                                  |
| `worker_status`       | The `status` field from `worker_result_json`, hoisted for routing convenience. The orchestrator MUST still parse `worker_result_json` for the canonical value. |

### What the orchestrator does NOT need on the callback path

The callback payload does NOT need to carry: `branch`, `dev_branch`, `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, `max_concurrent_subagents`, `stuck_after_minutes`. Those are loaded from the persisted `${CAMPAIGN_STATE_FILE}`. The callback path does NOT apply trigger overrides.

### Behavior on missing / malformed callbacks

- Missing required field → orchestrator returns `"callback_status":"malformed"` with the missing field name and exits without state mutation. The runtime should log and not retry blindly.
- Unparseable `worker_result_json` → orchestrator synthesizes a Phase 6 blocked reply (`block_reason="callback worker_result_json not valid JSON"`) and processes it.
- `iid` not in `pending_subagents` OR `attempt_number` mismatch → `"callback_status":"stale_or_already_drained"`, no state mutation.

### Runtime delivery requirements

For this workspace's scheduling contract to hold, the runtime MUST:

1. Deliver `RUN_CHILD_COMPLETION_CALLBACK` to the SAME orchestrator session that issued the original `sessions_spawn` (typically `agent:acpx_auto_tester:main`).
2. Deliver the callback exactly once per subagent termination (idempotent retry by `run_id` + `iid` + `attempt_number` is acceptable; the orchestrator drops duplicates as `stale_or_already_drained`).
3. Carry the subagent's terminal compact JSON in `worker_result_json` verbatim — runtime MUST NOT alter, truncate, or re-serialize the JSON line.
4. Deliver the callback even if the subagent terminated abnormally (timeout, runtime error, manual cancel). In those cases `worker_status` should be `blocked` or `failed` and `worker_result_json` should be a synthetic minimal compact JSON the runtime constructs (with `iid`, `attempt_number`, `status`, `block_reason`, `skill_version`).

If (4) is not feasible on the deployment, the orchestrator's stuck-pending eviction (default 90 min after `spawned_at`) recovers — but at the cost of UI account lockup for that duration.
