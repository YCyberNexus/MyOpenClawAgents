# Trigger Commands

`req_executor` accepts eight current trigger forms and one compatibility
command:

- `RUN_SCHEDULED_ISSUE_CAMPAIGN`
- `RUN_CHILD_COMPLETION_CALLBACK`
- `RUN_DRIVEN_ISSUE_BATCH`
- `RUN_EXECUTOR_BATCH_TICK`
- `/slot <positive-integer>`
- `/repo-slot <positive-integer>`
- `/timeout-executor <60..18000 seconds|Nm|Nh>`
- `/mission-stop <GitLab repository URL|group/project>`
- `RUN_SINGLE_ISSUE`

The executor is task-agnostic. It reads the GitLab issue, renders the issue
content into `${LOG_DIR}/prompt.txt`, and asks the outer subagent to make one
long `scripts/run_executor_attempt.sh` call. That wrapper owns deterministic
finalization and invokes `scripts/run_acpx_attempt.sh`, which remains the sole
owner of the fixed
`acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` call.

Runtime state uses the fixed in-repo directory `${REPO_PATH}/.req_executor/`. There is no trigger or config field for runtime basenames, project data directories, or account-pool paths.

## Runtime Slot Control

Exact form:

```text
/slot <positive-integer>
```

Call `scripts/set_executor_slots.sh` with the complete message on stdin and
return its sole compact JSON object. The wrapper persists `max_concurrency` as
the parallel-repository ceiling in the executor-wide `scheduler_state.json`
under `scheduler.lock`; every batch session sharing the same scheduler root
uses that value. A decrease below the current active repository count is
accepted without cancelling work:
`draining=true`, no new repository jobs are reserved, and the active set drains
naturally to the new ceiling. The tracked `EXECUTOR_MAX_CONCURRENCY=10` remains
the initialization default when no runtime value has been set.

## Runtime Per-Repository Issue Control

Exact form:

```text
/repo-slot <positive-integer>
```

Call `scripts/set_executor_repo_slots.sh` with the complete message on stdin and
return its sole compact JSON object. The wrapper persists
`max_issues_per_repository` in executor-wide scheduler state under
`scheduler.lock`; every repository and batch session sharing the scheduler root
uses it. The tracked `EXECUTOR_MAX_ISSUES_PER_REPOSITORY=1` keeps repository
execution serial by default. A decrease does not cancel preparing or running
jobs. The command reports draining when any repository's active physical job
count, including reservations, exceeds the new ceiling. The next reservation
pass returns excess tokenless reservations to pending and waits for excess
started work to finish before granting replacements.

## Runtime ACPX Timeout Control

Exact form:

```text
/timeout-executor <60..18000 seconds|Nm|Nh>
```

Call `scripts/set_executor_acpx_timeout.sh` with the complete message on stdin
and return its sole compact JSON object. Bare integers and `Ns` are seconds;
`Nm` is minutes and `Nh` is hours. The wrapper persists
`acpx_timeout_seconds` in executor-wide scheduler state under the scheduler
lock. The tracked initialization default is `3600` seconds. Updates apply only
to future executions; pending and running executions keep their spawn-time value.
The result reports future dispatcher-side budgets derived as agent turn
`acpx+3600`, exec tool `acpx+3900`, legacy queue reclaim `acpx+4200`, and stuck
eviction `ceil((acpx+4200)/60)+20`. The command never changes OpenClaw global
`runTimeoutSeconds`.

## Repository Mission Stop

Exact form:

```text
/mission-stop <GitLab repository URL|group/project>
```

Call `scripts/stop_repository_mission.sh` with the complete message. Execute
only the exact runtime cleanup targets in its private envelope, using one
bounded child listing for exact `runtime_labels` matches, then return only
`public_result`. The wrapper archives and removes the repository's active
scheduler jobs, non-terminal batch chain, hot launch actions, undelivered I3
callbacks, and project pending state so a later submission starts cleanly.

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
- `stuck_after_minutes`: integer >= 5. Defaults to `ceil((acpx_timeout_seconds + 2400) / 60) + 30`.
- `acpx_timeout_seconds`: integer from 60 through 18000. Defaults to `3600`.
- `kill_subagent_on_terminal`: legacy compatibility boolean. Defaults to
  `false`; ordinary terminal callbacks preserve child sessions for diagnosis.
  Claim-fenced durable-result and expired post-acpx recovery may still reclaim
  the stale child that failed to emit a final model reply.
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

