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
- `dependency_scan_cursor_iid`
- `shared_branch_groups`
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
`dependency_scan_cursor_iid` is either `null` or a positive IID lower bound. A
scheduled tick uses it only to rotate the bounded dependency-preflight view;
it resets after a complete scan or a full runnable batch, so a large waiting
prefix cannot permanently starve later candidates.
`shared_branch_groups` is an object keyed by the exact frozen branch
`issue/<head>+<tail>`. Each value contains the same `work_branch`, positive and
distinct `head_iid` / `tail_iid`, ordered `members:[head,tail]`, a non-empty
`scope_id`, and an optional non-empty `merge_target_branch`. A fan-in group also
contains `dependency_mode:"fan_in"` and ordered unique
`dependency_iids:[head,...]` with two through eight entries; the tail may not
appear in that list. `members` intentionally remains `[head,tail]` because the
first dependency is the compatibility anchor for the existing execution/MR
contract. Uniqueness is enforced across every group's effective participants
`(dependency_iids // [head]) + [tail]`, so auxiliary fan-in sources cannot be
reused through their absence from `members`. The key must encode the anchor and
tail exactly. Malformed keys, duplicate participation, invalid targets,
declaration changes, or a second group binding fail closed before allocation.

Graph discovery from a frozen planning scope is advisory for topology already
visible. An incomplete scope never delays or changes an ordinary A. When C is
processed, its direct declaration may bind a completed A from the same scope or
an earlier campaign. API/parse uncertainty uses bounded non-terminal preflight
reasons. Deterministic cycles, fan-out, longer chains, binding conflicts, and
invalid declarations are persisted through the ordinary per-Issue blocked
state. A driven project response also carries an
exact scheduler `skipped_entries[]` handoff so the physical job terminates.

### Driven project launch receipts

`driven_launch_receipts` is an optional object keyed by physical driven
`job_id`. `dispatch_record_spawn.sh` writes the current receipt in the same
atomic `campaign_state.json` persistence as the corresponding `spawned` or
`launch_failed` mutation. Each receipt contains exactly:

- `version:1`, `job_id`, positive `claim_generation`;
- `claim_token_sha256` (never the private token itself);
- `iid`, `execution_id`, and `outcome` (`spawned|launch_failed`);
- exact `ack`: `run_id+child_session_key` or
  `launch_attempts+launch_error`;
- `recorded_at` and the exact public project recorder `result`.

The stored `result` is also an exact, typed authorization boundary. For
`spawned` it has only `status:"spawned"`, matching positive `iid` and
`execution_id`, non-negative integer `remaining_pending_count`, and a
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

Scheduler-driven pending entries freeze `auto_merge:boolean`,
`merge_target_branch:string|null`, `work_branch`, ordered `branch_members`,
`shared_branch_role`, optional `expected_work_branch_sha`, and optional
`expected_commit_parent_sha` from the exact active job.
`expected_work_branch_sha` is the old remote tip used only by the push lease;
`expected_commit_parent_sha` is the required sole parent of the new shared
commit. Ordinary automatic requests require a non-empty merge target;
shared groups require `auto_merge:false`. Legacy ordinary records missing the
new branch fields normalize to `issue/<iid>`, `[iid]`, and a null shared role;
a two-member record never receives that compatibility default. Phase 6 reads
only this trusted pending configuration, not callback-authored labels.

Dependency and branch identity are committed in two phases. Before worktree
preparation, immutable `executions/execution-<execution_id>.json` binds `work_branch`, `branch_members`,
`shared_branch_role`, `expected_work_branch_sha`,
`expected_commit_parent_sha`, and the all-null or
all-present `dependency_iid` / `dependency_branch` / `dependency_base_sha`
tuple to the exact IID, execution identity, title, mode, merge policy, and target. A shared
head requires a null dependency tuple. A shared tail requires the complete
tuple with `dependency_iid=head`, `dependency_branch=work_branch`; in fresh mode
`expected_work_branch_sha` must equal `dependency_base_sha`. Every shared
execution requires a full `expected_commit_parent_sha`; for C it equals
`dependency_base_sha`, while for A it is the frozen target baseline. At that point
`state.json` retains the last successfully pushed identity and stores the new
values only under `proposed_*` plus `preparing_execution_id`.

