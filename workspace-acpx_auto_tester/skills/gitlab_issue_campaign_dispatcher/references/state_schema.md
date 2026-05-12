# State File Schemas

Disk state is a **cache**, not source of truth. GitLab is the source of truth (see Source-of-Truth Policy in `SKILL.md`). These files exist for progress tracking and resumption only.

There are three state files in this workspace:

| File                                            | Owner                          | Lifecycle                                     |
| ----------------------------------------------- | ------------------------------ | --------------------------------------------- |
| `_dispatcher/campaign_state.json`               | dispatcher (campaign-level)    | persisted across ticks; mutated each tick     |
| `ifp-result/issue-<iid>/state.json`             | dispatcher (cross-attempt)     | persisted across attempts; one per IID        |
| `ifp-result/issue-<iid>/attempt_state.json`     | dispatcher (per-attempt)       | overwritten on each new attempt               |

**State-file write ownership:** the **dispatcher writes all state files**, including the terminal updates. The dispatcher's Phase 4 (per-IID prep) initializes the in-progress values in `issue-<iid>/state.json` and `issue-<iid>/attempt_state.json`. The subagent's compact JSON reply (see §Compact Subagent Reply below) carries every fact the dispatcher needs; the dispatcher's Phase 6 follow-up writes the terminal values from that reply. The subagent does NOT touch any state file.

## campaign_state.json

