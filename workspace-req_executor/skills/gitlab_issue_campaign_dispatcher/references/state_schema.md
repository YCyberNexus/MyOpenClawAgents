# State File Schemas

Disk state is a **cache**, not source of truth. GitLab is the source of truth (see Source-of-Truth Policy in `SKILL.md`). These files exist for progress tracking and resumption only.

There are three state (cache) files in this workspace:

| File                                            | Owner                          | Lifecycle                                     |
| ----------------------------------------------- | ------------------------------ | --------------------------------------------- |
| `_dispatcher/campaign_state.json`               | dispatcher (campaign-level)    | persisted across ticks; mutated each tick     |
| `<RESULT_BASENAME>/issues/issue-<iid>/state.json`         | dispatcher (cross-attempt)     | persisted across attempts; one per IID        |
| `<RESULT_BASENAME>/issues/issue-<iid>/attempt_state.json` | dispatcher (per-attempt)       | overwritten on each new attempt               |

A fourth per-issue file — `<RESULT_BASENAME>/issues/issue-<iid>/dispatch_origin.json` — exists ONLY on the driven `RUN_SINGLE_ISSUE` path. It is not a workflow-state cache (it carries no labels/status and is never reconciled); it records the cross-agent origin so Phase 6 can report the terminal result back to `req_dispatcher`. See §dispatch_origin.json below.

**State-file write ownership:** the **dispatcher writes all state files**, including the terminal updates. The dispatcher's Phase 4 (per-IID prep) initializes the in-progress values in `issue-<iid>/state.json` and `issue-<iid>/attempt_state.json`. The subagent's compact JSON reply (see §Compact Subagent Reply below) carries every fact the dispatcher needs; the dispatcher's Phase 6 follow-up writes the terminal values from that reply. The subagent does NOT touch any state file.

**Wrapper-side writes (post-refactor).** As of `SKILL_VERSION=2026-05-18.x`, every dispatcher-side state write is performed by one of three shell wrappers under `scripts/` (see [`dispatcher_wrappers.md`](dispatcher_wrappers.md)), NOT by the orchestrator LLM directly:

| Wrapper | Writes |
| ------- | ------ |
| `dispatch_prepare_tick.sh` | `campaign_state.json` (trigger overrides, scope/stuck-eviction Phase 6 results, post-reconcile cache correction, batch placeholders); per-IID `state.json` + `attempt_state.json` initial `status=in_progress` blocks; `${LOG_DIR}/spawn_payload.txt` (the rendered executor prompt). |
| `dispatch_record_spawn.sh` | `campaign_state.json` (post-launch ack writeback of `run_id` / `child_session_key` / `spawned_at`, or — on launch failure — Phase 6 blocked synth + drain). |
| `dispatch_followup.sh` | `campaign_state.json` (drain + classify + `campaign_status` flip back to `running` when pending hits empty); per-IID `state.json` + `attempt_state.json` terminal blocks per §Phase 6 Write Mapping below. |

All three wrappers hold the dispatcher flock (`${LOCK_FILE}`) for their entire critical section and persist `campaign_state.json` atomically (`mktemp` + `mv`). The LLM never touches state files directly under the new contract.

## campaign_state.json

Path: `${CAMPAIGN_STATE_FILE}` (i.e. `${WORK_ROOT}/campaign_state.json` = `${RESULT_ROOT}/_dispatcher/campaign_state.json`; default `/data/${PROJECT}/${RESULT_BASENAME}/_dispatcher/campaign_state.json`)

```json
{
  "project": "px_ifp_hulat_test",
  "repo_path": "/data",
  "branch": "master",
  "issue_min_iid": 1,
  "issue_max_iid": 12,
  "hourly_issue_quota": 3,
  "max_runtime_minutes": 55,
  "blocked_retry_limit": 3,
  "blocked_cooldown_ticks": 1,
  "max_concurrent_subagents": 1,
  "max_accounts_per_issue": 14,
  "stuck_after_minutes": 332,
  "run_timeout_seconds": 18120,
  "acpx_timeout_seconds": 18000,
  "kill_subagent_on_terminal": true,
  "kill_subagent_on_done": true,
  "result_note_enabled": false,
  "issue_iids_whitelist": [14, 17, 20],
  "require_labels": ["acpx-auto", "priority::high"],
  "require_labels_match": "and",
  "result_basename": "ifp-result",
  "data_basename": "ifp-data",
  "ui_accounts_relpath": "ifp-data/ifp-common/ifp_users.json",
  "model_tiers": [
    {"tier": "flash", "settings": "/data/<project>/hulat/.claude/settings.flash.json"},
    {"tier": "pro",   "settings": "/data/<project>/hulat/.claude/settings.pro.json"},
    {"tier": "max",   "settings": "/data/<project>/hulat/.claude/settings.max.json"}
  ],
  "continue_upgrade_threshold": 2,
  "next_new_issue_iid": 4,
  "tick_seq": 27,
  "active_issue_iids": [14],
  "active_issue_sessions": ["issue-px_ifp_hulat-14"],
  "pending_subagents": {
    "14": {
      "attempt_number": 3,
      "run_id": "9710b359-2f32-407b-8c54-5c995ba266dc",
      "child_session_key": "agent:req_executor:subagent:b6719233-bcc8-4418-b401-c5f5f752609a",
      "ui_account_index_start": 0,
      "ui_account_count": 14,
      "spawned_at": "2026-05-06T10:00:12Z"
    }
  },
  "blocked_at_tick_by_iid": {},
  "unfinished_iids": [9, 10, 14, 15],
  "completed_iids": [1, 2, 3],
  "blocked_iids": [],
  "failed_iids": [],
  "timeout_iids": [],
  "campaign_status": "waiting_for_callbacks",
  "quota_launched_this_tick": 1,
  "quota_completed_this_tick": 0,
  "last_reconcile_evidence": "/data/<project>/<RESULT_BASENAME>/_dispatcher/log/reconcile-20260507T100501Z.json",
  "updated_at": "2026-05-07T10:05:30Z"
}
```

### `pending_subagents` — async-callback bookkeeping

Map keyed by stringified IID. Each entry tracks one in-flight subagent from spawn (`sessions_spawn` launch ack) to drain (`RUN_CHILD_COMPLETION_CALLBACK` processed by Phase 6) or eviction. Eviction can happen because the entry is stuck past `stuck_after_minutes`, or because a later scheduled trigger narrows the hard IID scope so this pending IID is outside `issue_iids ∩ [issue_min_iid,issue_max_iid]`.

