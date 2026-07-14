# Dispatcher Wrappers

The LLM orchestrator does not hand-write campaign logic. It calls shell wrappers and acts only on their JSON envelopes.

## `dispatch_prepare_tick.sh`

Owns scheduled preparation:

- parses and validates `RUN_SCHEDULED_ISSUE_CAMPAIGN`
- sources `env_paths.sh`
- loads and persists `.req_executor/_dispatcher/campaign_state.json`
- reconciles GitLab labels
- forms the eligible IID batch
- allocates attempt numbers
- prepares per-IID worktrees
- builds `${LOG_DIR}/prompt.txt`
- renders `${LOG_DIR}/spawn_payload.txt`
- emits `dispatch_entries[]` for `sessions_spawn`

It does not read runtime basename, data directory, or account-pool trigger fields.

## `dispatch_record_spawn.sh`

Records a `sessions_spawn` result for one IID. On launch failure it synthesizes a blocked Phase 6 reply and drains the pending entry.

When the fixed driven wrapper supplies `DRIVEN_JOB_ID`,
`DRIVEN_CLAIM_GENERATION`, and `DRIVEN_CLAIM_TOKEN`, all three are mandatory.
The recorder stores only the token SHA-256 plus the exact runtime outcome and
result under `campaign_state.json.driven_launch_receipts[job_id]` in the same
atomic persistence as the state mutation. Exact replay is read-only; conflict
replay fails closed. Receipt replay validates the complete exact typed result,
including the only reachable driven launch-failure status (`blocked`) and the
two exact Phase 6 cleanup shapes; malformed fields cannot authorize replay.
Scheduled calls without those fields retain the legacy behavior.

## `record_executor_batch_spawn.sh`

Consumes one strict driven `spawned` or `launch_failed` result, recovers the
private claim, and advances `ack_received -> project_recorded ->
scheduler_recorded -> completed`. It always records project state first. A
later tick may call it with the durable exact outcome when the process died
after either downstream commit; project receipts and scheduler
`launch_failed_receipts` make those calls idempotent. The project boundary
accepts only the complete exact result shape for the durable action's
`spawned` or `launch_failed` outcome. A partial or forged zero-exit response
leaves the action at `ack_received` for safe recovery.

## `record_driven_batch_launch.sh`

`ACTION=launch_failed` requires a positive claim generation and matching private
token. Its scheduler transaction both removes the active job and writes a
token-hash-bound tombstone. If no active job remains, only the exact same
job/generation/token/action may replay successfully; a current active claim is
always authoritative over an older tombstone.

## `ingest_subagent_completion.sh` and `dispatch_followup.sh`

`ingest_subagent_completion.sh` authenticates an OpenClaw native
`task_completion` event, or one bounded non-truncated `sessions_history`
recovery envelope, against the pending run/session/attempt identity. It then
passes exactly one strict compact worker JSON object to `dispatch_followup.sh`.
The followup rechecks the same identity while holding the campaign lock,
reconciles the IID, writes terminal state, updates labels, optionally reports
results back to `req_dispatcher`, and emits cleanup instructions. Direct legacy
compact JSON is accepted only when the pending record explicitly carries
`completion_auth:"legacy"`.

For scheduler-internal recovery, `dispatch_followup.sh` also accepts a
token-digest claim fence. Completion-reconcile mode first repeats a narrow
GitLab read under `campaign.lock`; only live `pr`/closed evidence may atomically
drain pending and persist a claim-bound `skipped` handoff intent. Timeout mode
keeps the existing running-lease plus project ACPX-deadline backstop. Durable
result mode accepts one non-empty compact worker result, rechecks the exact
job/generation/token digest, runs ordinary Phase 6, and returns a kill cleanup
for the stale native child only after state persistence.

## `run_executor_attempt.sh` and post-acpx recovery

The outer per-IID subagent invokes `run_executor_attempt.sh` once. It keeps
`run_acpx_attempt.sh`, stage, commit/push, verification, labels, MR, and summary
inside one bounded Bash process. It atomically persists mode-600
`${LOG_DIR}/worker_result.json` before printing the same compact JSON.
`run_acpx_attempt.sh` separately persists mode-600
`${LOG_DIR}/acpx_terminal.json` immediately after the inner process exits.

`run_executor_batch_tick.sh` checks those attempt-scoped files only for an
exact currently pending job/generation. A worker result is sent through the
claim-fenced durable-result followup mode and produces `cleanup_actions[]`.
An acpx-only marker produces cleanup only after the post-acpx grace period, so
a legitimately running inner acpx process is never reaped by this watchdog.

## `reap_driven_orphan_placeholders.sh`

Consumes the protected physical-job IDs built by `run_executor_batch_tick.sh`
from current scheduler jobs plus unfinished launch coordinators. Under the
project campaign lock it removes only scheduler-driven `placeholder:true`
entries whose `run_id`, `child_session_key`, and `spawned_at` are null and whose
exact safe `job_id` is not protected. It never guesses from IID, attempt, batch
labels, or malformed identity, and it returns unresolved IIDs explicitly.

## Standard Env

All wrappers accept:

```text
PROJECT
GROUP
GITLAB_TOKEN
REPO_PARENT_PATH   # optional; defaults to /data
```

Per-IID wrappers additionally receive `ISSUE_IID` and `ATTEMPT_NUMBER`. `env_paths.sh` derives every path from those values and the fixed `.req_executor` runtime directory.
