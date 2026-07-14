# State Schema

Runtime state lives under `${REPO_PATH}/.req_executor/`.

## Campaign State

Path:

```text
${REPO_PATH}/.req_executor/_dispatcher/campaign_state.json
```

Important fields:

- `project`
- `repo_path`
- `branch`
- `issue_min_iid`
- `issue_max_iid`
- `hourly_issue_quota`
- `max_runtime_minutes`
- `blocked_retry_limit`
- `blocked_cooldown_ticks`
- `max_concurrent_subagents`
- `stuck_after_minutes`
- `acpx_timeout_seconds`
- `kill_subagent_on_terminal`
- `result_note_enabled`
- `issue_iids_whitelist`
- `require_labels`
- `require_labels_match`
- `model_tiers`
- `continue_upgrade_threshold`
- `pending_subagents`
- `driven_launch_receipts`
- `blocked_iids`
- `failed_iids`
- `timeout_iids`
- `completed_iids`
- `last_reconcile_evidence`
- `updated_at`

There are no persisted runtime basename, data directory, or account-pool fields.
Legacy state files may still contain `run_timeout_seconds`; `load_state` deletes
that field in memory and the next state write persists the migrated shape.

### Driven project launch receipts

`driven_launch_receipts` is an optional object keyed by physical driven
`job_id`. `dispatch_record_spawn.sh` writes the current receipt in the same
atomic `campaign_state.json` persistence as the corresponding `spawned` or
`launch_failed` mutation. Each receipt contains exactly:

- `version:1`, `job_id`, positive `claim_generation`;
- `claim_token_sha256` (never the private token itself);
- `iid`, `attempt_number`, and `outcome` (`spawned|launch_failed`);
- exact `ack`: `run_id+child_session_key` or
  `launch_attempts+launch_error`;
- `recorded_at` and the exact public project recorder `result`.

The stored `result` is also an exact, typed authorization boundary. For
`spawned` it has only `status:"spawned"`, matching positive `iid` and
`attempt_number`, non-negative integer `remaining_pending_count`, and a
non-empty control-free `chat_summary`. For `launch_failed` it has only those
common result fields plus `status:"launch_failed_recorded"`,
`final_status:"blocked"`, and `cleanup`. Cleanup is exactly either
`{action:"skip",target:"",reason:"no_child_session_key"}` or
`{action:"skip",target:<non-empty control-free child key>,
reason:"preserve_terminal_evidence",status:"blocked"}`. Missing, extra,
mistyped, or unknown result values invalidate the whole receipt.

When the current `pending_subagents[iid]` exists, its job/generation/token takes
precedence over an older receipt. An exact same-claim replay returns the stored
result without persisting again, so `quota_launched_this_tick`, `spawned_at`,
`updated_at`, and file bytes do not change. `launch_failed` replay remains valid
after the pending entry was drained. A conflicting outcome, run/session,
attempt, generation, or token fails closed.

## Executor-Wide Scheduler State

Path:

```text
${EXECUTOR_SCHEDULER_ROOT}/scheduler_state.json
```

In addition to `version`, `round_robin_cursor`, `batch_order`, and
`active_jobs`, version 1 may contain positive-integer `max_concurrency`. It is
written only by `set_executor_slots.sh` under `scheduler.lock` and overrides
the deployment initialization default for all later batch sessions. A
`pending_transaction.scheduler_state` carries the same value so transaction
recovery cannot roll back a concurrent slot update.

Version 1 may also contain `launch_failed_receipts`. This optional object is
keyed by `job_id`; each value has exactly:

```json
{
  "version":1,
  "job_id":"<physical job>",
  "claim_generation":1,
  "claim_token_sha256":"<64 lowercase hex>",
  "action":"launch_failed",
  "recorded_at":0
}
```

For fixed `ACTION=launch_failed`, deleting `active_jobs[job_id]`, restoring
batch memberships to pending, and writing this receipt share one scheduler
transaction. `pending_transaction.scheduler_state` already contains the final
receipt, so transaction recovery cannot publish the deletion without its
idempotency evidence. If a current active job exists it is authoritative and
must match generation plus private token; an old receipt cannot authorize work
against a newer claim. Only when the active job is absent may an exact
job/generation/token-hash/action receipt return idempotent success. Malformed or
conflicting receipts fail closed and never expose the original token.

Durable post-spawn coordination lives in mode-600 files under:

```text
${EXECUTOR_SCHEDULER_ROOT}/launch_actions/
```

Stages advance `ack_received -> project_recorded -> scheduler_recorded ->
completed`. A tick can replay either recorder after a process dies between a
downstream commit and the following coordinator-stage write; the two receipts
above make those replays side-effect free. A zero-exit project recorder is not
enough to advance the coordinator: its complete exact result must match the
durable action outcome and the corresponding acknowledgement branch.

## Per-Issue State

Path:

```text
${REPO_PATH}/.req_executor/issues/issue-<iid>/state.json
${REPO_PATH}/.req_executor/issues/issue-<iid>/attempt_state.json
${REPO_PATH}/.req_executor/issues/issue-<iid>/summary.md
```

Legacy pre-batch `RUN_SINGLE_ISSUE` state may also contain:

```text
${REPO_PATH}/.req_executor/issues/issue-<iid>/dispatch_origin.json
```

The current compatibility shim delegates to `RUN_DRIVEN_ISSUE_BATCH` and does
not create a new `dispatch_origin.json`; existing files remain readable for
legacy recovery.

## Compact Subagent Reply

`run_executor_attempt.sh` atomically writes the exact compact result to:

```text
${LOG_DIR}/worker_result.json
```

The outer subagent normally echoes that same line as its final reply. The
heartbeat may instead consume the file through claim-fenced result reconcile
when OpenClaw does not schedule the final model turn. The object has exactly:

- `iid`
- `attempt_number`
- `status`: `done`, `no_changes`, `blocked`, `failed`, or `timeout`
- `mode_actual`, `work_branch`, `local_branch`
- `commit_sha`, `merge_request_url`, `mr_action`
- `wiki_url` (legacy compatibility; new replies keep it empty)
- `labels_added`, `labels_removed`, `summary_posted`
- `block_reason`, `log_dir`

Immediately after the inner acpx process exits, `run_acpx_attempt.sh` also
atomically writes:

```text
${LOG_DIR}/acpx_terminal.json
```

Its exact version-1 object contains `version`, `iid`, `attempt_number`,
`exit_code`, and `completed_at_epoch`. This marker is not a terminal Issue
result; it only proves that acpx itself is no longer running and starts the
bounded post-acpx watchdog.

`dispatch_followup.sh` validates the IID and attempt number against `pending_subagents` before mutating state.