| Field                | Type   | Notes                                                                                          |
| -------------------- | ------ | ---------------------------------------------------------------------------------------------- |
| `attempt_number`     | int    | The attempt number allocated for this subagent. Phase 6 validates `callback.attempt_number == this` to reject stale callbacks. |
| `run_id`             | string \| null | The `runId` returned by `sessions_spawn`. `null` only between Phase 4 step 5 (placeholder write) and Phase 5 step 2 (post-launch update); the orchestrator MUST NOT leave a `null` run_id once Phase 5 has finished. |
| `child_session_key`  | string \| null | The anonymous `childSessionKey` returned by `sessions_spawn` (e.g. `agent:req_executor:subagent:<uuid>`). For runtime-side audit only; not used for matching callbacks. Same nullability rule as `run_id`. |
| `ui_account_index_start` | int | The 0-based index of the FIRST account in `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}` (no default; configured via trigger `ui_accounts_relpath`) allocated to this subagent. The subagent owns `ui_account_count` consecutive accounts starting at this index. With `max_concurrent_subagents=1` this is always `0`, and the single slot is capped by `max_accounts_per_issue` (default 14). With `N>1` the orchestrator divides the pool into exactly `max_concurrent_subagents` raw slots (`pool_size / max_concurrent_subagents` with the integer remainder front-loaded), caps each slot at `max_accounts_per_issue`, and binds the `k`-th effective slot to the `k`-th IID of the batch (k = 0..batch_size-1); `ui_account_index_start` for that IID equals the cumulative effective slot-size sum `SLOT_SIZES[0..k-1]`. When `ui_accounts_relpath` is unconfigured the pool load is skipped entirely; `ui_account_index_start` is `0` and `ui_account_count` is `0` for every IID (no slot to allocate). Unlike `run_id` / `child_session_key` / `spawned_at`, this field is non-null even for placeholder entries — Phase 4 step 5 writes it together with the placeholder because the dispatcher already allocated the block (or recorded a zero-sized slot) in step 4. If the placeholder is reaped (Phase 5 launch retries exhaust) without ever reaching Phase 5 step 2, the value records the unused allocation for audit; the next batch's allocation comes from the pool head as usual. |
| `ui_account_count`       | int | The number of UI accounts allocated to this subagent (effective capped slot size `SLOT_SIZES[k]` for the `k`-th IID of the batch). Differs across IIDs in the same batch when `pool_size % max_concurrent_subagents != 0` or when `max_accounts_per_issue` caps a raw slot. Example: `pool=40, max_concurrent_subagents=1, max_accounts_per_issue=14` produces slot size `14`; `pool=50, max_concurrent_subagents=4, max_accounts_per_issue=14` produces `13,13,12,12`. Same nullability rule as `ui_account_index_start`: non-null even for placeholder entries because Phase 4 step 4 has already computed the slot before Phase 4 step 5 writes the placeholder. Legacy on-disk pending entries written before this field existed are loaded with `ui_account_count = null`; Phase 6 ignores the field for legacy entries. |
| `spawned_at`         | ISO-8601 UTC \| null | The orchestrator's wall-clock timestamp when `sessions_spawn` returned its launch ack. Used for stuck-pending eviction (`now - spawned_at >= stuck_after_minutes`). `null` between placeholder write and launch ack receipt; an entry with `null` `spawned_at` past `Phase 5 → end-of-tick` is itself a stuck case and gets evicted on the next scheduled wake-up. |
| `acpx_timeout_seconds` | int | The acpx wall-clock budget in effect when this entry was created (Phase 4 step 5 placeholder write). Pins which budget the timeout-shaped classification compares elapsed time against (`now - spawned_at >= acpx_timeout_seconds - 60s` → synthesized replies become `timeout`, parked without retry), so a trigger override applied while this run is in flight does not change the judgment for already-spawned runs. Non-null even for placeholder entries. Legacy on-disk entries written before this field existed are loaded without it; readers fall back to the campaign-level `acpx_timeout_seconds`. |

A `pending_subagents` entry with `placeholder: true` is a transient state during Phase 4 step 5 / Phase 5; it MUST NOT survive the end of the scheduled wake-up. If a crash leaves a placeholder behind, the next scheduled wake-up's stuck-pending eviction (which inspects `spawned_at`) treats it as stuck and synthesizes a blocked Phase 6 reply (`block_reason="placeholder pending entry survived: spawn was never observed to land"`).

### `active_issue_iids` / `active_issue_sessions` semantics under async-callback

These two arrays are now **redundant with `pending_subagents` keys** but retained for backward compatibility and cheap human-readable logging:

- `active_issue_iids[k]` = the IID
- `active_issue_sessions[k]` = the **logical** label `issue-<project>-<iid>` (NOT the runtime `child_session_key` — that lives in `pending_subagents[iid].child_session_key`)

The orchestrator MUST keep these two arrays in lockstep with `pending_subagents` keys: write all three in one persist; drain all three in one persist.

### Fresh-init values (when the file does not exist)

```text
next_new_issue_iid           = null   # resolved to issue_min_iid on first read
tick_seq                     = 0
max_concurrent_subagents     = 1
max_accounts_per_issue       = 14
stuck_after_minutes          = 332   # = ceil(run_timeout_seconds / 60) + 30
run_timeout_seconds          = 18120
acpx_timeout_seconds         = 18000
kill_subagent_on_terminal    = true
kill_subagent_on_done        = true
issue_iids_whitelist         = []
require_labels               = []
require_labels_match         = "or"
result_basename              = "ifp-result"
data_basename                = "ifp-data"
ui_accounts_relpath          = null   # unconfigured by default; trigger field opts in
model_tiers                  = null   # unconfigured by default; trigger field opts in; carry-forward
continue_upgrade_threshold   = 2      # carry-forward; soft model-upgrade threshold for continue_count
repo_path                    = "/data"
active_issue_iids            = []
active_issue_sessions        = []
pending_subagents            = {}
blocked_at_tick_by_iid       = {}
unfinished_iids              = []
completed_iids               = []
blocked_iids                 = []
failed_iids                  = []
timeout_iids                 = []
campaign_status              = running
quota_launched_this_tick     = 0
quota_completed_this_tick    = 0
```

### Campaign-level defaulted fields

