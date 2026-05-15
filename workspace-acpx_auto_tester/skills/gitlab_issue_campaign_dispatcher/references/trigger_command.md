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

Older triggers may also include `gitlab_address=...` and/or `hulat_dir=...`. Both are still accepted but ignored — `gitlab_address` is now a verification-only field (see "Optional inputs" below), and `hulat_dir` is no longer used because the test team committed `hulat/` to the repo (the dispatcher derives `HULAT_DIR=${REPO_PATH}/hulat`). Schedulers do NOT need to be updated to drop the field.

## Required inputs

| Field                   | Notes                                                                 |
| ----------------------- | --------------------------------------------------------------------- |
| `group`                 | GitLab group slug                                                     |
| `project`               | GitLab project slug                                                   |
| `branch`                | **Integration / target branch** (typically `master`). MRs are opened against this branch; spec accumulation happens here. |
| `dev_branch`            | **Clean baseline branch** (typically `dev`). Fresh-mode attempts base their per-attempt linked git worktree on `origin/${dev_branch}` so Claude Code starts from a clean tree without past spec accumulation. If the project does not maintain a separate clean baseline, set `dev_branch=<same-as-branch>` to fall back to single-branch behavior. |
| `gitlab_token`          | Token used by `glab auth login` against the deployment-pinned host    |
| `issue_min_iid`         | Integer, inclusive                                                    |
| `issue_max_iid`         | Integer, inclusive                                                    |
| `hourly_issue_quota`    | Integer. **In async-callback mode this is the per-scheduled-tick LAUNCH count**, NOT the completion count. The dispatcher caps each tick's batch at `min(max_concurrent_subagents, hourly_issue_quota - quota_launched_this_tick, eligible_iids_remaining)`. |
| `max_runtime_minutes`   | Integer wall-clock budget for this tick                               |
| `blocked_retry_limit`   | Integer                                                               |
| `blocked_cooldown_ticks`| Integer                                                               |

## Optional inputs

