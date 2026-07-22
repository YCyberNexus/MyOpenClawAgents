# Dispatcher Wrappers

The LLM orchestrator does not hand-write campaign logic. It calls shell wrappers and acts only on their JSON envelopes.

## `dispatch_prepare_tick.sh`

Owns scheduled preparation:

- parses and validates `RUN_SCHEDULED_ISSUE_CAMPAIGN`
- sources `env_paths.sh`
- loads and persists `.req_executor/_dispatcher/campaign_state.json`
- reconciles GitLab labels
- forms the eligible IID batch
- uses frozen-scope graph evidence only for topology already visible, without
  changing or delaying an ordinary A
- when C declares A, migrates completed `issue/<A>` at the exact A SHA onto
  `issue/<A>+<C>` through a replayable branch/MR transaction
- defers C until A's stable `pr`/`finish`, migrated shared branch, durable
  commit SHA, replacement MR identity, and campaign `pending` drain all agree
- allocates execution identities
- prepares per-IID worktrees
- builds `${LOG_DIR}/prompt.txt`
- renders execution-scoped payload, manifest, and spawn-bootstrap files under `${LOG_DIR}`
- emits `dispatch_entries[]` for `sessions_spawn`

It does not read runtime basename, data directory, or account-pool trigger fields.
Dependency planning and waiting happen before allocation and placeholder
persistence, so they do not consume retry budget or create an execution identity. Version 1 supports
only a two-node one-to-one A -> C pair. Fan-out, a longer chain, cycles,
duplicate persisted membership, a changed edge, or a changed target fail
closed. An incomplete frozen scope does not block an ordinary A; a later C may
bind an already-completed A from the same batch or an earlier campaign.

The project envelope exposes `dependency_waiting[]` with `iid`,
`dependency_iid`, `branch`, and a stable reason. Before an IID is known, scope
or API uncertainty uses null dependency fields. Once known, C waits on
`dependency_not_completed`, `dependency_branch_migration_pending`, or
`dependency_commit_unverified` for the shared `issue/A+C` branch. Bounded API
or parser uncertainty remains non-terminal. Driven mode returns deterministic
failures as exact `skipped_entries[]`, allowing the scheduler to terminalize
the physical job after project state is durable. Driven
mode also returns exact scheduler identities in `deferred_entries[]`; the
agent-wide tick releases those jobs only after bounded ordinary skip/refill
processing. One topup transaction is limited to 256 candidates, 32 refill
rounds, a 90-second phase deadline, and a 75-second project-wrapper timeout;
all child commands and nested locks use the remaining phase budget, and
remaining reserved jobs are retried by the next tick. A migrated
`legacy_running` job cannot take the non-terminal deferral path because it has
no secret claim token; the wrapper reports `legacy_running_recovery_required`
without mutating it.
The fresh C worktree is based on A's verified immutable SHA while direct control
paths at any depth (`.claude/`, `CLAUDE.md`, `CLAUDE.local.md`, `.mcp.json`,
`.acpxrc.json`) come from the original trusted `CONFIG_BRANCH`. Ordinary
business scripts remain part of the baseline; this overlay is not an OS
sandbox. A and C keep different fixed IID-local branches but push to the same
frozen remote branch. C receives A's SHA as both dependency baseline and exact
lease; its commit must have exactly that one parent. Continue may resume only
when durable state binds the exact shared branch, members, roles, dependency
tuple, resume ref, and resume SHA. Missing, legacy, dependency-free-tail, or
mismatched metadata fails closed; current Issue text never rewrites ancestry.

A initially creates an ordinary A-only MR. The late-binding transaction closes
that MR and creates the only open shared replacement containing closing
references for both members; the closed old IID remains as audit history. C
requires the exact replacement MR URL/IID persisted by A and reuses it without
close/create rotation. Shared groups reject `auto_merge=true`; ordinary
non-dependent jobs retain the existing automatic-merge verification path.

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

## `emit_driven_batch_acceptance.sh`

Rebuilds the exact five-field I1 receipt from durable scheduler state. Before
emitting success it scans all hot launch actions and rejects any action still
at `action_emitted`; the embedded global tick may return a grant owned by an
older batch. This is the deterministic fence between
the intake wrapper and the OpenClaw-only runtime call: skipping
`sessions_spawn` or its mandatory recorder can no longer look like successful
batch acceptance. `ack_received` and later stages are safe because the runtime
identity is already durable and heartbeat recovery owns the remaining recorder
stages. A live path that concurrently moves to the cold archive is accepted
only when the same basename is present there with `stage=completed`; other
read/layout errors remain fail-closed.

The executor heartbeat pairs that fence with bounded recovery. A hot
`action_emitted` record waits on its dedicated spawn-ack lease (180 seconds by
default). At expiry, the tick permits `reserve_driven_batch_items.sh` to recover
only the exact matching preparing job, stops before project top-up, and emits
the ordinary runtime-evidence reconciliation action. This prevents an
interrupted older batch from holding every later intake behind a permanent ACK
gate without weakening the no-duplicate-spawn fence.