Legacy `run_timeout_seconds` is explicitly rejected. The common OpenClaw
2026.4.9/2026.6.11 spawn contract deliberately omits version-specific per-call
timeout fields; deployments may configure the optional global
`agents.defaults.subagents.runTimeoutSeconds`. When positive, it should be at
least `acpx_timeout_seconds + 2400`.

## Native completion and legacy callback

New child completions arrive as protected OpenClaw `task_completion` events and
are passed intact to `scripts/ingest_subagent_completion.sh`; the runtime does
not synthesize `RUN_CHILD_COMPLETION_CALLBACK`. The ingester authenticates the
run id, child session key, label, IID, execution ID, and runtime provenance before
calling `dispatch_followup.sh`. `RUN_CHILD_COMPLETION_CALLBACK` remains only for
pre-upgrade pending records explicitly marked `completion_auth:"legacy"`.
Campaign scalars are loaded from persisted state; completion inputs do not
override them.

## Dispatcher-Driven Batch

`RUN_DRIVEN_ISSUE_BATCH` is the primary `req_dispatcher` intake. Its fixed
multi-line form is:

```text
RUN_DRIVEN_ISSUE_BATCH
batch_id=<stable dispatcher batch ID>
correlation_id=<dispatcher correlation ID>
project=<full group/project path>
executor_agent=<deployment-pinned executor agent>
selector_type=single|iid_list|range|open_unfinished|open_label
iid=<positive integer; single only>
iids=<comma-separated sorted unique positive integers; iid_list only, at least two>
iid_min=<positive integer; range only>
iid_max=<positive integer; range only>
label=<exact label; open_label only>
force_rerun_pr=true|false
auto_merge=true|false
dispatcher_callback_target=<non-empty req_dispatcher target>
callback_nonce=<64 lowercase hexadecimal characters>
branch=<optional processing base branch>
merge_target_branch=<optional MR target branch; required when auto_merge=true>
```

Exactly one selector shape is allowed. `iid_list` selects the exact canonical
IID set supplied in `iids`. Every selector is restricted to OPEN issues.
`open_unfinished` excludes `pr`, `finish`, `timeout`, `blocked`, `blocked-*`,
`failed`, and `failed-*` from the frozen snapshot. `open_label` matches the
requested label exactly and does not apply those snapshot exclusions. Live
preflight still skips an issue carrying `pr` or `finish` unless `force_rerun_pr=true`; a
closed issue is always skipped. The executor uses the GitLab GraphQL cursor
connection, rejects duplicate IIDs and unsafe/non-advancing or over-budget
cursors, and freezes the matching IID snapshot only after two consecutive full
scans normalize to the same result. Persistent movement fails closed, and later
matching issues are not added.

`auto_merge=true` is accepted only with an exact `merge_target_branch`. The
scheduler persists and compares both fields as part of physical-job intent, so
conflicting merge policies cannot attach to the same running Issue. Legacy
requests and scheduler records missing the fields normalize to `false/null`.
This intake validation does not override dependency planning: if an Issue is
later frozen into `issue/A+C`, either member carrying `auto_merge=true` is
rejected as `shared_branch_auto_merge_unsupported` before execution.

`batch_id` is idempotent: the same canonical request replays the existing
batch, while the same ID with different bytes fails closed. The external I1
uses the selector and callback-routing fields shown above. The executor loads
`GITLAB_TOKEN` from its private process environment or deployment config using
the standard precedence. It passes the credential only to fixed outer scripts;
internal scheduled triggers, spawn bootstraps, manifests, and executor payloads
never serialize it.

The fixed `run_driven_issue_batch.sh` response includes `status`, `batch_id`,
`matched_count`, `snapshot_digest`, `scheduler_status`, `spawn_grants`,
`reconcile_actions`, `cleanup_actions`, `operation_results`, `max_launch_retries`,
`backoff_seconds`, and `chat_summary`. It never returns the frozen IID array or
private claim tokens. `matched_count=0` is a completed batch and creates no
spawn grant.

That rich response is runtime work input, not the req_dispatcher receipt. After
all `cleanup_actions`, `reconcile_actions`, and `spawn_grants` are processed, call:

```bash
cd "${SKILL_DIR}" && BATCH_ID="<verbatim envelope.batch_id>" \
  bash scripts/emit_driven_batch_acceptance.sh
```

Use its sole compact stdout JSON as the final agent reply, with no code fence,
`chat_summary`, rich envelope, or surrounding prose. The wrapper locks and
validates durable scheduler state and emits exactly:

```json
{"status":"success","batch_id":"<batch>","matched_count":3,"snapshot_digest":"<digest>","scheduler_status":"queued"}
```

Never assemble this receipt in the LLM. req_dispatcher intentionally rejects
the rich envelope and a human `chat_summary` because neither is the exact
five-field public acceptance contract.

## Executor Batch Tick

`RUN_EXECUTOR_BATCH_TICK` has no user fields. Call
`scripts/run_executor_batch_tick.sh` once for each trigger. The wrapper always
performs these phases in order:

1. Reconcile durable batch terminal counters before any new reservation.
2. Recover exact hash-latched durable worker results and emit post-acpx child
   cleanup under the current job/generation/token-digest fence. An unlatched
   result is provisional; the narrow crash repair accepts only a single-parent
   execution-log child and CASes its exact `work_branch_sha`.
3. Reconcile expired positive-generation running claims against their exact
   project claim fence and ACPX deadline; due claims synthesize `timeout` via
   the ordinary durable handoff path.
4. Scan active/registered projects for durable Phase 6 handoff intents.
5. Import handoffs and retry the callback outbox.
6. Resume durable post-spawn coordinators in `ack_received`,
   `project_recorded`, or `scheduler_recorded` without requiring the original
   caller to resend an acknowledgement.
7. Recover leases and reserve free executor-wide slots.
8. Strictly round-robin runnable batches, top up project campaigns, and import
   claim-0 skips.
9. Persist preparing claims and bind them before emitting safe spawn grants.

Post-spawn recovery covers the exact commit/coordinator ambiguity windows. The
project campaign state stores a job/generation/token-hash/exact-outcome receipt
in the same persistence as `spawned` or `launch_failed`; exact replay does not
increase quota, refresh `spawned_at`, or require a deleted pending entry. For
`ACTION=launch_failed`, scheduler active-job deletion and a strict token-hash
tombstone share the same `pending_transaction`, so tick replay after deletion
returns idempotent success. A current active claim always takes precedence over
an older tombstone, including when the same job and numeric generation are
reused with a new token. All conflicting outcome, runtime session, generation,
token, or action evidence fails closed.

The initial executor-wide repository concurrency is 10 unless deployment config
overrides `EXECUTOR_MAX_CONCURRENCY`; the initial per-repository Issue limit is
1 unless `EXECUTOR_MAX_ISSUES_PER_REPOSITORY` overrides it. `/slot` and
`/repo-slot` then persist the corresponding runtime ceilings in shared scheduler
state. `EXECUTOR_ACPX_TIMEOUT_SECONDS` similarly initializes the
one-hour attempt cap, while `/timeout-executor` persists later values for future
attempts. Multiple projects/batches share those limits. Grant
order is persisted scheduler order and must be consumed one item at a time;
project grouping must not reorder it. Explicit process values for
`EXECUTOR_SCHEDULER_ROOT` process values take precedence over config and are
preserved consistently across intake, tick, top-up, and spawn recording, so one
operation cannot split a batch across scheduler roots. A process/config
`EXECUTOR_MAX_CONCURRENCY` and `EXECUTOR_MAX_ISSUES_PER_REPOSITORY` initialize
scheduler capacity only while no corresponding runtime value has been persisted.
Completed batches leave the hot `batch_order`; completed launch actions and
delivered callbacks move to cold per-ID archives. Direct replay still resolves
those records without making every periodic tick scan the full history.

The response has exactly `status`, `spawn_grants`, `reconcile_actions`,
`cleanup_actions`, `operation_results`, `max_launch_retries`, `backoff_seconds`, and
`chat_summary`. Each `spawn_grants[]` item contains only `job_id`,
`claim_generation`, `project`, `iid`, `execution_id`, `child_label`, and an
absolute `payload_path`. Read that file and call `sessions_spawn` serially. Feed
the runtime result to `record_executor_batch_spawn.sh`; never call claim/bind or
scheduler record helpers directly.