Path: `${CAMPAIGN_STATE_FILE}` (i.e. `${WORK_ROOT}/campaign_state.json` = `${REPO_PATH}/ifp-result/_dispatcher/campaign_state.json`; default `/data/${PROJECT}/ifp-result/_dispatcher/campaign_state.json`)

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
  "stuck_after_minutes": 330,
  "kill_subagent_on_terminal": true,
  "kill_subagent_on_done": true,
  "issue_iids_whitelist": [14, 17, 20],
  "require_labels": ["acpx-auto", "priority::high"],
  "require_labels_match": "and",
  "result_basename": "ifp-result",
  "data_basename": "ifp-data",
  "next_new_issue_iid": 4,
  "active_issue_iids": [14],
  "active_issue_sessions": ["issue-px_ifp_hulat-14"],
  "pending_subagents": {
    "14": {
      "attempt_number": 3,
      "run_id": "9710b359-2f32-407b-8c54-5c995ba266dc",
      "child_session_key": "agent:acpx_auto_tester:subagent:b6719233-bcc8-4418-b401-c5f5f752609a",
      "ui_account_index": 0,
      "spawned_at": "2026-05-06T10:00:12Z"
    }
  },
  "unfinished_iids": [9, 10, 14, 15],
  "completed_iids": [1, 2, 3],
  "blocked_iids": [],
  "failed_iids": [],
  "campaign_status": "waiting_for_callbacks",
  "quota_launched_this_tick": 1,
  "last_reconcile_evidence": "/data/<project>/ifp-result/_dispatcher/log/reconcile-20260507T100501Z.json",
  "updated_at": "2026-05-07T10:05:30Z"
}
```

### `pending_subagents` — async-callback bookkeeping

Map keyed by stringified IID. Each entry tracks one in-flight subagent from spawn (`sessions_spawn` launch ack) to drain (`RUN_CHILD_COMPLETION_CALLBACK` processed by Phase 6) or eviction (stuck-pending past `stuck_after_minutes`).

| Field                | Type   | Notes                                                                                          |
| -------------------- | ------ | ---------------------------------------------------------------------------------------------- |
| `attempt_number`     | int    | The attempt number allocated for this subagent. Phase 6 validates `callback.attempt_number == this` to reject stale callbacks. |
| `run_id`             | string \| null | The `runId` returned by `sessions_spawn`. `null` only between Phase 4 step 5 (placeholder write) and Phase 5 step 2 (post-launch update); the orchestrator MUST NOT leave a `null` run_id once Phase 5 has finished. |
| `child_session_key`  | string \| null | The anonymous `childSessionKey` returned by `sessions_spawn` (e.g. `agent:acpx_auto_tester:subagent:<uuid>`). For runtime-side audit only; not used for matching callbacks. Same nullability rule as `run_id`. |
| `ui_account_index`   | int    | The 0-based index in `<workspace>/config/ui_accounts.env` allocated to this subagent. With `max_concurrent_subagents=1` this is always `0`; with `N>1` the orchestrator binds `account[k]` → the `k`-th IID of the batch (k = 0..batch_size-1). |
| `spawned_at`         | ISO-8601 UTC \| null | The orchestrator's wall-clock timestamp when `sessions_spawn` returned its launch ack. Used for stuck-pending eviction (`now - spawned_at >= stuck_after_minutes`). `null` between placeholder write and launch ack receipt; an entry with `null` `spawned_at` past `Phase 5 → end-of-tick` is itself a stuck case and gets evicted on the next scheduled wake-up. |

A `pending_subagents` entry with `placeholder: true` is a transient state during Phase 4 step 5 / Phase 5; it MUST NOT survive the end of the scheduled wake-up. If a crash leaves a placeholder behind, the next scheduled wake-up's stuck-pending eviction (which inspects `spawned_at`) treats it as stuck and synthesizes a blocked Phase 6 reply (`block_reason="placeholder pending entry survived: spawn was never observed to land"`).

### `active_issue_iids` / `active_issue_sessions` semantics under async-callback

These two arrays are now **redundant with `pending_subagents` keys** but retained for backward compatibility and cheap human-readable logging:

- `active_issue_iids[k]` = the IID
- `active_issue_sessions[k]` = the **logical** label `issue-<project>-<iid>` (NOT the runtime `child_session_key` — that lives in `pending_subagents[iid].child_session_key`)

The orchestrator MUST keep these two arrays in lockstep with `pending_subagents` keys: write all three in one persist; drain all three in one persist.

### Fresh-init values (when the file does not exist)

```text
next_new_issue_iid        = issue_min_iid
max_concurrent_subagents  = 1
stuck_after_minutes       = 330
kill_subagent_on_terminal = true
kill_subagent_on_done     = true
issue_iids_whitelist      = []
require_labels            = []
require_labels_match      = "or"
result_basename           = "ifp-result"
data_basename             = "ifp-data"
repo_path                 = "/data"
active_issue_iids         = []
active_issue_sessions     = []
pending_subagents         = {}
unfinished_iids           = []
completed_iids            = []
blocked_iids              = []
failed_iids               = []
campaign_status           = running
quota_launched_this_tick  = 0
```

### Optional filter fields

| Field                   | Type            | Notes                                                                 |
| ----------------------- | --------------- | --------------------------------------------------------------------- |
| `issue_iids_whitelist`  | array of int    | Post-override snapshot of the trigger's `issue_iids` field. Empty `[]` = no whitelist (full `[issue_min_iid, issue_max_iid]` range). When non-empty, the effective IID universe = range ∩ this list (IIDs outside range are silently dropped at Phase 1). Stuck-pending eviction is **not** filtered by this list. |
| `require_labels`        | array of string | Post-override snapshot of the trigger's `require_labels` field. Empty `[]` = no label filter. When non-empty, applied at Phase 3 against live GitLab labels from the reconcile evidence file. Case-sensitive. |
| `require_labels_match`  | `"or"` / `"and"` | Combinator for `require_labels`. Defaults to `"or"`. Ignored when `require_labels` is empty. Any other value = tick-level abort with `"invalid_require_labels_match"`. |
| `kill_subagent_on_terminal` | bool | Post-override snapshot of the trigger's terminal cleanup gate. Defaults to `true`. When true, Phase 6 may best-effort kill terminal `done` / `blocked` / `failed` child sessions after state files are persisted; `blocked` / `failed` cleanup additionally requires local evidence under `${LOG_DIR}` / `${ISSUE_ROOT}`. |
| `kill_subagent_on_done` | bool | Legacy compatibility snapshot only. New deployments should use `kill_subagent_on_terminal`; if the new field is missing and this legacy field is explicitly `false`, the loader disables terminal cleanup. |
| `repo_path`             | string          | Post-override snapshot of the trigger's `repo_path` parent directory. Defaults to `"/data"`. `env_paths.sh` derives final `REPO_PATH=${repo_path}/${PROJECT}` as the clone target and acpx cwd. Tick aborts with `"invalid_repo_path"` when the value is not an absolute parent directory or contains `..`, whitespace, or shell-unsafe characters outside `[A-Za-z0-9_./-]`. This field is persisted for audit, but non-default deployments must still pass `repo_path` on every scheduled trigger and callback because the dispatcher needs it before reading this file. |
| `result_basename`       | string          | Post-override snapshot of the trigger's `result_basename`. Defaults to `"ifp-result"`. Used by `env_paths.sh` to derive `RESULT_ROOT=${REPO_PATH}/${result_basename}` and forwarded to every script as `RESULT_BASENAME=...`. Tick aborts with `"invalid_result_basename"` when the value contains `/`, `..`, or whitespace. |
| `data_basename`         | string          | Post-override snapshot of the trigger's `data_basename`. Defaults to `"ifp-data"`. Forwarded as `DATA_BASENAME=...` and rendered into the subagent prompt. Same validation as `result_basename`. |

### Legacy on-disk shapes the loader must tolerate

Some on-disk files written by older deployments may be missing fields or use the old scalar shape. The loader normalizes them in memory and persists the current shape on the next write.

- **Legacy scalar `active_issue_iid` / `active_issue_session`** — if present and no `active_issue_iids` / `active_issue_sessions` array exists, treat as `[scalar]` (or `[]` if the scalar was `null`). On the next write, persist only the array shape.
- **Missing `pending_subagents`** — treat as `{}` in memory; persist on next write.
- **Missing `max_concurrent_subagents`** — default to `1` and persist.
- **Missing `stuck_after_minutes`** — default to `330` and persist.
- **Missing `kill_subagent_on_terminal`** — default to `true` and persist. If the new field is missing but legacy `kill_subagent_on_done` is present and explicitly `false`, set and persist `kill_subagent_on_terminal=false` for compatibility. This gate controls whether Phase 6 step 9 calls the `subagents` kill tool after terminal `done` / `blocked` / `failed` outcomes; blocked/failed cleanup is additionally gated on local evidence existence.
- **Missing `kill_subagent_on_done`** — default to the same value as `kill_subagent_on_terminal` and persist only for backward-readable audit. New logic should not use it except for the compatibility rule above.
- **Missing `quota_launched_this_tick`** — default to `0` and persist (it is reset to `0` at the top of every scheduled wake-up anyway).
- **`active_issue_iids` entries with no matching `pending_subagents` key** — stale (the orchestrator was synchronous before async-callback; nothing was actually in-flight if the prior tick exited cleanly). Drop them on read: clear `active_issue_iids` / `active_issue_sessions` and persist. The next scheduled wake-up re-schedules those IIDs from disk state.
- **Missing `issue_iids_whitelist` / `require_labels` / `require_labels_match`** — default to `[]` / `[]` / `"or"` and persist on next write. These fields are NOT carried forward across ticks beyond the trigger's say-so: each scheduled wake-up's Phase 1 OVERRIDES them with the trigger's current values (or with defaults when the trigger omits them). The on-disk copy is for audit and crash-recovery only.
- **Missing `repo_path`** — default to `"/data"` in memory and persist on next write. This is a bootstrap path snapshot only; if the operator configured a non-default clone parent, the trigger/callback still has to provide it so the dispatcher can locate this state file before loading it.
- **Missing `result_basename` / `data_basename`** — default to `"ifp-result"` / `"ifp-data"` in memory and persist on next write. Each scheduled wake-up's Phase 1 may OVERRIDE them with the trigger's current values; when the trigger omits the fields, the persisted value is retained (these basenames are deployment-stable per project, unlike the per-tick filter fields above).

The dispatcher MUST NOT keep both the scalar and the array fields in the persisted file — pick the array shape per write and drop the legacy scalars.

### Possible `campaign_status` values

- `running` — between scheduled wake-ups, when no batch is in flight
- `waiting_for_callbacks` — set by Phase 5 after spawning a batch; cleared back to `running` once the last pending entry drains (or all evicted)
- `completed` — every IID in range terminal AND `pending_subagents` empty

`completed` may only be set when reconciliation has just run AND every IID in range has `is_done_on_gitlab == true` (live state is `closed` OR live labels contain both `done` and `pr`) AND `needs_continue == false` in the evidence file AND `pending_subagents == {}`.

## issue-<iid>/state.json — cross-attempt issue state

Path: `${ISSUE_STATE_FILE}` = `${ISSUE_ROOT}/state.json`

Initialized by `scripts/allocate_attempt.sh` (which the dispatcher runs before each spawn). The dispatcher's Phase 4 prep refreshes `status="in_progress"` / `mode` / `attempts_total` / `latest_attempt_*` before spawn. The dispatcher's Phase 6 follow-up writes the terminal `status` / `commit_sha` / `merge_request_url` / `block_reason` from the subagent's compact JSON reply or from an inline-synthesized blocked reply. Launch-side `sessions_spawn` failures preserve `retry_count`; other blocked/failed outcomes consume that budget. The subagent does NOT write this file.

```json
{
  "iid": 14,
  "session": "issue-px_ifp_hulat_test-14",
  "status": "in_progress",
  "mode": "continue",
  "attempts_total": 2,
  "latest_attempt_number": 2,
  "latest_attempt_dir": "/data/<project>/ifp-result/issue-14",
  "retry_count": 1,
  "block_reason": null,
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
| `retry_count`           | int             | How many blocked/failed outcomes have consumed the cross-tick retry budget. Launch-side `sessions_spawn` failures after in-tick retry exhaustion do not increment it. |
| `block_reason`          | string \| null  | Required when `status=blocked` or `failed`.                            |
| `commit_sha`            | string \| null  | Latest pushed commit SHA when applicable.                              |
| `merge_request_url`     | string \| null  | Strategy A: single MR per issue in fresh mode; rotated in continue mode. |
| `updated_at`            | ISO-8601 UTC    | Update at every major step.                                            |

### Possible `status` values

| Status        | When written                                                                 | Terminal? |
| ------------- | ---------------------------------------------------------------------------- | --------- |
| `pending`     | After dispatcher reconciliation re-enqueues; before dispatcher prep starts.  | no        |
| `in_progress` | After dispatcher prep finishes (repo checkout + prompt ready); during Claude execution and post-acpx subagent flow. | no |
| `blocked`     | Retryable failure (auth, runtime mismatch, dispatcher prep failed for this IID, post-push fetch failed, etc.). | no |
| `failed`      | Non-recoverable, or `retry_count > blocked_retry_limit`.                     | yes       |
| `done`        | After post-push verification, Wiki evidence publication, `doing → done`, MR creation / rotation, and `pr` label addition succeeded. | yes |
| `no_changes`  | Legacy compact-reply value for `stage_and_guard.sh` `NO_CHANGES`; new prompts normalize this to `blocked` because no MR / `pr` label can be produced. | no |

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
  "log_dir": "/data/<project>/ifp-result/issue-14/log/attempt-002",
  "commit_sha": "abc1234...",
  "wiki_artifacts_file": "/data/<project>/ifp-result/issue-14/log/attempt-002/wiki_artifacts.md",
  "attempt_artifacts_posted_to_wiki": true,
  "status": "done",
  "block_reason": null,
  "summary_file": "/data/<project>/ifp-result/issue-14/summary.md",
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
| `prior_attempt_count`     | continue mode only — number of past `acpx_auto_tester:attempt-summary` notes (plus legacy pre-rename attempt-summary notes) the prompt included |
| `local_branch`            | per-attempt local branch (`${LOCAL_ATTEMPT_BRANCH}`)                                      |
| `log_dir`                 | `${LOG_DIR}` for this attempt                                                             |
| `wiki_artifacts_file`     | `${LOG_DIR}/wiki_artifacts.md` once `upload_attempt_artifacts.sh` has posted Wiki links to GitLab |
| `attempt_artifacts_posted_to_wiki` | true after `prompt.txt`, `claude_result.txt`, and optional `report.html` were published to the project Wiki and linked from the issue |
| `summary_file`            | `${SUMMARY_FILE}` once `summarize_attempt.sh` has run                                     |
| `summary_posted_to_issue` | true after the summary was successfully posted as a GitLab issue note                     |

The dispatcher's Phase 4 prep initializes `attempt_started_at`, `mode_*`, `no_reviewer_comments`, `prior_attempt_count`, `local_branch`, `log_dir`, `status="in_progress"` before spawn. The dispatcher's Phase 6 follow-up writes the terminal `status` / `attempt_finished_at` / `commit_sha` / `wiki_artifacts_file` / `attempt_artifacts_posted_to_wiki` / `summary_posted_to_issue` / `block_reason` from the subagent's compact JSON reply. The subagent does NOT write this file.

---

## Compact Subagent Reply

The subagent returns a single compact JSON line on the LAST line of its turn. The dispatcher (Phase 6 of the algorithm) reads this reply and uses it to write the terminal `issue-<iid>/state.json` and `issue-<iid>/attempt_state.json`, drain the IID from `active_issue_iids`, classify the IID into the right `campaign_state.json` list, and (optionally) post a per-IID summary to a notification channel.

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
  "log_dir": "/data/<project>/ifp-result/issue-14/log/attempt-003"
}
```

### Field reference

| Field                | Type            | Notes                                                                  |
| -------------------- | --------------- | ---------------------------------------------------------------------- |
| `iid`                | int             | Must match the dispatched IID. The dispatcher rejects mismatches.      |
| `attempt_number`     | int             | Must match `${ATTEMPT_NUMBER}` from the rendered prompt.               |
| `status`             | string (enum)   | `done` / `no_changes` / `blocked` / `failed`. See §Possible status values above. New subagent prompts convert no-diff outcomes to `blocked`; `no_changes` is accepted only for legacy replies and normalized by the dispatcher. The subagent prefers `blocked` — the dispatcher promotes `blocked → failed` in Phase 6 when retry budget exhausted. |
| `mode_actual`        | string (enum)   | `fresh` / `continue` — what `prepare_attempt.sh` actually ran (continue can downgrade to fresh inside `prepare_attempt.sh`). |
| `work_branch`        | string          | `issue/<iid>-auto-fix` — the single force-pushed remote branch.        |
| `local_branch`       | string          | `${LOCAL_ATTEMPT_BRANCH}` — per-attempt local branch kept for audit.   |
| `commit_sha`         | string          | Empty `""` if Step 3 did not run (no_changes / blocked-before-commit). |
| `merge_request_url`  | string          | Empty `""` if Step 7 did not run.                                      |
| `mr_action`          | string (enum)   | `created` / `rotated` / `none`. `rotated` when one or more prior open MRs were closed before creating the new one, `created` when no prior open MR existed, `none` when Step 7 did not run. The legacy `reused` value is retired — both fresh and continue modes now always close + create. |
| `wiki_url`           | string          | First Wiki page URL printed by `upload_attempt_artifacts.sh`. Empty if Step 5 did not run. |
| `labels_added`       | array of string | The labels the subagent ADDED in Steps 6 / 7b or fail-flow label sync (e.g. `["done","pr"]` for done, `["blocked"]` for a blocked failure before done). |
| `labels_removed`     | array of string | The labels the subagent REMOVED in Step 6 or fail-flow label sync (e.g. `["doing"]`). |
| `summary_posted`     | bool            | `true` iff `summarize_attempt.sh` posted a GitLab issue note. Failure paths set `SUMMARY_POST_TO_ISSUE=false`, so this is normally `false` even when `${SUMMARY_FILE}` was written locally. |
| `block_reason`       | string          | Required non-empty when `status` is `blocked` or `failed`; empty `""` otherwise. |
| `log_dir`            | string          | Absolute path; mirrors `${LOG_DIR}`. Helps the dispatcher locate logs without re-deriving paths. |

### Tolerated variations

- The subagent may emit `null` instead of `""` for empty string fields. The dispatcher normalizes both to empty.
- The subagent may omit `labels_added` / `labels_removed` for legacy non-done terminals — the dispatcher treats omission as `[]` and still performs Phase 6 live-label synchronization.
- Trailing whitespace / a single trailing newline after the JSON line is OK; nothing else may appear after the JSON on the subagent's last turn.

### Dispatcher-side validation (Phase 6)

The compact reply arrives in two ways:

- **Callback path** — the runtime delivers `RUN_CHILD_COMPLETION_CALLBACK` carrying the full compact JSON in `worker_result_json`. One callback per subagent.
- **Inline-synthesized path** — Phase 5 launch failure after in-tick retry exhaustion / stuck-pending eviction at the top of a scheduled wake-up; the orchestrator constructs a minimal blocked reply on the spot. Phase 5 launch failures are tracked as launch-side internally for retry accounting; this is not a compact-reply field.

The validation pipeline is the same in both paths:

1. Parse `worker_result_json` (callback path) or use the synthesized object directly. On parse failure, treat as a synthetic blocked reply: `{"iid":<callback.iid>,"attempt_number":<callback.attempt_number>,"status":"blocked","block_reason":"callback worker_result_json not valid JSON: <first 200 chars>"}` and continue with that.
2. **Match to a `pending_subagents` entry by `iid` + `attempt_number`.** This is the canonical identity check (replacing both session-name dedup AND the old "match against this batch's dispatch list").
   - Look up `pending_subagents[reply.iid]`. If the entry does not exist → return `"callback_status":"stale_or_already_drained"` (the IID was already drained by a prior callback / eviction). Do NOT mutate state files.
   - Verify `pending_subagents[reply.iid].attempt_number == reply.attempt_number`. Mismatch (most commonly: a stale callback for an older attempt) → return `"callback_status":"stale_or_already_drained"`. Do NOT mutate state files.
   - Optionally cross-check `pending_subagents[reply.iid].run_id` against `callback.run_id` (when present). Mismatch is logged but does not reject — the canonical identity is `iid + attempt_number`.
3. Normalize legacy `reply.status="no_changes"` to `status="blocked"` and set `block_reason="subagent produced no staged changes"` when the reply did not provide a reason.
4. If `reply.status in {blocked, failed}`, require non-empty `reply.block_reason`. Empty → mark `blocked` with `block_reason="subagent reply status=<status> with empty block_reason"`.
5. Synchronize live GitLab workflow labels from the final status with `scripts/set_issue_label.sh`: `done` ends as `done` + `pr`, `blocked` ends as no `doing` + `blocked`, and `failed` ends as no `doing` / `blocked` + `failed`. Any required live-label sync failure converts a non-failed result to `blocked` with `block_reason` appended.
6. If `status=blocked` AND `retry_count > blocked_retry_limit` (after incrementing), promote to `status=failed`, add to `failed_iids`, and run failed-label sync. For Phase 5 launch-side synthesized blocked replies only, do not increment `retry_count` and do not promote to `failed` on this tick.
7. Use the validated reply to write `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` (see §Phase 6 Write Mapping below). The callback path processes exactly one IID — there is no per-batch "fill in missing replies" pass.
8. **Drain the pending entry.** Remove `pending_subagents[reply.iid]` and the corresponding `iid` from `active_issue_iids` / `active_issue_sessions`. Persist `campaign_state.json`.
9. **Best-effort terminal cleanup.** If `kill_subagent_on_terminal=true` and a `child_session_key` was captured before drain, Phase 6 may call `subagents kill` for terminal `done` / `blocked` / `failed`. For `blocked` / `failed`, cleanup first verifies local evidence exists under `${LOG_DIR}` / `${ISSUE_ROOT}`; missing evidence yields `cleanup_status="skipped: local_evidence_missing"` and preserves the runtime transcript.

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
- `retry_count` ← prior + 1 if final status in {blocked, failed} and the reply is NOT a Phase 5 launch-side synthesized blocked reply; else prior unchanged
- `block_reason` ← final block_reason after validation / label-sync errors (empty → null)
- `updated_at` ← ISO-8601 UTC now
- preserve `iid`, `session`, `attempts_total` (already monotonically tracked in Phase 4)
