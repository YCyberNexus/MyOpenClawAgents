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

## Required inputs

| Field                   | Notes                                                                 |
| ----------------------- | --------------------------------------------------------------------- |
| `group`                 | GitLab group slug                                                     |
| `project`               | GitLab project slug                                                   |
| `branch`                | **Integration / target branch** (typically `master`). MRs are opened against this branch; spec accumulation happens here. |
| `dev_branch`            | **Clean baseline branch** (typically `dev`). Fresh-mode attempts reset the shared per-issue worktree's tracked files to `origin/${dev_branch}` and quarantine same-IID runtime residue before recreating empty current output/log directories, so Claude Code starts without past same-IID spec output. If the project does not maintain a separate clean baseline, set `dev_branch=<same-as-branch>` to fall back to single-branch behavior. |
| `gitlab_token`          | Token used by `glab auth login` against the deployment-pinned host    |
| `issue_min_iid`         | Integer, inclusive                                                    |
| `issue_max_iid`         | Integer, inclusive                                                    |
| `hourly_issue_quota`    | Integer. **In async-callback mode this is the per-scheduled-tick LAUNCH count**, NOT the completion count. The dispatcher caps each tick's batch at `min(max_concurrent_subagents, hourly_issue_quota - quota_launched_this_tick, eligible_iids_remaining)`. |
| `max_runtime_minutes`   | Integer wall-clock budget for this scheduled tick's pre-launch wrapper work. If the budget is already exhausted before batch formation, the wrapper returns `status:"no_eligible_iids"` with a `time_budget` chat summary. Callback wake-ups ignore this budget and always process the terminal IID. |
| `blocked_retry_limit`   | Integer                                                               |
| `blocked_cooldown_ticks`| Integer scheduled-wake cooldown before a blocked IID becomes retryable. Implemented with `campaign_state.json.tick_seq` and `blocked_at_tick_by_iid`; legacy blocked entries with no timestamp are treated as immediately retryable. |

## Optional inputs