| Field                       | Notes                                                                                                                                              |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gitlab_address`            | Pure verification value. The host is pinned in `<workspace>/config/gitlab.env`; it is never derived from this field. If supplied, `scripts/glab_auth.sh` checks that it resolves to the same `host:port` and protocol as the pin and aborts on mismatch (exit 13). If omitted, the pin is used unconditionally. New triggers should omit this field. |
| `repo_path`                 | Optional absolute parent directory for project clones. Forwarded as `REPO_PARENT_PATH=...` to scripts; `env_paths.sh` derives the final repo root as `${repo_path}/${project}` and defaults the parent to `/data` when omitted. Must be absolute and not `/`; values with `..`, whitespace, or shell-unsafe characters outside `[A-Za-z0-9_./-]` are rejected with `"invalid_repo_path"`. Non-default deployments MUST include the same parent on every scheduled trigger and callback because the dispatcher needs it before it can locate `${CAMPAIGN_STATE_FILE}`. |
| `max_concurrent_subagents`  | Integer. Caps per-tick batch size and maximum in-flight subagent count. Defaults to `1` when omitted. The post-override value MUST satisfy `1 ≤ value`. Values below 1 abort the tick with `"invalid_max_concurrent_subagents: must be >= 1"`. Each in-flight subagent runs in its own per-attempt linked git worktree at `${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>-att-<NNN>/`, so cross-IID parallelism is enabled at the working-tree level. All concurrent subagents share the same UI account — there is no pool-size upper bound. |
| `stuck_after_minutes`       | Integer ≥ 5, defaults to `330`. A pending subagent that has not received a `RUN_CHILD_COMPLETION_CALLBACK` within this many minutes of `spawned_at` is evicted at the top of the next scheduled wake-up (synthesized as a Phase 6 blocked reply with `block_reason="no callback received within stuck_after_minutes"`). Bumping this number is appropriate when subagent runs are routinely close to `runTimeoutSeconds=18000` (300 minutes). Set lower (e.g. 30) only if you are confident the runtime delivers callbacks within seconds of subagent termination. |
| `acpx_resume`               | Boolean, defaults to `false`. When `true`, the dispatcher will attempt to resume the previous acpx Claude Code session after an interruption: if `attempts_total > 0` (not the first attempt), Phase 4 sets `ACPX_RESUME=true` so `build_prompt.sh` writes a step-aware resume prompt instead of the full task prompt. The resume prompt lists the three hulat sub-agents (detector / testcase-generator / executor), instructs Claude Code to inspect `${OUTPUT_DIR}` on startup, and selectively invoke only the agents whose output is missing — e.g. if step2's test cases are already complete, only step3 (executor) is invoked. The acpx invocation `-s issue-<iid>` reopens the persisted Claude Code session so the full conversation history from the prior run is still in context. When `false` or on the first attempt, the full task prompt is used. Does not force `ISSUE_MODE=continue` — the worktree setup follows the normal reconciliation result. |
| `kill_subagent_on_terminal` | Boolean, defaults to `true` when omitted. When true, Phase 6 step 9 calls the runtime-side `subagents` tool with `action="kill"` and `target=<child_session_key>` after terminal `done` / `blocked` / `failed` outcomes drain, releasing the subagent's runtime session and transcript-store entry so OpenClaw does not bloat over a long campaign. For `blocked` / `failed`, cleanup is gated on local evidence existing under `${LOG_DIR}` / `${ISSUE_ROOT}`; failure paths do not publish Wiki evidence. Cleanup is best-effort: failure of `subagents kill` does NOT mutate state files or re-classify the IID, only adds `cleanup_status` to the chat summary. Truthy values (case-insensitive): `true`, `1`, `yes`. Falsy: `false`, `0`, `no`. Any other value aborts the tick with `"invalid_kill_subagent_on_terminal"`. |
| `kill_subagent_on_done`     | Legacy Boolean kept for backward compatibility. New triggers should use `kill_subagent_on_terminal`. If `kill_subagent_on_terminal` is omitted and legacy `kill_subagent_on_done=false` is present, terminal cleanup is disabled. Otherwise this field is ignored. |
| `issue_iids`                | Comma-separated integers (e.g. `14,17,20`). Optional whitelist applied **on top of** `[issue_min_iid, issue_max_iid]`. When non-empty, the effective IID universe for this tick = `[issue_min_iid, issue_max_iid] ∩ issue_iids`. IIDs in `issue_iids` that fall outside the range are silently dropped. Whitespace around commas is tolerated. When omitted or empty, no whitelist is applied (the full range is used — current default behavior). **Stuck-pending eviction is NOT subject to this filter** — already in-flight subagents are always evicted by the `stuck_after_minutes` rule regardless of whether their IID is still in the whitelist. |
| `require_labels`            | Comma-separated GitLab label names (e.g. `acpx-auto,priority::high`). Optional inclusion filter on live GitLab labels (read from the Phase 2 reconcile evidence file). When non-empty, only IIDs whose live labels satisfy the match (combined with `require_labels_match` below) are considered for batching in Phase 3. Match is case-sensitive (GitLab labels are case-sensitive). Whitespace around commas is tolerated; whitespace inside a label name is preserved. When omitted or empty, no label filter is applied — current default behavior. **Does not affect stuck-pending eviction.** |
| `require_labels_match`      | `or` (default) or `and`. Only meaningful when `require_labels` is non-empty. `or` = IID passes if its live labels include **at least one** of `require_labels`. `and` = IID passes only if its live labels include **all** of `require_labels`. When `require_labels` is empty, this field is ignored. Any other value → tick aborts with `"invalid_require_labels_match"`. |
| `result_basename`           | Optional. Basename of the agent runtime root **inside the cloned project repo**. The orchestrator forwards this value to every script as `RESULT_BASENAME=...`, and `env_paths.sh` derives `RESULT_ROOT=${REPO_PATH}/${RESULT_BASENAME}`. Use this when the test team renames the runtime directory under a per-project convention (e.g. `pts-result` for the PTS project). When the trigger supplies the field, it overrides the persisted value; when omitted, the dispatcher keeps the persisted value (or `ifp-result` on a fresh deployment) — basenames are deployment-stable per project, so omission is treated as "no change", NOT as "reset to default". |
| `data_basename`             | Optional. Basename of the test team's knowledge directory inside the repo. Forwarded as `DATA_BASENAME=...`; rendered into the subagent prompt's `<config>` block and Step 0 directory check. Same persistence semantics as `result_basename` (default `ifp-data` on fresh deployment; otherwise carry-forward). |
| `claude_settings_path`      | Optional absolute path to a Claude Code settings JSON file. When provided, the dispatcher copies this file to `${REPO_PATH}/.claude/settings.json` (replacing the committed settings) during Phase 4 per-IID prep, BEFORE the subagent runs `acpx claude exec`. Then runs `git update-index --skip-worktree .claude/settings.json` inside the parent checkout so the replacement is never staged into issue MRs. Must be an absolute file path; values with `..`, whitespace, or shell-unsafe characters outside `[A-Za-z0-9_./-]` are rejected with `"invalid_claude_settings_path"`. The file must exist and be readable at copy time; a missing/unreadable file marks the IID `blocked`. Omitted or empty → the committed `.claude/settings.json` from the base branch is used as-is. |

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

`max_concurrent_subagents` (when supplied) is also applied as an override using the same rule: write the trigger value into `campaign_state.json.max_concurrent_subagents`. When the trigger omits it, the dispatcher MUST default the field to `1` for the tick AND persist that default so the disk schema stays consistent across versions. The post-override value MUST satisfy `1 ≤ max_concurrent_subagents`; values below 1 abort the tick with `"invalid_max_concurrent_subagents: must be >= 1"`. All concurrent subagents share the same UI account — there is no pool-size upper bound.

`gitlab_address` (when supplied) is NOT applied as an override — it is used only for the cross-check above. The pin in `<workspace>/config/gitlab.env` is the single source of truth for host / protocol.

`repo_path` is a bootstrap path input, not a carry-forward value. When the trigger supplies it, validate that it is an absolute parent directory path (reject `/`, dot segments, whitespace, and shell-unsafe characters outside `[A-Za-z0-9_./-]`; abort with `"invalid_repo_path"` on violation) and forward it as `REPO_PARENT_PATH=...` to scripts. `env_paths.sh` derives the final repo root as `${repo_path}/${project}`. When the trigger omits it, the tick uses the legacy default parent `/data`, so the final repo root remains `/data/${project}`. Because `repo_path` determines where `${CAMPAIGN_STATE_FILE}` lives, a non-default deployment must keep passing it on every scheduled trigger and callback.

`stuck_after_minutes` (when supplied) overrides the persisted value the same way `max_concurrent_subagents` does.

`acpx_resume` (when supplied) overrides the persisted value with the same "trigger-wins each tick + persist the post-override value" rule. When omitted, defaults to `false` and persist. The persisted value is consulted in Phase 4 Step 1.5 to decide whether to write a resume prompt.

`kill_subagent_on_terminal` (when supplied) overrides the persisted value with the same "trigger-wins each tick + persist the post-override value" rule. When omitted, the dispatcher MUST default the field to `true` for the tick AND persist that default into `campaign_state.json.kill_subagent_on_terminal`, except for the legacy compatibility case where `kill_subagent_on_done=false` is present and the new field is omitted; in that case persist `kill_subagent_on_terminal=false`. The post-override boolean is consulted by Phase 6 step 9 for both callback and inline-synthesized terminal outcomes; toggling it on a later tick takes effect immediately for the next callback wake-up. The callback path does NOT re-read the trigger override (callbacks carry no scalar inputs) — the persisted value from the most recent scheduled wake-up is authoritative.

`issue_iids`, `require_labels`, and `require_labels_match` (when supplied) override the persisted values the same way the other scalars do — each tick takes whatever the trigger says (or "unset / empty" when the trigger omits the field). The dispatcher persists the post-override values into `campaign_state.json.issue_iids_whitelist` / `.require_labels` / `.require_labels_match` for audit, but does NOT carry a stale whitelist forward when the next trigger drops the field. Stuck-pending eviction is performed BEFORE the new whitelist takes effect, so an in-flight subagent whose IID is removed from the whitelist on this tick still gets its eviction processed (it is NOT silently abandoned).

`result_basename` / `data_basename` use **carry-forward** semantics, NOT the per-tick reset rule used by `max_concurrent_subagents` / `stuck_after_minutes`. When the trigger supplies a value, the dispatcher writes it into `campaign_state.json` and uses it for this tick. When the trigger omits the field, the dispatcher keeps the persisted value; on a fresh deployment with no persisted value, it falls back to the hardcoded defaults (`ifp-result` / `ifp-data`). The reason for the difference: project-local directory names are a deployment property, not a per-tick decision — schedulers should not have to repeat them every tick to keep the project running. Both basenames must be plain directory names — a value containing `/`, `..`, or whitespace aborts the tick with `"invalid_result_basename"` / `"invalid_data_basename"`. Once set for a project, do NOT toggle the values mid-campaign without first migrating the existing on-disk runtime root: the dispatcher will start writing state to a fresh subtree under the new basename.

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
worker_status=<done|blocked|failed>   # no_changes is accepted only for legacy callbacks and normalized to blocked
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

The callback payload does NOT need to carry: `branch`, `dev_branch`, `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, `max_concurrent_subagents`, `stuck_after_minutes`, `kill_subagent_on_terminal`, `kill_subagent_on_done`. Those are loaded from the persisted `${CAMPAIGN_STATE_FILE}`. The callback path does NOT apply trigger overrides.

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

If (4) is not feasible on the deployment, the orchestrator's stuck-pending eviction (default 330 min after `spawned_at`) recovers — but at the cost of UI account lockup for that duration.