| Field                   | Type            | Notes                                                                 |
| ----------------------- | --------------- | --------------------------------------------------------------------- |
| `max_accounts_per_issue` | int             | Post-override snapshot of the trigger's per-IID UI account cap. Defaults to `14`. Must be a positive integer. Used only when forming the next scheduled batch; callback processing reads the persisted value for audit but does not recalculate allocations. |
| `tick_seq`               | int             | Monotonic scheduled-wake counter. `dispatch_prepare_tick.sh` increments it once after acquiring the dispatcher lock and uses it with `blocked_at_tick_by_iid` to enforce `blocked_cooldown_ticks`. Callback wake-ups do not increment it. |
| `next_new_issue_iid`     | int \| null     | Cursor for picking the next never-attempted IID when forming a scheduled batch. Stored as `null` at fresh-init and resolved to `issue_min_iid` on first read (readers apply `// .issue_min_iid`); advanced by `dispatch_prepare_tick.sh` as fresh IIDs are consumed. Bounded by the effective IID universe (range ∩ `issue_iids_whitelist`). |
| `unfinished_iids`        | array of int    | Working backlog of in-range IIDs not yet terminal (not in `completed_iids` / `failed_iids`, and — for `blocked` / `timeout` — still retry-eligible). Rebuilt each scheduled tick from disk state and reconcile evidence; drives which IIDs the next batch draws from. Audit/scheduling aid, not a source of truth (GitLab labels are). |
| `quota_completed_this_tick` | int          | Per-tick counter of IIDs that reached terminal `done` during the current wake-up. Reset to `0` at the top of every scheduled wake-up (`dispatch_prepare_tick.sh`) and incremented by Phase 6 (`_dispatch_lib.sh`) on each `done` drain. Diagnostic only; pairs with `quota_launched_this_tick`. |
| `blocked_at_tick_by_iid` | object          | Map from stringified IID to the `tick_seq` at which the IID most recently entered `blocked`. Removed when the IID becomes `done` or `failed`. Missing legacy entries are treated as immediately retryable so old state is not stranded. |
| `issue_iids_whitelist`  | array of int    | Post-override snapshot of the trigger's `issue_iids` field. Empty `[]` = no whitelist (full `[issue_min_iid, issue_max_iid]` range). When non-empty, the effective IID universe = range ∩ this list (IIDs outside range are silently dropped at Phase 1). Pending entries outside the effective universe are scope-evicted at the top of the scheduled tick, marked `blocked`, and returned with a best-effort runtime kill action when a `child_session_key` is known. |
| `require_labels`        | array of string | Post-override snapshot of the trigger's `require_labels` field. Empty `[]` = no label filter. When non-empty, applied at Phase 3 against live GitLab labels from the reconcile evidence file. Case-sensitive. |
| `require_labels_match`  | `"or"` / `"and"` | Combinator for `require_labels`. Defaults to `"or"`. Ignored when `require_labels` is empty. Any other value = tick-level abort with `"invalid_require_labels_match"`. |
| `kill_subagent_on_terminal` | bool | Post-override snapshot of the trigger's terminal cleanup gate. Defaults to `true`. When true, Phase 6 may best-effort kill terminal `done` / `blocked` / `failed` / `timeout` child sessions after state files are persisted; `blocked` / `failed` / `timeout` cleanup additionally requires local evidence under `${LOG_DIR}` / `${ISSUE_ROOT}` (see Phase 6 step 9). |
| `run_timeout_seconds`   | int             | Post-override snapshot of the trigger's `run_timeout_seconds`. Defaults to `acpx_timeout_seconds + 120` (18120s when `acpx_timeout_seconds` is also omitted). Must be integer ≥ 60 and `≥ acpx_timeout_seconds + 120`, so the subagent has enough outer-runtime headroom for `run_acpx_attempt.sh` to return 124/137 and enter the timeout flow. Read by Phase 5 when constructing `sessions_spawn(..., runTimeoutSeconds=<value>, ...)`. Callback path does not re-read the trigger override; the persisted value from the most recent scheduled wake-up is authoritative for any callback-path readers (post-mortem inspection, future tooling). Not directly compared against `spawned_at` at eviction time — that comparison uses `stuck_after_minutes`, whose default tracks this value automatically (`ceil(run_timeout_seconds / 60) + 30`); explicit `stuck_after_minutes` overrides still take precedence. |
| `acpx_timeout_seconds`  | int             | Post-override snapshot of the trigger's `acpx_timeout_seconds`. Defaults to `18000`. Must be integer ≥ 60 and `acpx_timeout_seconds + 120 ≤ run_timeout_seconds`. Rendered into the executor prompt in Phase 4 step 7 as `{ACPX_TIMEOUT_SECONDS}` and `{ACPX_TIMEOUT_MINUTES} = floor(value / 60)`. Persisted for audit; callback path reads it for diagnostic purposes only. |
| `kill_subagent_on_done` | bool | Legacy compatibility snapshot only. New deployments should use `kill_subagent_on_terminal`; if the new field is missing and this legacy field is explicitly `false`, the loader disables terminal cleanup. |
| `result_note_enabled` | bool | Post-override snapshot of the trigger's `result_note_enabled` opt-in. Defaults to `false`, carry-forward. When `true`, Phase 6 best-effort runs `scripts/post_result_note.sh` after terminal `done` / `failed` / `timeout` drains: reads the issue's `req_origin` marker note (written by `git_issuer`) and, only if present, posts a `req_result` note (G1b read + G9 post) for an external relay (114) to deliver to the requester. `blocked` excluded. Best-effort: failure is logged to `wrapper.log` and never aborts Phase 6 (see Phase 6 step 10). Callback path reads the persisted value; callbacks carry no scalar override. |
| `repo_path`             | string          | Post-override snapshot of the trigger's `repo_path` parent directory. Defaults to `"/data"`. `env_paths.sh` derives final `REPO_PATH=${repo_path}/${PROJECT}` as the clone target (the parent checkout; the shared per-issue linked worktree at `${WORKTREE_DIR}=${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>/` is acpx's cwd, reused across attempts of the same IID). Tick aborts with `"invalid_repo_path"` when the value is not an absolute parent directory or contains `..`, whitespace, or shell-unsafe characters outside `[A-Za-z0-9_./-]`. This field is persisted for audit, but non-default deployments must still pass `repo_path` on every scheduled trigger and callback because the dispatcher needs it before reading this file. |
| `result_basename`       | string          | Post-override snapshot of the trigger's `result_basename`. Defaults to `"ifp-result"`. Used by `env_paths.sh` to derive `RESULT_ROOT=${REPO_PATH}/${result_basename}` and forwarded to every script as `RESULT_BASENAME=...`. Tick aborts with `"invalid_result_basename"` when the value contains `/`, `..`, or whitespace. |
| `data_basename`         | string          | Post-override snapshot of the trigger's `data_basename`. Defaults to `"ifp-data"`. Forwarded as `DATA_BASENAME=...` and rendered into the subagent prompt. Same validation as `result_basename`. |
| `ui_accounts_relpath`   | string \| null  | Post-override snapshot of the trigger's `ui_accounts_relpath`. **No default** — `null`, `""`, or absent on a fresh deployment that never supplied the field (the on-disk representation depends on which jq writer last touched the file; all three are treated identically by the loader's `// empty` filter). When non-null and non-empty it is forwarded as `UI_ACCOUNTS_RELPATH=...` to `scripts/load_ui_accounts.sh`, which derives the absolute pool file path `${REPO_PATH}/${ui_accounts_relpath}` (the relpath is resolved under the project checkout root, NOT under `${REPO_PATH}/${DATA_BASENAME}/`). When `null` / empty / absent, the dispatcher skips the entire UI-account flow: `load_ui_accounts.sh` is not invoked, `ui_account_pool_size` is set to `0`, every IID's `ui_account_count` is `0`, and the rendered Claude Code prompt omits the `# UI test accounts` section. Tick aborts with `"invalid_ui_accounts_relpath"` when a non-null trigger or persisted value is absolute, contains `.` / `..` segments, whitespace, or characters outside `[A-Za-z0-9_./-]`. Carry-forward semantics: omitted-in-trigger keeps the persisted value (or stays unconfigured on a fresh deployment). To disable a previously-configured deployment, manually `jq` `campaign_state.json` to set `.ui_accounts_relpath = null`. **Schema migration:** before SKILL_VERSION 2026-05-27.1 this field was resolved under `${REPO_PATH}/${DATA_BASENAME}/`; a persisted carry-forward value from before the upgrade (e.g. `"ifp-common/ifp_users.json"`) MUST be re-sent on the next trigger with the data basename prepended (e.g. `ui_accounts_relpath=ifp-data/ifp-common/ifp_users.json`) so the resolved path matches reality. The loader does NOT auto-migrate — instead, `load_ui_accounts.sh` exit 10 carries an explicit hint when the legacy resolved path still exists on disk. |
| `model_tiers`           | array \| null   | Post-override snapshot of the trigger's `model_tiers`. **No default — `null` when unconfigured.** Each element is `{"tier": "<suffix>", "settings": "<absolute path>"}` (the settings path MUST be absolute — same validation as `claude_settings_path`) in ascending model order (e.g. `[{"tier":"flash","settings":"/data/<project>/hulat/.claude/settings.flash.json"},{"tier":"pro","settings":"/data/<project>/hulat/.claude/settings.pro.json"},{"tier":"max","settings":"/data/<project>/hulat/.claude/settings.max.json"}]`). `ensure_labels.sh` creates one `model:<tier>` label per entry. `resolve_model_tier` (Phase 4, before entering `doing`) reads the current live model label, computes `UPGRADE?`, advances the tier monotonically when triggered, writes the new `model:<tier>` label to GitLab, injects the corresponding settings file into the worktree, and updates `state.json.model_tier`. Carry-forward semantics: omitted-in-trigger keeps the persisted value. Set to `null` on a fresh deployment that has not configured model tiers; the model-upgrade flow is skipped entirely when this field is null. |
| `continue_upgrade_threshold` | int        | Soft model-upgrade threshold for continue-mode runs. Default `2`. When `state.json.continue_count >= this value`, `resolve_model_tier` includes it as a soft trigger for model upgrade. Carry-forward semantics: omitted-in-trigger keeps the persisted value. Must be a positive integer. |