`run_executor_attempt.sh` does not use this file as an authorization or
consistency gate. Its IID, execution ID, branch, dependency, and merge inputs
come from the rendered wrapper invocation. Before sourcing the path bootstrap
or creating runtime output, it validates `ISSUE_IID` and `WORK_BRANCH` and
derives branch identity directly from them: `issue/<iid>` means ordered
`branch_members:[iid]` with a null shared role, while a distinct two-member
`issue/<head>+<tail>` containing the current IID means ordered
`branch_members:[head,tail]` with role `head` or `tail` according to the IID's
position. Every other ordinary or shared shape fails without side effects.
Caller-provided branch-member/role environment leftovers and execution-file
fields cannot override this derivation. When readable, the execution file may
supply only the optional string `issue_title`; missing, malformed, forged,
mismatched, or nonstandard file metadata does not reject a run and no other
field is read as runtime context.

Only after `run_executor_attempt.sh` has pushed the exact remote branch,
matched it to the returned commit, and verified the dependency history does it
promote the identity in `state.json`. The promoted fields include
`work_branch`, `branch_members`, `shared_branch_role`, `work_branch_sha`, the
dependency tuple, `dependency_history_verified:true`,
`dependency_pinned_execution_id`, and `dependency_history_updated_at`.
For fresh C, the commit must have A's frozen SHA as its only parent and the push
uses that same SHA as an explicit lease. For continued C, the lease is the old
C tip while the new commit's sole parent remains A, so C1 is replaced by C2
instead of producing `A -> C1 -> C2`. A published shared head cannot enter the
ordinary continue path. Continue mode otherwise requires this complete identity
and an exact resume SHA. A two-member state can never normalize to a
dependency-free tail. Missing, legacy, partial, moved, or mismatched metadata
fails closed and is never reconstructed from current Issue text.

After the compact terminal result is durable, `archive_execution_logs.sh`
builds a tree from the current `HEAD` plus only the current `ISSUE_LOG_REL` and
pushes it as a direct log-only child on the same `WORK_BRANCH`. A private Git
index prevents staged or unstaged partial business work from entering that
child. Ordinary log-only executions may create `issue/<iid>` from the current
base even when `stage_and_guard.sh` returned `NO_CHANGES`. For non-auto and
shared open-MR flows, the wrapper advances `work_branch_sha`, the private MR
marker/checkpoint, and the compact callback `commit_sha` to the new source tip.
A verified merged automatic MR keeps its immutable merged SHA in the callback
while only `work_branch_sha` advances. An unresolved automatic MR and a shared
failure that has not installed its exact MR checkpoint keep post-push evidence
local because moving those source refs would destroy their recovery fence. No
`req-executor-logs/*` ref is created.

Before C starts, `migrate_shared_dependency_head.sh` moves an ordinary completed
A from `issue/A` to `issue/A+C` without changing A's commit. A's state first
adds `branch_migration` with `version:1`, `status:"pending"`, ordered
`head_iid`/`tail_iid`, `from_branch`, `to_branch`, exact `commit_sha`, frozen
`target_branch`, old MR IID/URL, random 64-hex `intent_id`, source execution ID, and
`started_at`. The script creates the new ref with an empty lease, closes the
old MR, creates one replacement MR, and deletes the old ref with an exact A-SHA
lease. Every external mutation is rediscovered and identity-checked on replay.

Completion changes `branch_migration.status` to `"completed"`, adds the new MR
IID/URL and `completed_at`, changes A's `work_branch` to `issue/A+C`, sets
`branch_members:[A,C]` and `shared_branch_role:"head"`, and installs a
`mr_finalization.status:"verified_open"` binding for the same A commit and
replacement MR. A terminal identity conflict changes the checkpoint to
`"failed"` with `failure_reason`/`failed_at`; transient GitLab or transport
uncertainty leaves it pending and returns a retryable migration deferral. The
old ordinary MR remains closed in GitLab history, but steady state has exactly
one open shared MR.

For a fan-in, the anchor Issue additionally stores
`dependency_aggregation`. Version 1 freezes `anchor_iid`, `tail_iid`, ordered
`dependency_iids`, `work_branch`, `target_branch`, `aggregate_sha`,
`started_at`, and ordered `sources`. Every source entry contains its `iid`,
ordinary `branch`, immutable `commit_sha`, `source_execution_id`, and old MR
IID/URL. `status:"pending"` is written only after all source states, refs, MRs,
and a conflict-free aggregate commit have been verified, but before the anchor
migration changes remote state. Completion adds the combined MR IID/URL and
`completed_at`, advances the anchor's canonical `commit_sha`,
`work_branch_sha`, and `mr_finalization.commit_sha` to `aggregate_sha`, and sets
`status:"completed"`. A deterministic identity/merge failure uses
`status:"failed"` with `failure_reason`/`failed_at`; transient uncertainty
leaves it pending.