## `record_driven_batch_launch.sh`

`ACTION=launch_failed` requires a positive claim generation and matching private
token. Its scheduler transaction both removes the active job and writes a
token-hash-bound tombstone. If no active job remains, only the exact same
job/generation/token/action may replay successfully; a current active claim is
always authoritative over an older tombstone.

`ACTION=dependency_deferred` is scheduler-internal and fail-closed. A reserved
job accepts only claim generation zero with no token; a running job requires
its exact positive generation and private token. The same transaction removes
the active job, changes every owning or attached membership to `retry_wait`,
clears physical-job links, increments `defer_count`, and leaves terminal
counters unchanged. The next reservation receives a defer-generation job-ID
suffix so stale claims cannot collide with it.

## `ingest_subagent_completion.sh` and `dispatch_followup.sh`

`ingest_subagent_completion.sh` authenticates an OpenClaw native
`task_completion` event, or one bounded non-truncated `sessions_history`
recovery envelope, against the pending run/session/execution identity. It then
passes exactly one strict compact worker JSON object to `dispatch_followup.sh`.
The followup rechecks the same identity while holding the campaign lock,
reconciles the IID, writes terminal state, updates labels, optionally reports
results back to `req_dispatcher`, and emits cleanup instructions. Direct legacy
compact JSON is accepted only when the pending record explicitly carries
`completion_auth:"legacy"`.

For scheduler-internal recovery, `dispatch_followup.sh` also accepts a
token-digest claim fence. Completion-reconcile mode first repeats a narrow
GitLab read under `campaign.lock`; only live `pr`/`finish`/closed evidence may atomically
drain pending and persist a claim-bound `skipped` handoff intent. Timeout mode
keeps the existing running-lease plus project ACPX-deadline backstop. Durable
result mode accepts one non-empty compact worker result, rechecks the exact
job/generation/token digest, runs ordinary Phase 6, and returns a kill cleanup
for the stale native child only after state persistence.

The fixed outer execution performs the first authorization before Phase 6:
`merge_mr.sh` uses exact GET, SHA-fenced PUT, and exact GET, then
`run_executor_attempt.sh` atomically writes `finish` only for the matching
server-side merged result. Phase 6 does not postpone this first label update;
it separately gates durable terminal persistence and callback emission with a
bounded read-only verification of the same MR identity, branches, and SHA.

If the automatic-merge compact result is empty or unavailable, Phase 6 may
recover identity only from the current execution's mode-600, regular non-symlink
`${LOG_DIR}/mr_result.json`, with exact Issue, execution ID, canonical source branch,
frozen merge target, and SHA checks. A marker or callback by itself never
authorizes `finish` or a successful terminal callback; the independent live
verification remains mandatory.

## `run_executor_attempt.sh` and post-acpx recovery

The outer per-IID subagent invokes `run_executor_attempt.sh` once. It keeps
`run_acpx_attempt.sh`, stage, commit/push, verification, labels, MR, summary,
and terminal log archival inside one bounded Bash process. It atomically
persists mode-600 `${LOG_DIR}/worker_result.json`, publishes the complete
terminal directory on append-only branch
`req-executor-logs/issue-<iid>/execution-<execution_id>`, then prints the same
compact JSON. The archive branch is separate so it cannot move the business/MR
SHA or violate shared-branch commit topology.
`run_acpx_attempt.sh` separately persists mode-600
`${LOG_DIR}/acpx_terminal.json` immediately after the inner process exits.

`run_executor_batch_tick.sh` checks those issue-local files only for an
exact currently pending job/generation. A worker result is sent through the
claim-fenced durable-result followup mode and produces `cleanup_actions[]`.
An acpx-only marker produces cleanup only after the post-acpx grace period, so
a legitimately running inner acpx process is never reaped by this watchdog.

## `reap_driven_orphan_placeholders.sh`

Consumes the protected physical-job IDs built by `run_executor_batch_tick.sh`
from current scheduler jobs plus unfinished launch coordinators. Under the
project campaign lock it removes only scheduler-driven `placeholder:true`
entries whose `run_id`, `child_session_key`, and `spawned_at` are null and whose
exact safe `job_id` is not protected. It never guesses from IID, execution ID, batch
labels, or malformed identity, and it returns unresolved IIDs explicitly.

## Standard Env

All wrappers accept:

```text
PROJECT
GROUP
GITLAB_TOKEN
REPO_PARENT_PATH   # optional; defaults to /data
```

Per-IID wrappers additionally receive `ISSUE_IID` and `EXECUTION_ID`. `env_paths.sh` derives every path from those values and the fixed `.req_executor` runtime directory.