### Reconcile evidence digest (`reconcile-<ts>.json`)

Path: `${WORK_ROOT}/log/reconcile-<ts>.json`. Written by `scripts/reconcile.sh` at every tick (both scheduled and callback). No evidence file = the tick is considered failed. The dispatcher reads the most-recent evidence file as the post-reconcile per-IID signal table.

Key per-IID fields in the evidence digest:

| Field               | Meaning                                                                                         |
| ------------------- | ----------------------------------------------------------------------------------------------- |
| `is_closed_on_gitlab` | `true` when the GitLab issue is `state=closed`. Hard terminal skip — the IID is never scheduled again. |
| `has_done_pr`       | `true` when live labels contain `pr` (i.e. the issue carries the `pr` label). This is the completion signal — **`done` alone is NOT sufficient**; only `pr` indicates the agent finished and opened an MR. `done` is transient and is removed when `pr` is added. |
| `needs_continue`    | `true` when the issue is opened and has a `continue` (or legacy `contiune`) label. Wins over cached `done` state — the dispatcher re-enqueues the IID even if disk says `done`. |
| `user_reopened`     | `true` when the issue is opened, lacks both `pr` and failure/doing/continue labels, and the disk cache says terminal. Signals manual human intervention (stripped labels to restart). |
| `model_tier`        | The `{tier}` suffix of the current `model:{tier}` label on the issue (e.g. `"flash"`, `"pro"`, `"max"`), or `null` when no `model:{tier}` label is present. `reconcile.sh` extracts this from live GitLab labels and writes it into the evidence digest. `dispatch_prepare_tick.sh` uses it to update `state.json.model_tier` after reconciliation so the cache stays aligned with GitLab. |

### Legacy on-disk shapes the loader must tolerate

Some on-disk files written by older deployments may be missing fields or use the old scalar shape. The loader normalizes them in memory and persists the current shape on the next write.