Each non-anchor source retains its original `commit_sha` and gains a
`joined_dependency_group` record with the same anchor, tail, dependency list,
work branch, aggregate SHA, and `joined_at`. Its ordinary MR URL is retained as
`superseded_merge_request_url`; `merge_request_url` points to the combined MR,
and `mr_finalization.status:"superseded"` prevents the retired ordinary
identity from authorizing another migration. These auxiliary states are audit
evidence, not execution members of the pair-shaped shared branch.

After C's shared push is verified, `state.json.mr_finalization` first has exactly
`status:"pending"`, `source_execution_id`, `work_branch`, ordered
`branch_members`, `shared_branch_role`, `commit_sha`, a 64-lowercase-hex
`intent_id`, and `target_branch`. The A migration creates the high-entropy
intent and embeds it in the replacement MR description; C inherits the same
value from A's verified binding. The intent is ownership evidence, not a secret.
This checkpoint authorizes only MR finalization for the already-pushed commit;
it never authorizes acpx, stage, commit, or push. A missing/invalid current-
attempt marker keeps the same pending claim with
`mr_finalization_retry:true` and
`mr_finalization_retry_execution_id:<execution_id>`. The heartbeat repeats all private
state, local HEAD, and remote-tip checks before entering the MR-only path.
An exact marker whose prior observation is `unknown` is identity evidence only:
it can select the MR IID/URL for Phase 6, but only a fresh GitLab GET can
authorize `done`. A closed, moved, retargeted, or foreign live identity drains
the current claim without authorizing success; an unavailable GET retains it.
History reads paginate until complete. Multiple, truncated, or repeating
history pages for the frozen source branch produce
`shared_mr_history_conflict` evidence, which Phase 6 immediately classifies as
terminal `failed-dispatcher`; it can never authorize success or a replacement
MR.

Phase 6 promotes a successful shared result to
`mr_finalization.status:"verified_open"` and adds the exact MR `iid`,
`web_url`, the unchanged `intent_id`, role-specific `mr_action`, and
`verified_at`. Before reuse, C
requires A's durable `done` state to carry this exact binding for the A commit,
members, branch, head role, frozen target, and latest pinned execution. The only
open MR returned by GitLab must have the same URL/IID. Phase 6 performs both an
exact-IID GET and a source-branch open-list read, while C's release gate repeats
the same uniqueness and identity checks. They require `state=opened`, current
token author, the intent marker, both exact `Closes` lines, source/target branch,
and source SHA. Closed, moved, retargeted, foreign, duplicate, or ambiguous MR history
fails closed and never authorizes a replacement MR. `mr_result.json` records
`mr_action:"created"` for A and `mr_action:"reused"` for C. Shared branches
never enter the automatic-merge mutation path. Ordinary automatic-merge jobs
retain the exact GET/PUT/GET and independent Phase 6 verification contract;
neither callback fields nor a marker alone authorize `finish`.

C additionally requires A to be absent from current `pending_subagents`. This
prevents the per-Issue completion write from releasing C during the Phase-6
crash window. A in the current campaign is normally also present in
`completed_iids`; for an earlier-campaign A, the migration helper instead
requires its private done state, exact ordinary ref SHA, and unique live MR.

If the exact merge is verified but the atomic `finish` update fails,
Phase 6 keeps the claim in `pending_subagents[iid]` and adds
`finish_label_retry:true` plus
`finish_label_retry_execution_id:<current execution_id>`. Reconciliation may
then override even a non-empty killed/failure callback with current-execution
marker recovery, but only when that retry attempt exactly equals the pending
claim's `execution_id`. A missing, invalid, or stale retry-attempt fence is
ignored and cannot hijack a later attempt. The retry re-verifies the exact MR
against GitLab before trying only the `finish` transition; it does not rerun
Issue work or drain the scheduler slot early.

The same retention rule applies when a verified shared MR cannot receive the
atomic `pr` label: Phase 6 records `mr_label_retry:true` plus the exact attempt,
then retries only the trusted marker and label transition. It does not rerun
Issue work or change the shared branch.