Each `cleanup_actions[]` item has `action:"kill"` and an exact native child
session `target`. Durable-result cleanup is emitted only after Phase 6 has
committed the claim-fenced worker result. Marker-only cleanup is emitted only
after exact IID/attempt matching and the post-acpx grace period. Process these
actions before reconciliation or spawning; a cleanup tick contains no spawn
grant.

Driven `child_label` is generated only after the scheduler claim exists and has
the fixed form `reqx-iid<IID>-gen<generation>-<40 lowercase hex>`. Its SHA-256
prefix binds the full project, physical job ID, IID, attempt and generation, so
`g1/repo#42` and `g2/repo#42` are distinguishable even at the same attempt and
generation. A retry generation also receives a different label. The value is
stable across replay, uses only `[A-Za-z0-9._-]`, is at most 96 bytes, and must
be passed to `sessions_spawn` and matched during reconciliation verbatim.

An `action_emitted` item uses a dedicated 180-second spawn-ack lease, measured
from durable action emission rather than the earlier project-preparation
claim. When it expires, the tick runs the canonical reservation transition for
that exact job only and immediately returns it in `reconcile_actions[]` before
project top-up. Enumerate
runtime subagents using its exact
`child_label`, then call `resolve_executor_batch_reconcile.sh` with one of the
strict objects below:

```json
{"job_id":"<job>","claim_generation":1,"resolution":"spawned","run_id":"<run>","child_session_key":"<session>"}
```

```json
{"job_id":"<job>","claim_generation":1,"resolution":"not_found","evidence":"subagents_list_no_matching_label"}
```

Only explicit `not_found` evidence lets a later tick allocate the next claim
generation. A found child restores the original generation project-first and
must not be spawned again. Neither resolution accepts or returns a claim token.

Driven terminal results use durable I3 outbox events with stable `event_id`,
`batch_id`, `snapshot_index`, `project`, `iid`, `status`, `mr_url`, and
`reason`. The executor marks an event delivered only after req_dispatcher
returns an accepted/duplicate acknowledgement containing the same `event_id`.
The callback `openclaw` subprocess inherits the executor process environment,
including the effective `GITLAB_TOKEN` selected from process/config.
The transport is `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY`, one strict `callback_envelope`
containing `batch_acceptance`, `callback_nonce`, `executor_agent`, and the public
eight-field `worker_result_json`, and one fixed third-line `ack_instruction` that
forbids temporary files. `batch_acceptance` is rebuilt by the fixed public
acceptance emitter immediately before transport and uses the same batch ID as
the I3, so dispatcher can repair a receipt/mirror after a lost synchronous I1
reply; the nonce never appears inside either public object. The
dispatcher still accepts the former `RUN_DRIVEN_BATCH_RESULT` marker for
in-flight compatibility, but new outbox delivery never emits it. The complete
ack stdout must be exactly one strict accepted/duplicate JSON object, or exactly
one `json`/plain Markdown fence whose body is that sole strict object. Text
outside a fence, prose, double fences, prefixes, suffixes, or multiple objects
are retryable failures.

## Single-Issue Compatibility Shim

`RUN_SINGLE_ISSUE` accepts:

- `project` plus `iid`, or `issue_url` as their alternative source;
- required non-empty `dispatcher_callback_target`;
- required pinned `executor_agent` and 64-hex `callback_nonce`;
- optional `correlation_id`, `branch`, and `group`.

Explicit project/IID values must match `issue_url` when both are present.
`dispatch_single_issue.sh` generates stable content-addressed correlation and
batch IDs when needed, converts the request into a single-selector
`RUN_DRIVEN_ISSUE_BATCH`, and delegates to the same executor-wide scheduler.
`dispatch_single_issue.sh` itself does not synthesize
`RUN_SCHEDULED_ISSUE_CAMPAIGN`, create a private `max_concurrent_subagents=1`
campaign, or write `dispatch_origin.json`. The downstream driven top-up keeps
the resolved token private to fixed outer scripts; neither its internal
scheduled trigger nor any spawned task text carries it.
After processing its runtime actions, use the same
`emit_driven_batch_acceptance.sh` call and exact five-field final reply described
for dispatcher-driven batches; do not return its rich envelope or
`chat_summary` as the public result.