- **Legacy scalar `active_issue_iid` / `active_issue_session`** — if present and no `active_issue_iids` / `active_issue_sessions` array exists, treat as `[scalar]` (or `[]` if the scalar was `null`). On the next write, persist only the array shape.
- **Missing `pending_subagents`** — treat as `{}` in memory; persist on next write.
- **Missing `max_concurrent_subagents`** — default to `1` and persist.
- **Missing `max_accounts_per_issue`** — default to `14` and persist.
- **Stale `accounts_per_issue` field** — silently dropped on the next persist. The field is no longer part of the schema; per-IID account counts are derived automatically from the pool size, `max_concurrent_subagents`, and `max_accounts_per_issue`.
- **Missing `stuck_after_minutes`** — default to `ceil(run_timeout_seconds / 60) + 30` (`332` when both timeout fields are omitted) and persist.
- **Missing `run_timeout_seconds`** — default to `acpx_timeout_seconds + 120` and persist (18120s when both timeout fields are omitted). Older deployments did not carry this field; loading it from a legacy file is harmless because Phase 5 reads the post-override value, not the trigger directly.
- **Missing `acpx_timeout_seconds`** — default to `18000` and persist. Same legacy-tolerance rule as `run_timeout_seconds`. If the persisted `run_timeout_seconds` somehow lacks the required 120-second headroom over `acpx_timeout_seconds` (only possible across a hand-edited file or an explicit trigger override), Phase 1's post-override validation aborts the tick with `"run_timeout_seconds_below_acpx_timeout_seconds_plus_120"` so the operator notices.
- **Missing `kill_subagent_on_terminal`** — default to `true` and persist. If the new field is missing but legacy `kill_subagent_on_done` is present and explicitly `false`, set and persist `kill_subagent_on_terminal=false` for compatibility. This gate controls whether Phase 6 step 9 calls the `subagents` kill tool after terminal `done` / `blocked` / `failed` / `timeout` outcomes; `blocked` / `failed` / `timeout` cleanup is additionally gated on local evidence existence.
- **Missing `kill_subagent_on_done`** — default to the same value as `kill_subagent_on_terminal` and persist only for backward-readable audit. New logic should not use it except for the compatibility rule above.
- **Missing `result_note_enabled`** — default to `false` and persist. Carry-forward: a later trigger that supplies it overrides; when omitted the persisted value is preserved. When `false` the Phase 6 result-note step is skipped entirely. Issue-note markers it touches: reads `<!-- req_origin v1 {...} -->` (written by `git_issuer`), writes `<!-- req_result v1 {...} -->` (consumed by the 114-side relay) — neither is a workflow label and neither affects scheduling.
- **Missing `quota_launched_this_tick`** — default to `0` and persist (it is reset to `0` at the top of every scheduled wake-up anyway).
- **Missing `quota_completed_this_tick`** — default to `0` and persist (same reset-each-tick behavior; a legacy file without it is harmless because Phase 6's `// 0` guard tolerates its absence).
- **Missing `next_new_issue_iid`** — treat as `null` and resolve to `issue_min_iid` on first read via `// .issue_min_iid` (same as fresh-init); the next scheduled wake-up advances and persists it as fresh IIDs are consumed.
- **Missing `unfinished_iids`** — default to `[]`; rebuilt from disk state and reconcile evidence on the next scheduled tick, so a missing-on-disk list is harmless.
- **Missing `tick_seq`** — default to `0`; the next scheduled wake-up increments and persists it.
- **Missing `blocked_at_tick_by_iid`** — default to `{}`. A blocked IID with no map entry is considered cooldown-eligible on the next batch decision.
- **`active_issue_iids` entries with no matching `pending_subagents` key** — stale (the orchestrator was synchronous before async-callback; nothing was actually in-flight if the prior tick exited cleanly). Drop them on read: clear `active_issue_iids` / `active_issue_sessions` and persist. The next scheduled wake-up re-schedules those IIDs from disk state.
- **Missing `timeout_iids`** — default to `[]` and persist on next write. Older deployments did not carry this list; missing-on-disk is harmless because the dispatcher fully rebuilds it from the reconcile evidence file's `has_timeout` signal each tick.
- **Missing `issue_iids_whitelist` / `require_labels` / `require_labels_match`** — default to `[]` / `[]` / `"or"` and persist on next write. These fields are NOT carried forward across ticks beyond the trigger's say-so: each scheduled wake-up's Phase 1 OVERRIDES them with the trigger's current values (or with defaults when the trigger omits them). The on-disk copy is for audit and crash-recovery only.
- **Missing `repo_path`** — default to `"/data"` in memory and persist on next write. This is a bootstrap path snapshot only; if the operator configured a non-default clone parent, the trigger/callback still has to provide it so the dispatcher can locate this state file before loading it.
- **Missing `result_basename` / `data_basename`** — default to `"ifp-result"` / `"ifp-data"` in memory and persist on next write. Each scheduled wake-up's Phase 1 may OVERRIDE them with the trigger's current values; when the trigger omits the fields, the persisted value is retained (these basenames are deployment-stable per project, unlike the per-tick filter fields above).
- **Missing `ui_accounts_relpath`** — treat as `null` in memory and persist as `null` on next write. There is no hardcoded default. Same Phase 1 override / carry-forward rule as `result_basename` / `data_basename` (the UI account pool file location is a deployment property, not a per-tick decision), but with the additional behavior that `null` / `""` triggers **pool-load skip mode**: the dispatcher does not invoke `load_ui_accounts.sh`, every IID gets `ui_account_count=0`, and `build_prompt.sh` omits the `# UI test accounts` section of the rendered Claude Code prompt. **Schema migration:** persisted values written before SKILL_VERSION 2026-05-27.1 were `${DATA_BASENAME}/`-relative (e.g. `"ifp-common/ifp_users.json"`); after the upgrade they would resolve under `${REPO_PATH}` directly and miss the pool file. The loader does NOT auto-prepend `${DATA_BASENAME}/` — operators must re-send the trigger once with the corrected `ui_accounts_relpath` (e.g. `ifp-data/ifp-common/ifp_users.json`). `load_ui_accounts.sh` exit 10 includes a migration hint when it detects the legacy path on disk.

The dispatcher MUST NOT keep both the scalar and the array fields in the persisted file — pick the array shape per write and drop the legacy scalars.

### Possible `campaign_status` values

- `running` — between scheduled wake-ups, when no batch is in flight
- `waiting_for_callbacks` — set by Phase 5 after spawning a batch; cleared back to `running` once the last pending entry drains (or all evicted)
- `completed` — every IID in range terminal AND `pending_subagents` empty

`completed` may only be set when reconciliation has just run AND every IID in range has `is_done_on_gitlab == true` (live state is `closed` OR live labels contain `pr`) AND `needs_continue == false` in the evidence file AND `pending_subagents == {}`.

## issue-<iid>/state.json — cross-attempt issue state

Path: `${ISSUE_STATE_FILE}` = `${ISSUE_ROOT}/state.json`

Initialized by `scripts/allocate_attempt.sh` (which the dispatcher runs before each spawn). The dispatcher's Phase 4 prep refreshes `status="in_progress"` / `mode` / `attempts_total` / `latest_attempt_*` before spawn. The dispatcher's Phase 6 follow-up writes the terminal `status` / `commit_sha` / `merge_request_url` / `block_reason` from the subagent's compact JSON reply or from an inline-synthesized blocked/timeout reply. Launch-side `sessions_spawn` failures preserve `retry_count`; other blocked/failed outcomes consume that budget. The subagent does NOT write this file.

```json
{
  "iid": 14,
  "session": "issue-px_ifp_hulat_test-14",
  "status": "in_progress",
  "mode": "continue",
  "attempts_total": 2,
  "latest_attempt_number": 2,
  "latest_attempt_dir": "/data/<project>/<RESULT_BASENAME>/issues/issue-14",
  "retry_count": 1,
  "block_reason": null,
  "block_side": null,
  "model_tier": "flash",
  "continue_count": 1,
  "commit_sha": "abc1234...",
  "merge_request_url": "http://gitlab.example.com/.../merge_requests/15",
  "updated_at": "2026-05-07T10:00:00Z"
}
```

| Field                   | Type            | Notes                                                                  |
| ----------------------- | --------------- | ---------------------------------------------------------------------- |
| `iid`                   | int             | GitLab issue IID this session is bound to.                             |
| `session`               | string          | Logical issue label `issue-<project>-<iid>` (used for `active_issue_sessions` bookkeeping and human-readable logging). The runtime subagent key is anonymous; this field stores the logical label only. |
| `status`                | string (enum)   | See "Possible status values" below. This is the latest attempt's terminal status (or `in_progress` mid-flight). |
| `mode`                  | string (enum)   | `"fresh"` or `"continue"` for the latest attempt.                      |
| `attempts_total`        | int             | Number of attempts ever launched for this IID.                         |
| `latest_attempt_number` | int             | Same number as `${ATTEMPT_NUMBER}` of the most recent attempt.         |
| `latest_attempt_dir`    | string          | Convenience absolute path; matches `${ATTEMPT_DIR}`. In the current layout this is `${ISSUE_ROOT}`. |
| `retry_count`           | int             | How many blocked/failed outcomes have consumed the cross-tick retry budget. Launch-side `sessions_spawn` failures after in-tick retry exhaustion do not increment it. `timeout` outcomes ALSO do not increment it (the IID is terminally parked in `timeout_iids` and the dispatcher does not auto-retry until a reviewer strips `timeout`, adds `retry`, or applies `continue`). |
| `block_reason`          | string \| null  | Required when `status` is `blocked-cc`, `blocked-dispatcher`, `failed-cc`, `failed-dispatcher`, or `timeout`. |
| `block_side`            | string \| null  | `"cc"` when the last failure was CC-side (`blocked-cc`, `failed-cc`, `timeout`); `"dispatcher"` when dispatcher-side (`blocked-dispatcher`, `failed-dispatcher`); `null` when status is `done` / `in_progress` / `pending`. Written by `dispatch_followup.sh` in Phase 6: dispatcher-synthesized replies (`launch_failed`, scope/stuck eviction, unparseable reply forced-downgrade, label-sync failure downgrade) use `"dispatcher"`; replies parsed from a subagent compact JSON use `"cc"` (the subagent does NOT include `block_side` in its reply — this field is inferred by the dispatcher internally). Used by `resolve_model_tier` in Phase 4 to determine whether to apply a model upgrade (`cc` → upgrade eligible; `dispatcher` → no upgrade). |
| `model_tier`            | string \| null  | Cache of the current `model:{tier}` suffix active on GitLab for this issue (e.g. `"flash"`, `"pro"`, `"max"`). Written by `dispatch_prepare_tick.sh` after `resolve_model_tier` runs. `null` when `model_tiers` is unconfigured or before the first attempt. `reconcile.sh` reads the live GitLab `model:{tier}` label and updates this field to keep the cache aligned — GitLab is the source of truth. |
| `continue_count`        | int             | Cumulative count of attempts that ran in continue mode for this IID. Incremented by Phase 4 each time `mode_actual=continue`. Used by `resolve_model_tier` as a soft trigger for model upgrade when `continue_count >= continue_upgrade_threshold`. |
| `commit_sha`            | string \| null  | Latest pushed commit SHA when applicable.                              |
| `merge_request_url`     | string \| null  | Strategy A: exactly one open MR per issue at any moment; every attempt rotates (closes the prior open MR, creates a fresh one) in BOTH fresh and continue modes. |
| `updated_at`            | ISO-8601 UTC    | Update at every major step.                                            |

### Possible `status` values

| Status        | When written                                                                 | Terminal? | GitLab label applied |
| ------------- | ---------------------------------------------------------------------------- | --------- | --------------------- |
| `pending`     | After dispatcher reconciliation re-enqueues; before dispatcher prep starts.  | no        | (unchanged from prior) |
| `in_progress` | After dispatcher prep finishes (repo checkout + prompt ready); during Claude execution and post-acpx subagent flow. | no | `doing` |
| `blocked`     | Retryable failure. The dispatcher maps this to `blocked-cc` (CC-side: acpx non-timeout failure, NO_CHANGES, push rejected, post-push steps failed) or `blocked-dispatcher` (dispatcher-synthesized: prep failed, launch_failed after retry exhaustion, scope/stuck eviction, unparseable reply downgrade, label-sync failure downgrade), based on the internally-derived `block_side`. For acpx CC-side failures after worktree prep, the subagent first tries to stage, commit, and force-push any committable partial work to `${WORK_BRANCH}`; it still opens no MR and consumes retry budget. | no | `blocked-cc` or `blocked-dispatcher` |
| `failed`      | Non-recoverable, or `retry_count > blocked_retry_limit`. Mapped to `failed-cc` when `block_side=cc` and to `failed-dispatcher` when `block_side=dispatcher`. | yes | `failed-cc` or `failed-dispatcher` |
| `done`        | After post-push verification, Wiki evidence publication, `doing → done` (transient), MR creation / rotation, and `pr` label addition succeeded. `done` is a transient label: Step 6 applies it, and Step 8 (`set_issue_label add pr`) replaces it with `pr` only. `done` and `pr` are never present simultaneously. | yes | `pr` (replacing `done`) |
| `timeout`     | `acpx claude exec` exceeded its wall-clock cap (`acpx_timeout_seconds`). The subagent still commits + force-pushes the partial work to `${WORK_BRANCH}` but does NOT open an MR. Terminal until a human strips `timeout`, adds `retry`, or applies `continue` — `retry_count` is NOT consumed and the dispatcher does NOT auto-retry. `timeout` is always `block_side=cc`. | yes (until human relabel) | `timeout` |
| `no_changes`  | Legacy compact-reply value for `stage_and_guard.sh` `NO_CHANGES`; new prompts normalize this to `blocked` because no MR / `pr` label can be produced. | no | `blocked-cc` (after normalization) |

## issue-<iid>/attempt_state.json — current-attempt state

Path: `${ATTEMPT_STATE_FILE}` = `${ATTEMPT_DIR}/attempt_state.json`

Each attempt overwrites this file with the current attempt's details. Older local attempt-state files are not preserved on disk; durable history is kept in the monotonically increasing attempt counters, local attempt logs, and GitLab attempt-summary notes for successful `done` attempts.

```json
{
  "iid": 14,
  "attempt_number": 2,
  "attempt_started_at": "2026-05-06T09:55:00Z",
  "attempt_finished_at": "2026-05-06T09:59:42Z",
  "mode_requested": "continue",
  "mode_actual": "continue",
  "mode_downgraded_from": null,
  "no_reviewer_comments": false,
  "prior_attempt_count": 1,
  "local_branch": "issue/14-auto-fix-att002",
  "log_dir": "/data/<project>/<RESULT_BASENAME>/.worktrees/issue-14/<RESULT_BASENAME>/issue-14/log/attempt-002",
  "commit_sha": "abc1234...",
  "wiki_artifacts_file": "/data/<project>/<RESULT_BASENAME>/.worktrees/issue-14/<RESULT_BASENAME>/issue-14/log/attempt-002/wiki_artifacts.md",
  "attempt_artifacts_posted_to_wiki": true,
  "status": "done",
  "block_reason": null,
  "summary_file": "/data/<project>/<RESULT_BASENAME>/issues/issue-14/summary.md",
  "summary_posted_to_issue": true
}
```

| Field                     | Notes                                                                                    |
| ------------------------- | ---------------------------------------------------------------------------------------- |
| `attempt_number`          | matches `${ATTEMPT_NUMBER}` for this attempt                                              |
| `mode_requested`          | what reconciliation / per-issue state asked for (`fresh` or `continue`)                   |
| `mode_actual`             | what `prepare_attempt.sh` ended up running (continue can downgrade to fresh)              |
| `mode_downgraded_from`    | non-null only when `mode_actual=fresh` but `mode_requested=continue` and the remote branch was missing |
| `no_reviewer_comments`    | continue mode only — true if `build_prompt.sh` reported `CONTINUE_MODE_NO_REVIEWER_COMMENTS=true` |
| `prior_attempt_count`     | continue mode only — number of past `req_executor:attempt-summary` notes (plus legacy pre-rename attempt-summary notes) the prompt included |
| `local_branch`            | per-attempt local branch (`${LOCAL_ATTEMPT_BRANCH}`)                                      |
| `log_dir`                 | `${LOG_DIR}` for this attempt                                                             |
| `wiki_artifacts_file`     | `${LOG_DIR}/wiki_artifacts.md` once `upload_attempt_artifacts.sh` has posted Wiki links to GitLab |
| `attempt_artifacts_posted_to_wiki` | true after `prompt.txt`, `claude_result.txt`, and optional `report.html` were published to the project Wiki and linked from the issue |
| `summary_file`            | `${SUMMARY_FILE}` once `summarize_attempt.sh` has run                                     |
| `summary_posted_to_issue` | true after the summary was successfully posted as a GitLab issue note                     |

The dispatcher's Phase 4 prep initializes `attempt_started_at`, `mode_*`, `no_reviewer_comments`, `prior_attempt_count`, `local_branch`, `log_dir`, `status="in_progress"` before spawn. The dispatcher's Phase 6 follow-up writes the terminal `status` / `attempt_finished_at` / `commit_sha` / `wiki_artifacts_file` / `attempt_artifacts_posted_to_wiki` / `summary_posted_to_issue` / `block_reason` from the subagent's compact JSON reply. The subagent does NOT write this file.

## issue-<iid>/dispatch_origin.json — driven-entry origin (RUN_SINGLE_ISSUE)

Path: `${ISSUE_ROOT}/dispatch_origin.json` (= `${ISSUES_ROOT}/issue-<iid>/dispatch_origin.json`).

**Written only on the driven path.** When `req_dispatcher` drives one issue via the `RUN_SINGLE_ISSUE` trigger (I1), `scripts/dispatch_single_issue.sh` records the cross-agent origin to this file BEFORE delegating to the synthesized single-IID `RUN_SCHEDULED_ISSUE_CAMPAIGN`. It is the ONLY driven-specific artifact; the cron path (`RUN_SCHEDULED_ISSUE_CAMPAIGN`) never writes it, so its presence is what Phase 6 uses to distinguish driven from cron at result-report time. It is NOT a campaign cache file — it carries no workflow state and is never reconciled against GitLab.

```json
{
  "correlation_id": "req-2026-06-29-abc123",
  "dispatcher_callback_target": "<待对齐 form>",
  "project": "claw_gitlab/px_ifp_hulat_test",
  "iid": 14
}
```

| Field                        | Type            | Notes                                                                                          |
| ---------------------------- | --------------- | ---------------------------------------------------------------------------------------------- |
| `correlation_id`             | string          | `req_dispatcher`'s关联 token from I1, persisted verbatim. Echoed back in the I2 result envelope so `req_dispatcher` matches its pending entry (secondary check; its primary key is `run_id`). |
| `dispatcher_callback_target` | string \| null  | The result-callback target from I1 (⚠️ **待对齐** form, design §9). `null` when the I1 trigger omitted it; an empty/`null` target makes the Phase 6 callback a no-op. A driven issue is only treated as driven when this is non-empty AND `correlation_id` is non-empty. |
| `project`                    | string          | The `project` slug from I1 (forwarded into the I2 envelope's `project` field). |
| `iid`                        | int             | The driven IID (matches the directory). |

**Phase 6 use (driven result callback, I2).** At terminal time, `dispatch_followup.sh` derives `DISPATCH_ORIGIN_FILE=${ISSUES_ROOT}/issue-<iid>/dispatch_origin.json` inline (the callback path sources `env_paths.sh` at the dispatcher level only, so `ISSUE_ROOT` is not exported; the inline path matches what `dispatch_single_issue.sh` wrote). If the file exists and carries a non-empty `correlation_id` + `dispatcher_callback_target` (`IS_DRIVEN=true`), then for terminal `done` / `failed` / `timeout` (NOT `blocked`) it best-effort runs `scripts/notify_dispatcher.sh` to报回 `req_dispatcher` with the I2 envelope `{correlation_id, iid, project, status, mr_url, wiki_url, reason}` and **SKIPS** `post_result_note.sh`. When the file is absent (cron path) the existing `result_note_enabled`-gated `post_result_note.sh` runs instead. The two paths are mutually exclusive. Both are best-effort (`set +e`, stdout → `/dev/null`, failure logged to `wrapper.log`, NEVER aborts Phase 6). Full I1/I2 contract: [`trigger_command.md`](trigger_command.md) §Driven single-issue trigger.

---

## Compact Subagent Reply

The subagent returns a single compact JSON line on the LAST line of its turn. The dispatcher (Phase 6 of the algorithm) reads this reply and uses it to write the terminal `issue-<iid>/state.json` and `issue-<iid>/attempt_state.json`, drain the IID from `active_issue_iids`, classify the IID into the right `campaign_state.json` list, and — when `result_note_enabled` — best-effort post a `req_result` 结果回报 note (see the `result_note_enabled` field and Phase 6 step 10).

### Schema

```json
{
  "iid": 14,
  "attempt_number": 3,
  "status": "done",
  "mode_actual": "fresh",
  "work_branch": "issue/14-auto-fix",
  "local_branch": "issue/14-auto-fix-att003",
  "commit_sha": "abc1234deadbeef",
  "merge_request_url": "https://gitlab.example.com/group/project/-/merge_requests/123",
  "mr_action": "created",
  "wiki_url": "https://gitlab.example.com/group/project/-/wikis/issue-14/attempt-003-prompt",
  "labels_added": ["done", "pr"],
  "labels_removed": ["doing"],
  "summary_posted": true,
  "block_reason": "",
  "log_dir": "/data/<project>/<RESULT_BASENAME>/.worktrees/issue-14/<RESULT_BASENAME>/issue-14/log/attempt-003"
}
```

### Field reference

| Field                | Type            | Notes                                                                  |
| -------------------- | --------------- | ---------------------------------------------------------------------- |
| `iid`                | int             | Must match the dispatched IID. The dispatcher rejects mismatches.      |
| `attempt_number`     | int             | Must match `${ATTEMPT_NUMBER}` from the rendered prompt.               |
| `status`             | string (enum)   | `done` / `no_changes` / `blocked` / `failed` / `timeout`. See §Possible status values above. New subagent prompts convert no-diff outcomes to `blocked`; `no_changes` is accepted only for legacy replies and normalized by the dispatcher. The subagent prefers `blocked` — the dispatcher promotes `blocked → failed` in Phase 6 when retry budget exhausted. The subagent emits `timeout` only from the dedicated timeout flow (see `executor_prompt.md` §timeout_flow); the dispatcher does NOT promote `timeout → failed`. **The compact reply does NOT include a `block_side` field.** The dispatcher derives `block_side` internally during Phase 6 normalization/synthesis: dispatcher-synthesized replies (`launch_failed`, scope/stuck eviction, unparseable-reply forced downgrade, label-sync failure downgrade) receive `block_side="dispatcher"`; replies parsed from a subagent compact JSON receive `block_side="cc"`. This mapping determines whether `blocked-cc`/`failed-cc` or `blocked-dispatcher`/`failed-dispatcher` is written to GitLab labels and `state.json`. |
| `mode_actual`        | string (enum)   | `fresh` / `continue` — what `prepare_attempt.sh` actually ran (continue can downgrade to fresh inside `prepare_attempt.sh`). |
| `work_branch`        | string          | `issue/<iid>-auto-fix` — the single force-pushed remote branch.        |
| `local_branch`       | string          | `${LOCAL_ATTEMPT_BRANCH}` — per-attempt local branch kept for audit.   |
| `commit_sha`         | string          | Empty `""` if commit/push did not run or failed. May be non-empty for `done`, `timeout`, or `blocked` replies when partial work was successfully force-pushed. |
| `merge_request_url`  | string          | Empty `""` if Step 7 did not run.                                      |
| `mr_action`          | string (enum)   | `created` / `rotated` / `none`. `rotated` when one or more prior open MRs were closed before creating the new one, `created` when no prior open MR existed, `none` when Step 7 did not run. The legacy `reused` value is retired — both fresh and continue modes now always close + create. |
| `wiki_url`           | string          | First Wiki page URL printed by `upload_attempt_artifacts.sh`. Empty if Step 5 did not run. |
| `labels_added`       | array of string | The labels the subagent ADDED in Steps 6 / 7b or fail-flow label sync (e.g. `["done","pr"]` for done, `["blocked"]` for a blocked failure before done). |
| `labels_removed`     | array of string | The labels the subagent REMOVED in Step 6 or fail-flow label sync (e.g. `["doing"]`). |
| `summary_posted`     | bool            | `true` iff `summarize_attempt.sh` posted a GitLab issue note. Failure paths set `SUMMARY_POST_TO_ISSUE=false`, so this is normally `false` even when `${SUMMARY_FILE}` was written locally. |
| `block_reason`       | string          | Required non-empty when `status` is `blocked`, `failed`, or `timeout`; empty `""` otherwise. For `timeout`, the value typically reads `acpx exec exceeded {ACPX_TIMEOUT_SECONDS}s wall-clock cap`. |
| `log_dir`            | string          | Absolute path; mirrors `${LOG_DIR}`. Helps the dispatcher locate logs without re-deriving paths. |

### Tolerated variations

- The subagent may emit `null` instead of `""` for empty string fields. The dispatcher normalizes both to empty.
- The subagent may omit `labels_added` / `labels_removed` for legacy non-done terminals — the dispatcher treats omission as `[]` and still performs Phase 6 live-label synchronization.
- Trailing whitespace / a single trailing newline after the JSON line is OK; nothing else may appear after the JSON on the subagent's last turn.

### Dispatcher-side validation (Phase 6)

The compact reply arrives in two ways:

- **Callback path** — the runtime delivers `RUN_CHILD_COMPLETION_CALLBACK` carrying the full compact JSON in `worker_result_json`. One callback per subagent.
- **Inline-synthesized path** — Phase 5 launch failure after in-tick retry exhaustion / scope or stuck-pending eviction at the top of a scheduled wake-up; the orchestrator constructs a minimal terminal reply on the spot. Launch failures, scope evictions, and placeholder evictions synthesize `status=blocked` (retryable); a stuck-pending eviction whose run already outlived its acpx wall-clock budget (`now - spawned_at ≥ acpx_timeout_seconds - 60s` — always true under the default `stuck_after_minutes`) synthesizes `status=timeout` instead, parking the IID in `timeout_iids` with no auto-retry (只要超时就不重试). Phase 5 launch failures and pending evictions are tracked as launch-side internally for retry accounting; this is not a compact-reply field.

The validation pipeline is the same in both paths:

1. Parse `worker_result_json` (callback path) or use the synthesized object directly. On parse failure (or empty payload / missing or non-enum `status` field), treat as a synthetic terminal reply `{"iid":<callback.iid>,"attempt_number":<callback.attempt_number>,"status":<synth>,"block_reason":"callback worker_result_json not valid JSON: <first 200 chars>"}` and continue with that, where `<synth>` is `"timeout"` when the run already outlived `acpx_timeout_seconds - 60s` since `spawned_at` (runtime-kill / dead-timeout-flow signature — parked, no auto-retry) and `"blocked"` otherwise. A parseable reply with an explicit `status` keeps the subagent's own verdict.
2. **Match to a `pending_subagents` entry by `iid` + `attempt_number`.** This is the canonical identity check (replacing both session-name dedup AND the old "match against this batch's dispatch list").
   - Look up `pending_subagents[reply.iid]`. If the entry does not exist → return `"callback_status":"stale_or_already_drained"` (the IID was already drained by a prior callback / eviction). Do NOT mutate state files.
   - Verify `pending_subagents[reply.iid].attempt_number == reply.attempt_number`. Mismatch (most commonly: a stale callback for an older attempt) → return `"callback_status":"stale_or_already_drained"`. Do NOT mutate state files.
   - Optionally cross-check `pending_subagents[reply.iid].run_id` against `callback.run_id` (when present). Mismatch is logged but does not reject — the canonical identity is `iid + attempt_number`.
3. Normalize legacy `reply.status="no_changes"` to `status="blocked"` and set `block_reason="subagent produced no staged changes"` when the reply did not provide a reason.
4. If `reply.status in {blocked, failed, timeout}`, require non-empty `reply.block_reason`. Empty → keep the status unchanged and fill `block_reason="subagent reply status=<status> with empty block_reason"`. The status itself is never reclassified by this rule — in particular `timeout` stays `timeout` (只要超时就不重试), never demoted to retryable `blocked`. A status that is present but not one of `{done, no_changes, blocked, failed, timeout}` (including the empty string) is coerced to the synthesized status from step 1 (`timeout` when the run outlived its budget, else `blocked`) with a diagnostic `block_reason`.
5. Synchronize live GitLab workflow labels from the final status with `scripts/set_issue_label.sh`: `done` ends as `pr` only (`done` is transient — Step 6 applies `doing → done`, Step 8 applies `pr` which removes `done`, so `done` and `pr` never coexist long-term); `blocked` (CC-side) ends as no `doing` + `blocked-cc`; `blocked` (dispatcher-side) ends as no `doing` + `blocked-dispatcher`; `failed` (CC-side) ends as no `doing` / `blocked-cc` + `failed-cc`; `failed` (dispatcher-side) ends as no `doing` / `blocked-dispatcher` + `failed-dispatcher`; and `timeout` ends as no `doing` / `blocked-cc` / `blocked-dispatcher` / `failed-cc` / `failed-dispatcher` + `timeout`. Any required live-label sync failure converts a non-failed / non-timeout result to `blocked` (`block_side="dispatcher"`, mapped to `blocked-dispatcher`) with `block_reason` appended.
6. If `status=blocked` AND `retry_count > blocked_retry_limit` (after incrementing), promote to `status=failed` (preserving `block_side`), add to `failed_iids`, and run failed-label sync (`blocked-cc → failed-cc` or `blocked-dispatcher → failed-dispatcher`, same side). For Phase 5 launch-side synthesized blocked replies only, do not increment `retry_count` and do not promote to `failed` on this tick. `timeout` is NEVER promoted to `failed` regardless of `retry_count` — it stays parked in `timeout_iids` until a human strips `timeout`, adds `retry`, or applies `continue`.
7. Use the validated reply to write `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` (see §Phase 6 Write Mapping below). The callback path processes exactly one IID — there is no per-batch "fill in missing replies" pass.
8. **Drain the pending entry.** Remove `pending_subagents[reply.iid]` and the corresponding `iid` from `active_issue_iids` / `active_issue_sessions`. Persist `campaign_state.json`.
9. **Best-effort terminal cleanup.** If `kill_subagent_on_terminal=true` and a `child_session_key` was captured before drain, Phase 6 may request `subagents kill` for terminal `done` / `blocked` / `failed` / `timeout` by returning `cleanup.action="kill"`. For `blocked` / `failed` / `timeout`, cleanup first verifies local evidence exists under `${LOG_DIR}` / `${ISSUE_ROOT}`; missing evidence yields `cleanup.action="skip", cleanup.reason="local_evidence_missing"` and preserves the runtime transcript.
10. **Best-effort 结果回报 (optional, two mutually-exclusive paths).** Only for terminal `done` / `failed` / `timeout` (NOT `blocked` — retryable, would re-report each attempt). `dispatch_followup.sh` chooses based on whether the issue carries a driven origin (`${ISSUE_ROOT}/dispatch_origin.json` with non-empty `correlation_id` + `dispatcher_callback_target`):
    - **driven path** (`RUN_SINGLE_ISSUE`) — runs `scripts/notify_dispatcher.sh` to报回 `req_dispatcher` with the **I2 result envelope** `{correlation_id, iid, project, status, mr_url, wiki_url, reason}` (`status` = `final_status`), and **SKIPS** `post_result_note.sh` (the user-facing回投 is `req_dispatcher`'s job; no `req_result` note on this path). The cross-agent send 原语 is ⚠️ **待对齐** (design §9): until aligned, `notify_dispatcher.sh` records the envelope to `${WORK_ROOT}/log/dispatcher_callbacks.jsonl` and exits 0 (留痕, never silently dropped); an empty target is a no-op. See [`trigger_command.md`](trigger_command.md) §Result callback (I2) and [§dispatch_origin.json](#issue-iiddispatch_originjson--driven-entry-origin-run_single_issue_test) above.
    - **cron path** (no `dispatch_origin.json`) — when `result_note_enabled=true`, runs `scripts/post_result_note.sh` after the drain: it reads the issue's `<!-- req_origin v1 {...} -->` marker note (written upstream by `git_issuer`, via G1b) and — **only if present** — posts a `<!-- req_result v1 {...} -->` note (via G9) carrying `{iid,status,attempt,mr_url,wiki_url,reason,ts,origin}` for an external 114-side relay to deliver to the original requester. Touches only issue **notes** — never labels / MR / state files. Full cross-region contract: the req_dispatcher workspace's `docs/integration/result_notify_loop.md`; glab forms in `references/glab_commands.md` §G14.

    Both paths are isolated identically: child stdout → `/dev/null` (never pollutes the Phase 6 envelope), wrapped in `set +e` (a failure is logged to `wrapper.log` and NEVER aborts Phase 6), and a no-op when their respective marker is absent (driven: empty `dispatcher_callback_target`; cron: no `req_origin`).

### Phase 6 Write Mapping

The dispatcher takes the validated compact reply and writes:

**`${ATTEMPT_STATE_FILE}`** (overwrite):
- `status` ← final status after validation / live-label sync / legacy `no_changes` normalization / blocked→failed promotion
- `attempt_finished_at` ← ISO-8601 UTC now
- `commit_sha` ← reply.commit_sha (empty → null)
- `wiki_artifacts_file` ← `${LOG_DIR}/wiki_artifacts.md` if reply.wiki_url is non-empty, else null
- `attempt_artifacts_posted_to_wiki` ← reply.wiki_url is non-empty
- `summary_file` ← `${SUMMARY_FILE}` if the file exists locally, else null
- `summary_posted_to_issue` ← reply.summary_posted
- `block_reason` ← final block_reason after validation / label-sync errors (empty → null)
- preserve everything Phase 4 already wrote (`attempt_number`, `mode_*`, `local_branch`, `log_dir`, `attempt_started_at`, `no_reviewer_comments`, `prior_attempt_count`)

**`${ISSUE_STATE_FILE}`** (overwrite):
- `status` ← final status after validation / live-label sync / legacy `no_changes` normalization / blocked→failed promotion
- `mode` ← reply.mode_actual
- `latest_attempt_number` ← reply.attempt_number
- `latest_attempt_dir` ← `${ISSUE_ROOT}` (canonical)
- `commit_sha` ← reply.commit_sha (empty → null)
- `merge_request_url` ← reply.merge_request_url (empty → null)
- `retry_count` ← prior + 1 if final status in {blocked, failed} and the reply is NOT a Phase 5 launch-side synthesized blocked reply; else prior unchanged. `timeout` does NOT consume retry budget.
- `block_reason` ← final block_reason after validation / label-sync errors (empty → null)
- `block_side` ← `"cc"` when final status is `done` / `blocked` (CC-side) / `failed` (CC-side) / `timeout`; `"dispatcher"` when final status is `blocked` (dispatcher-side) / `failed` (dispatcher-side); `null` when final status is `done` or `in_progress`. Determined by dispatcher internally (see §Compact Subagent Reply above); NOT derived from the subagent reply.
- `model_tier` ← updated by `dispatch_prepare_tick.sh` after `resolve_model_tier` (Phase 4); Phase 6 preserves the value set in Phase 4 unless `reconcile.sh` corrects it on the next tick
- `continue_count` ← prior + 1 if `mode_actual=continue`; else prior unchanged
- `updated_at` ← ISO-8601 UTC now
- preserve `iid`, `session`, `attempts_total` (already monotonically tracked in Phase 4)