## Executor-Wide Scheduler State

Path:

```text
${EXECUTOR_SCHEDULER_ROOT}/scheduler_state.json
```

In addition to `version`, `round_robin_cursor`, `batch_order`, and
`active_jobs`, version 1 may contain positive-integer `max_concurrency`,
positive-integer `max_issues_per_repository`, and `acpx_timeout_seconds` from 60
through 18000. `max_concurrency` is the maximum number of distinct active GitLab
repositories, while `max_issues_per_repository` caps active physical Issue jobs
within each repository and defaults to 1. Preparing/running jobs above a newly
lowered per-repository limit drain naturally; excess `reserved` jobs return to
pending on the next scheduler pass. The runtime values are written only by
`set_executor_slots.sh`, `set_executor_repo_slots.sh`, and
`set_executor_acpx_timeout.sh` under
`scheduler.lock` and override deployment initialization defaults for later
batch sessions. A `pending_transaction.scheduler_state` carries the same
values so transaction recovery cannot roll back a concurrent runtime update.

Each active job stores the processing `branch`, `auto_merge`, and
`merge_target_branch` as part of its physical intent. Deduplication attaches a
second batch membership only when all three values, `entry_mode`, and
`force_rerun_pr` match; a conflicting merge policy remains pending behind the
current physical job.

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
${REPO_PATH}/.req_executor/issues/issue-<iid>/executions/execution-<execution_id>.json
${REPO_PATH}/.req_executor/issues/issue-<iid>/summary.md
```

New `execution_id` values are randomly generated opaque positive integers below
`2^48`. They never represent execution order or a cumulative count. An upgrade
never derives an execution identity from a legacy counter. If legacy pending or
handoff state is still active, project admission returns
`legacy_execution_identity_drain_required`; operators must drain it with the old
release before activating the new release. `load_state` is a pure reader because
completion ingestion also uses it without `campaign.lock`.

Only after pending work and handoff intents are both empty does a dispatcher
holding the exclusive project lock perform the one-time filesystem sweep. It
removes retired count fields from campaign and per-Issue state and replaces a
legacy `attempt_state.json` with a count-free deprecation tombstone. After the
sweep succeeds, `campaign_state.json.execution-identity-v2-migrated` prevents
repeated full per-Issue scans; it contains only
`{version:2,completed:true,requires_quiescent_lock:true}`. The earlier
version-1 marker is not trusted because it could have been written by an
unlocked reader; it is replaced only after the same locked, quiescent sweep.

Old-schema hot files under the executor scheduler's `launch_actions/` are not
rewritten. The batch tick returns a bounded `legacy_execution_schema` /
`drain_required` operation, blocks new spawns, and leaves the action byte-stable
so the old release can finish it. Invalid files that match neither schema remain
hard failures.

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
- `execution_id`
- `status`: `done`, `no_changes`, `blocked`, `failed`, or `timeout`
- `mode_actual`, `work_branch`, `local_branch`
- `commit_sha`, `merge_request_url`, `mr_action`
- `wiki_url` (legacy compatibility; new replies keep it empty)
- `labels_added`, `labels_removed`, `summary_posted`
- `block_reason`, `log_dir`

`summary_posted` is retained for callback-schema compatibility and is always
`false`; `summarize_attempt.sh` writes only the local `summary.md` file.

Immediately after the inner acpx process exits, `run_acpx_attempt.sh` also
atomically writes:

```text
${LOG_DIR}/acpx_terminal.json
```

Its exact version-1 object contains `version`, `iid`, `execution_id`,
`exit_code`, and `completed_at_epoch`. This marker is not a terminal Issue
result; it only proves that acpx itself is no longer running and starts the
bounded post-acpx watchdog.

`dispatch_followup.sh` validates the IID and execution identity against `pending_subagents` before mutating state.

If a runtime-authenticated successful child terminal contains zero strict
compact worker objects, `ingest_subagent_completion.sh` uses the already-bound
durable launch IID and execution identity to invoke Phase 6 with a fixed
non-JSON sentinel. Phase 6 immediately synthesizes `blocked-dispatcher`, unless
the attempt has already outlived its pinned ACPX budget and therefore qualifies
as `timeout`. More than one strict worker object remains ambiguous and is
rejected without state or label mutation.