| Field                       | Notes                                                                                                                                              |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gitlab_address`            | Pure verification value. The host is pinned in `<workspace>/config/gitlab.env`; it is never derived from this field. If supplied, `scripts/glab_auth.sh` checks that it resolves to the same `host:port` and protocol as the pin and aborts on mismatch (exit 13). If omitted, the pin is used unconditionally. New triggers should omit this field. |
| `repo_path`                 | Optional absolute parent directory for project clones. Forwarded as `REPO_PARENT_PATH=...` to scripts; `env_paths.sh` derives the final repo root as `${repo_path}/${project}` and defaults the parent to `/data` when omitted. Must be absolute and not `/`; values with `..`, whitespace, or shell-unsafe characters outside `[A-Za-z0-9_./-]` are rejected with `"invalid_repo_path"`. Non-default deployments MUST include the same parent on every scheduled trigger and callback because the dispatcher needs it before it can locate `${CAMPAIGN_STATE_FILE}`. |
| `max_concurrent_subagents`  | Integer. Caps per-tick batch size and maximum in-flight subagent count. Defaults to `1` when omitted. The post-override value MUST satisfy `1 ≤ value ≤ ui_account_pool_size` (the pool is read from `${REPO_PATH}/${ui_accounts_relpath}` — see the `ui_accounts_relpath` row below; default relpath `ifp-data/ifp-common/ifp_users.json` — and divided into exactly `max_concurrent_subagents` per-IID slots, so a value above the pool size cannot give every concurrent subagent at least one distinct account). Values below 1 abort the tick with `"invalid_max_concurrent_subagents: must be >= 1"`; values exceeding the pool abort with `"ui_account_pool_too_small: pool=<size> max_concurrent_subagents=<value>"`. Each in-flight IID runs in its own shared per-issue linked git worktree at `${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>/` (one worktree per IID, reused across attempts of that IID), so cross-IID parallelism is enabled at the working-tree level; the UI account pool is the binding limit because the system under test logs out an account on duplicate login. |
| `max_accounts_per_issue`   | Integer. Caps how many UI accounts any one IID/subagent receives after the account pool is divided by `max_concurrent_subagents`. Defaults to `14` when omitted. Values below 1 or non-integers abort the tick with `"invalid_max_accounts_per_issue: must be >= 1"`. **Per-IID account counts are derived automatically** as `min(floor(pool_size / max_concurrent_subagents) plus front-loaded remainder, max_accounts_per_issue)`. Examples with default cap 14: `pool=3, max=2 → slot sizes 2,1`; `pool=50, max=4 → slot sizes 13,13,12,12`; `pool=40, max=1 → slot size 14`. |
| `stuck_after_minutes`       | Integer ≥ 5, defaults to `ceil(run_timeout_seconds / 60) + 30` (i.e. `332` when `run_timeout_seconds` is also omitted at its default 18120s). A pending subagent that has not received a `RUN_CHILD_COMPLETION_CALLBACK` within this many minutes of `spawned_at` is evicted at the top of the next scheduled wake-up (synthesized as a Phase 6 blocked reply with `block_reason="no callback received within stuck_after_minutes"`). The default tracks `run_timeout_seconds` automatically, so bumping `acpx_timeout_seconds` (and therefore `run_timeout_seconds`) on a long-running campaign no longer requires also bumping this field. Values below 5 or non-integers abort with `"invalid_stuck_after_minutes: must be >= 5"`. Explicit overrides are still allowed — e.g. set lower to release UI accounts faster on a deployment with reliable callback delivery, or set higher to never evict. |
| `run_timeout_seconds`       | Integer ≥ 60, defaults to `acpx_timeout_seconds + 120` (18120s / 302 minutes when `acpx_timeout_seconds` is also omitted). Forwarded as the `runTimeoutSeconds=<value>` parameter to every `sessions_spawn` call — caps how long the OpenClaw runtime allows a subagent to run before it forcibly terminates and (per the callback contract) delivers a synthetic `RUN_CHILD_COMPLETION_CALLBACK` with `worker_status=blocked` or `failed`. The post-override value MUST satisfy `run_timeout_seconds ≥ acpx_timeout_seconds + 120`; violation aborts the tick with `"run_timeout_seconds_below_acpx_timeout_seconds_plus_120"`. Values below 60 or non-integers abort with `"invalid_run_timeout_seconds: must be >= 60"`. Same per-tick reset / persist semantics as `max_concurrent_subagents` / `stuck_after_minutes` — see "Trigger-input override" below. `stuck_after_minutes` automatically tracks this value via its own derived default; an explicit `stuck_after_minutes` override that is materially smaller than `ceil(run_timeout_seconds / 60) + 30` will evict still-running subagents before the runtime's own timeout fires. |
| `acpx_timeout_seconds`      | Integer ≥ 60, defaults to `18000` (300 minutes / 5 hours). Substituted into the rendered executor prompt as `{ACPX_TIMEOUT_SECONDS}` (subagent Step 1 bash command timeout when invoking `run_acpx_attempt.sh`) AND as `{ACPX_TIMEOUT_MINUTES}` (= `floor(acpx_timeout_seconds / 60)`, used for the executor's hard wall-clock soft cap). Bumping this is appropriate when individual acpx claude exec runs need more than 5 hours. Values below 60 or non-integers abort with `"invalid_acpx_timeout_seconds: must be >= 60"`. Must satisfy `acpx_timeout_seconds + 120 ≤ run_timeout_seconds` (the inner bash timeout needs two minutes of outer runtime headroom to return 124/137 before the subagent is killed). Same per-tick reset / persist semantics as `run_timeout_seconds`. |
| `kill_subagent_on_terminal` | Boolean, defaults to `true` when omitted. When true, Phase 6 may return `cleanup.action="kill"` with `target=<child_session_key>` after terminal `done` / `blocked` / `failed` / `timeout` outcomes drain, releasing the subagent's runtime session and transcript-store entry so OpenClaw does not bloat over a long campaign. For `blocked` / `failed` / `timeout`, cleanup is gated on local evidence existing under `${LOG_DIR}` / `${ISSUE_ROOT}`; failure paths do not publish Wiki evidence. Cleanup is best-effort: failure of `subagents kill` does NOT mutate state files or re-classify the IID, only affects chat output. Truthy values (case-insensitive): `true`, `1`, `yes`. Falsy: `false`, `0`, `no`. Any other value aborts the tick with `"invalid_kill_subagent_on_terminal"`. |
| `kill_subagent_on_done`     | Legacy Boolean kept for backward compatibility. New triggers should use `kill_subagent_on_terminal`. If `kill_subagent_on_terminal` is omitted and legacy `kill_subagent_on_done=false` is present, terminal cleanup is disabled. Otherwise this field is ignored. |
| `issue_iids`                | Comma-separated integers (e.g. `14,17,20`). Optional whitelist applied **on top of** `[issue_min_iid, issue_max_iid]`. When non-empty, the effective IID universe for this tick = `[issue_min_iid, issue_max_iid] ∩ issue_iids`. IIDs in `issue_iids` that fall outside the range are silently dropped. Whitespace around commas is tolerated. When omitted or empty, no whitelist is applied (the full range is used — current default behavior). If an already-pending subagent's IID falls outside the new effective universe, the scheduled tick scope-evicts it before batching: the issue is drained and marked `blocked`, and the envelope carries a `cleanup_actions[]` kill request for the recorded child session key when available. |
| `require_labels`            | Comma-separated GitLab label names (e.g. `acpx-auto,priority::high`). Optional inclusion filter on live GitLab labels (read from the Phase 2 reconcile evidence file). When non-empty, only IIDs whose live labels satisfy the match (combined with `require_labels_match` below) are considered for batching in Phase 3. Match is case-sensitive (GitLab labels are case-sensitive). Whitespace around commas is tolerated; whitespace inside a label name is preserved. When omitted or empty, no label filter is applied — current default behavior. **Does not affect pending eviction**; it only filters future batch selection. |
| `require_labels_match`      | `or` (default) or `and`. Only meaningful when `require_labels` is non-empty. `or` = IID passes if its live labels include **at least one** of `require_labels`. `and` = IID passes only if its live labels include **all** of `require_labels`. When `require_labels` is empty, this field is ignored. Any other value → tick aborts with `"invalid_require_labels_match"`. |
| `result_basename`           | Optional. Basename of the agent runtime root **inside the cloned project repo**. The orchestrator forwards this value to every script as `RESULT_BASENAME=...`, and `env_paths.sh` derives `RESULT_ROOT=${REPO_PATH}/${RESULT_BASENAME}`. Use this when the test team renames the runtime directory under a per-project convention (e.g. `pts-result` for the PTS project). When the trigger supplies the field, it overrides the persisted value; when omitted, the dispatcher keeps the persisted value (or `ifp-result` on a fresh deployment) — basenames are deployment-stable per project, so omission is treated as "no change", NOT as "reset to default". |
| `data_basename`             | Optional. Basename of the test team's knowledge directory inside the repo. Forwarded as `DATA_BASENAME=...`; rendered into the subagent prompt's `<config>` block and Step 0 directory check. Same persistence semantics as `result_basename` (default `ifp-data` on fresh deployment; otherwise carry-forward). |
| `ui_accounts_relpath`       | Optional. Relative path of the test team's UI account pool JSON file under `${REPO_PATH}` (the project checkout root), NOT under `${REPO_PATH}/${DATA_BASENAME}/`. The relpath itself names the leading directory — on the default deployment that first segment is `${DATA_BASENAME}` (e.g. `ifp-data/...`), but the pool file may live under any other directory inside the repo. Defaults to `ifp-data/ifp-common/ifp_users.json` on fresh deployment. Forwarded as `UI_ACCOUNTS_RELPATH=...` to `scripts/load_ui_accounts.sh`, which derives the absolute pool file path `${REPO_PATH}/${ui_accounts_relpath}`. Use this when the test team stores the pool under a project-specific layout (e.g. `pts-data/pts-common/pts_users.json`, or even an out-of-data directory like `qa-config/users.json`). Must be a non-empty relative path with no leading `/`, no `.` / `..` segments, no whitespace, and characters limited to `[A-Za-z0-9_./-]`; any violation aborts the tick with `"invalid_ui_accounts_relpath"`. Same carry-forward persistence semantics as `result_basename` / `data_basename`: when the trigger supplies a value the dispatcher writes it into `campaign_state.json.ui_accounts_relpath` and uses it for this tick; when omitted it keeps the persisted value (or the default on a fresh deployment). **Schema migration note:** before SKILL_VERSION 2026-05-27.1 this field was resolved under `${REPO_PATH}/${DATA_BASENAME}/`; deployments with a persisted carry-forward value like `ifp-common/ifp_users.json` MUST re-send the trigger with `ui_accounts_relpath=${DATA_BASENAME}/ifp-common/ifp_users.json` (e.g. `ifp-data/ifp-common/ifp_users.json`) once after the upgrade, or `load_ui_accounts.sh` will report `ui_accounts_pool_file_missing` with a migration hint. |
| `claude_settings_path`      | Optional absolute path to a Claude Code settings JSON file. When provided, the dispatcher copies this file to `${WORKTREE_DIR}/.claude/settings.json` (replacing the committed settings) during Phase 4 per-IID prep, BEFORE the subagent runs `scripts/run_acpx_attempt.sh` (which invokes `acpx claude exec`). Then runs `git update-index --skip-worktree .claude/settings.json` inside the worktree so the replacement is never staged into issue MRs. The flag is per-worktree (linked worktrees have independent indexes), so concurrent attempts are unaffected. Must be an absolute file path; values with `..`, whitespace, or shell-unsafe characters outside `[A-Za-z0-9_./-]` are rejected with `"invalid_claude_settings_path"`. The file must exist and be readable at copy time; a missing/unreadable file marks the IID `blocked`. Omitted or empty → the committed `.claude/settings.json` from the base branch is used as-is. |

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

`max_concurrent_subagents` (when supplied) is also applied as an override using the same rule: write the trigger value into `campaign_state.json.max_concurrent_subagents`. When the trigger omits it, the dispatcher MUST default the field to `1` for the tick AND persist that default so the disk schema stays consistent across versions. The post-override value MUST satisfy `1 ≤ max_concurrent_subagents ≤ ui_account_pool_size` (after `clone_or_pull.sh`, call `MAX_CONCURRENT_SUBAGENTS=<max_concurrent_subagents> MAX_ACCOUNTS_PER_ISSUE=<max_accounts_per_issue> UI_ACCOUNTS_RELPATH=<ui_accounts_relpath> bash scripts/load_ui_accounts.sh`; it reads `${REPO_PATH}/${ui_accounts_relpath}`, and exit 13 maps to `"ui_account_pool_too_small: pool=<size> max_concurrent_subagents=<value>"`). Values below 1 abort the tick with `"invalid_max_concurrent_subagents: must be >= 1"`.

`max_accounts_per_issue` (when supplied) is also applied as an override using the same rule: write the trigger value into `campaign_state.json.max_accounts_per_issue`. When the trigger omits it, the dispatcher MUST default the field to `14` for the tick AND persist that default. The post-override value MUST be a positive integer; values below 1 or non-integers abort the tick with `"invalid_max_accounts_per_issue: must be >= 1"`. Per-IID account counts are derived automatically from the pool size, `max_concurrent_subagents`, and `max_accounts_per_issue`.

`gitlab_address` (when supplied) is NOT applied as an override — it is used only for the cross-check above. The pin in `<workspace>/config/gitlab.env` is the single source of truth for host / protocol.

`repo_path` is a bootstrap path input, not a carry-forward value. When the trigger supplies it, validate that it is an absolute parent directory path (reject `/`, dot segments, whitespace, and shell-unsafe characters outside `[A-Za-z0-9_./-]`; abort with `"invalid_repo_path"` on violation) and forward it as `REPO_PARENT_PATH=...` to scripts. `env_paths.sh` derives the final repo root as `${repo_path}/${project}`. When the trigger omits it, the tick uses the legacy default parent `/data`, so the final repo root remains `/data/${project}`. Because `repo_path` determines where `${CAMPAIGN_STATE_FILE}` lives, a non-default deployment must keep passing it on every scheduled trigger and callback.

`stuck_after_minutes` (when supplied) overrides the persisted value the same way `max_concurrent_subagents` does. When omitted, it defaults to `ceil(run_timeout_seconds / 60) + 30` (332 when both timeout fields are also omitted). Values below 5 or non-integers abort with `"invalid_stuck_after_minutes: must be >= 5"`.

`run_timeout_seconds` (when supplied) overrides the persisted value the same way `max_concurrent_subagents` does: write the trigger value into `campaign_state.json.run_timeout_seconds` and use it for this tick. When the trigger omits the field, default to `acpx_timeout_seconds + 120` for the tick AND persist that default so the disk schema stays consistent across versions. With the default `acpx_timeout_seconds=18000`, the default `run_timeout_seconds` is `18120`. Validation: integer ≥ 60 (values below 60 or non-integers abort `"invalid_run_timeout_seconds: must be >= 60"`) AND `≥ acpx_timeout_seconds + 120` (else abort `"run_timeout_seconds_below_acpx_timeout_seconds_plus_120"`). The post-override value is consulted by Phase 5 when constructing `sessions_spawn(..., runTimeoutSeconds=<run_timeout_seconds>, ...)`.

`acpx_timeout_seconds` (when supplied) overrides the persisted value the same way. When the trigger omits the field, default to `18000` for the tick AND persist that default. Validation: integer ≥ 60 (values below 60 or non-integers abort `"invalid_acpx_timeout_seconds: must be >= 60"`) AND `acpx_timeout_seconds + 120 ≤ run_timeout_seconds` (same combined check as above). The post-override value is rendered into the executor prompt in Phase 4 step 7 as both `{ACPX_TIMEOUT_SECONDS}` and `{ACPX_TIMEOUT_MINUTES}` (= `floor(acpx_timeout_seconds / 60)`) — the subagent uses these for its Step 1 bash command timeout and the overall hard-cap message respectively, so the two values stay in lockstep.

`kill_subagent_on_terminal` (when supplied) overrides the persisted value with the same "trigger-wins each tick + persist the post-override value" rule. When omitted, the dispatcher MUST default the field to `true` for the tick AND persist that default into `campaign_state.json.kill_subagent_on_terminal`, except for the legacy compatibility case where `kill_subagent_on_done=false` is present and the new field is omitted; in that case persist `kill_subagent_on_terminal=false`. The post-override boolean is consulted by Phase 6 step 9 for both callback and inline-synthesized terminal outcomes; toggling it on a later tick takes effect immediately for the next callback wake-up. The callback path does NOT re-read the trigger override (callbacks carry no scalar inputs) — the persisted value from the most recent scheduled wake-up is authoritative.

`issue_iids`, `require_labels`, and `require_labels_match` (when supplied) override the persisted values the same way the other scalars do — each tick takes whatever the trigger says (or "unset / empty" when the trigger omits the field). The dispatcher persists the post-override values into `campaign_state.json.issue_iids_whitelist` / `.require_labels` / `.require_labels_match` for audit, but does NOT carry a stale whitelist forward when the next trigger drops the field. The new effective `issue_iids ∩ [issue_min_iid,issue_max_iid]` scope takes effect before the waiting-for-callbacks gate: any pending IID outside that scope is scope-evicted, marked `blocked`, and returned in `scope_evicted_iids` with a best-effort `cleanup_actions[]` kill target when the child session key is known. `require_labels` is not a pending-scope control; it only filters future batch selection after reconcile.

`result_basename` / `data_basename` / `ui_accounts_relpath` use **carry-forward** semantics, NOT the per-tick reset rule used by `max_concurrent_subagents` / `stuck_after_minutes`. When the trigger supplies a value, the dispatcher writes it into `campaign_state.json` and uses it for this tick. When the trigger omits the field, the dispatcher keeps the persisted value; on a fresh deployment with no persisted value, it falls back to the hardcoded defaults (`ifp-result` / `ifp-data` / `ifp-data/ifp-common/ifp_users.json`). The reason for the difference: project-local directory names and the UI account pool location are deployment properties, not per-tick decisions — schedulers should not have to repeat them every tick to keep the project running. Both basenames must be plain directory names — a value containing `/`, `..`, or whitespace aborts the tick with `"invalid_result_basename"` / `"invalid_data_basename"`. `ui_accounts_relpath` is now resolved under `${REPO_PATH}` (NOT under `${REPO_PATH}/${DATA_BASENAME}/`) so the pool file may live under any repo subdirectory, not just the data dir; it must be a non-empty relative path with no leading `/`, no `.` / `..` segments, no whitespace, and characters limited to `[A-Za-z0-9_./-]`; any violation aborts the tick with `"invalid_ui_accounts_relpath"`. Once set for a project, do NOT toggle the values mid-campaign without first migrating the existing on-disk runtime root (or UI account pool file): the dispatcher will start writing state — or reading credentials — under the new layout. **Schema migration:** before SKILL_VERSION 2026-05-27.1 `ui_accounts_relpath` resolved under `${REPO_PATH}/${DATA_BASENAME}/`. A deployment that previously persisted `ui_accounts_relpath=ifp-common/ifp_users.json` (or any other `${DATA_BASENAME}`-relative value) MUST re-send the trigger with that value prefixed by `${DATA_BASENAME}/` exactly once after the upgrade (e.g. `ui_accounts_relpath=ifp-data/ifp-common/ifp_users.json`); the dispatcher persists the corrected value and subsequent ticks may omit the field again. Without the one-time re-send the tick aborts with `ui_accounts_pool_file_missing` and a hint that names both the actual and the legacy resolved paths.

---

## Callback trigger: `RUN_CHILD_COMPLETION_CALLBACK`

Sent by the OpenClaw runtime when a subagent's terminal compact JSON is available. One callback per subagent termination. Wakes the same orchestrator session that issued the original `sessions_spawn`.

Recommended payload form:

```text
RUN_CHILD_COMPLETION_CALLBACK
project=<project>
group=<group>
gitlab_token=<token>
repo_path=<same non-default repo_path, when used by the scheduled trigger>
iid=<iid>
attempt_number=<attempt_number>
run_id=<runId from the launch ack>
child_session_key=<childSessionKey from the launch ack>
worker_status=<done|blocked|failed|timeout>   # no_changes is accepted only for legacy callbacks and normalized to blocked
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
| `repo_path`           | Required when the scheduled trigger used a non-default clone parent. Forward as `REPO_PARENT_PATH=...` before sourcing `env_paths.sh`; when omitted, the callback path uses parent `/data` and final repo root `/data/${project}`. |

### What the orchestrator does NOT need on the callback path

The callback payload does NOT need to carry: `branch`, `dev_branch`, `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, `max_concurrent_subagents`, `max_accounts_per_issue`, `stuck_after_minutes`, `run_timeout_seconds`, `acpx_timeout_seconds`, `kill_subagent_on_terminal`, `kill_subagent_on_done`, `result_basename`, `data_basename`, `ui_accounts_relpath`. Those are loaded from the persisted `${CAMPAIGN_STATE_FILE}`. The callback path does NOT apply trigger overrides.

### Behavior on missing / malformed callbacks

- Missing required field → orchestrator returns `"callback_status":"malformed"` with the missing field name and exits without state mutation. The runtime should log and not retry blindly.
- Unparseable `worker_result_json` → orchestrator synthesizes a Phase 6 blocked reply (`block_reason="callback worker_result_json not valid JSON"`) and processes it.
- `iid` not in `pending_subagents` OR `attempt_number` mismatch → `"callback_status":"stale_or_already_drained"`, no state mutation.

### Runtime delivery requirements

For this workspace's scheduling contract to hold, the runtime MUST:

1. Deliver `RUN_CHILD_COMPLETION_CALLBACK` to the SAME orchestrator session that issued the original `sessions_spawn` (typically `agent:acpx_auto_tester:main`).
2. Deliver the callback exactly once per subagent termination (idempotent retry by `run_id` + `iid` + `attempt_number` is acceptable; the orchestrator drops duplicates as `stale_or_already_drained`).
3. Carry the subagent's terminal compact JSON in `worker_result_json` verbatim — runtime MUST NOT alter, truncate, or re-serialize the JSON line.
4. Deliver the callback even if the subagent terminated abnormally (timeout, runtime error, manual cancel). In those cases `worker_status` should be `blocked` or `failed` and `worker_result_json` should be a synthetic minimal compact JSON the runtime constructs (with `iid`, `attempt_number`, `status`, `block_reason`).

If (4) is not feasible on the deployment, the orchestrator's stuck-pending eviction (`stuck_after_minutes`, defaulting to `ceil(run_timeout_seconds / 60) + 30` after `spawned_at`) recovers — but at the cost of UI account lockup for that duration.
