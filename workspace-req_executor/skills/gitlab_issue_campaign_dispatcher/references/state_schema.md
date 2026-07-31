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
`shared_branch_groups` is a legacy compatibility object keyed by the exact
frozen branch `issue/<head>+<tail>`. Existing values retain their version-1
head/tail, fan-in, migration, and MR-recovery meaning so an in-flight deployment
can drain safely. DAG v2 planning never creates, expands, or rebinds this
object. In particular, DAG v2 does not enforce participant uniqueness across
consumers: one immutable predecessor artifact may be reused by any number of
independent consumer plans.

Graph discovery from a frozen planning scope supports fan-out, multiple
dependency levels, and one through eight declared inputs per consumer.
Incomplete discovery or API uncertainty uses bounded non-terminal preflight
reasons. A deterministic cycle, invalid declaration, unsafe or moved
predecessor artifact, identity mismatch, aggregation conflict, or changed
frozen plan is persisted through the ordinary per-Issue blocked state. A
driven project response also carries an exact scheduler `skipped_entries[]`
handoff so the physical job terminates.

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
`expected_commit_parent_sha` is the required sole parent of the new business
commit. Ordinary automatic requests require a non-empty merge target. DAG v2
and legacy shared-pair requests require `auto_merge:false`. Phase 6 reads only
this trusted pending configuration, not callback-authored labels.

A DAG v2 pending entry additionally freezes:

- `dependency_contract_version:2`;
- the complete lowercase 64-hex `dependency_plan_sha256`;
- `dependency_plan`, with exactly `version:2`, positive `consumer_iid`,
  `target_branch`, ordered `declared_inputs`, ordered `effective_inputs`,
  `aggregate_base_sha`, `plan_sha256`, and `work_branch`;
- `work_branch:"issue/<iid>-dag-<first 16 hex of dependency_plan_sha256>"`;
- `branch_members:[iid]`, `shared_branch_role:null`;
- `dependency_base_sha` and `expected_commit_parent_sha`, both equal to
  `dependency_plan.aggregate_base_sha`.

Every `declared_inputs` entry is one of two immutable predecessor snapshots:

- an ordinary GitLab-authoritative snapshot with exact `iid`,
  `identity_source:"gitlab_pr_label_branch"`, `work_branch:"issue/<iid>"`,
  equal `commit_sha` / `work_branch_sha` frozen from the fetched remote branch,
  and `verified:true`; this shape deliberately has no local `execution_id` or
  MR object because live `pr` plus the exact ordinary branch is the contract;
- an executor-state snapshot with exact `iid`, `execution_id`, `work_branch`,
  business `commit_sha`, exact remote `work_branch_sha`, `verified:true`, and
  `mr` identity (`iid`, `url`, `state`, `source_branch`, `target_branch`,
  `sha`). This richer shape is used for content-addressed DAG predecessors that
  do not expose an ordinary `issue/<iid>` ref.

For the richer shape, an opened MR SHA equals `work_branch_sha`; a merged MR may
retain the business SHA or the log-child tip. Any unequal business/tip pair must
be one direct, single-parent child whose complete diff is inside that
execution's log directory.
`effective_inputs` is the transitive-reduction frontier, preserves
declared order, and contains the same snapshot shape. `plan_sha256` inside the
object equals the top-level `dependency_plan_sha256`; the full hash is
authoritative even though the branch suffix contains only its first 16 hex.
The legacy scalar `dependency_iid` / `dependency_branch` /
`dependency_base_sha` tuple remains a compatibility projection and must not be
used to reconstruct a multi-input plan.

Dependency and branch identity are committed in two phases. Before worktree
preparation, immutable `executions/execution-<execution_id>.json` binds the
exact IID, execution identity, title, mode, merge policy, target, branch
identity, expected SHAs, and dependency contract. For DAG v2 this includes the
version, full plan hash, and frozen plan described above. At that point
`state.json` writes the exact `dependency_plan` as the authoritative immutable
plan before preparation, while retaining the last successfully pushed branch
identity. It also stores the new values under the corresponding `proposed_*`
fields, including
`proposed_dependency_contract_version`,
`proposed_dependency_plan_sha256`, and `proposed_dependency_plan`, plus
`preparing_execution_id`.

`run_executor_attempt.sh` does not use mutable Issue text to reconstruct this
contract. Its IID, execution ID, branch, dependency, and merge inputs come from
the rendered wrapper invocation. It validates the complete DAG v2 tuple before
creating runtime output: version 2, full plan hash, content-addressed branch,
single-Issue membership, null shared role, equal base/parent SHAs, and
`auto_merge:false` must all agree. An absent contract version selects only the
legacy grammar: ordinary `issue/<iid>` or an existing two-member
`issue/<head>+<tail>` shared pair. Cross-version, partial, or mismatched shapes
fail without side effects.

Only after `run_executor_attempt.sh` has pushed the exact remote branch,
matched it to the returned commit, and verified the dependency history does it
promote the identity in `state.json`. A DAG v2 promotion includes
`dependency_contract_version:2`, `dependency_plan_sha256`, the exact
`dependency_plan`, `work_branch`, `branch_members:[iid]`,
`shared_branch_role:null`, `work_branch_sha`, the compatibility dependency
tuple, `dependency_history_verified:true`,
`dependency_pinned_execution_id`, and `dependency_history_updated_at`.
The business commit's sole parent must equal the frozen aggregate base. Fresh
mode starts from that base. Continue mode leases the old consumer tip while
replacing the old business commit from the same frozen base, so repeated
attempts do not lengthen the dependency history. Missing, partial, moved, or
mismatched metadata fails closed and is never reconstructed from current Issue
text. Promotion verifies the exact trusted proposed plan against the already
authoritative `dependency_plan`, preserves that plan, and deletes all three DAG
proposal fields atomically.

After the compact terminal result is written, `archive_execution_logs.sh`
builds a tree from the current `HEAD` plus only the current `ISSUE_LOG_REL` and
pushes it as a direct log-only child on the same `WORK_BRANCH`. A private Git
index prevents staged or unstaged partial business work from entering that
child. Ordinary log-only executions may create `issue/<iid>` from the current
base even when `stage_and_guard.sh` returned `NO_CHANGES`. For every
single-Issue business execution, including DAG v2, `commit_sha`, the compact
callback, and the private MR marker remain at the reviewed business commit
`B`; only `work_branch_sha` advances to the exact terminal-log child `L`.
Dependency aggregation binds both identities but merges only `B`. Existing
legacy shared-pair flows retain their old checkpoint/callback promotion to
`L`. An unresolved automatic MR and a shared failure that has not installed
its exact MR checkpoint keep post-push evidence local because moving those
source refs would destroy their recovery fence. No `req-executor-logs/*` ref
is created.

`worker_result.json` is provisional recovery evidence while that archive/state
tail is running. The wrapper atomically publishes private mode-0600
`attempt_finalized.json` only after all terminal persistence succeeds. The
marker has exactly `version`, `iid`, `execution_id`, `work_branch`,
`commit_sha`, `worker_result_sha256`, and `completed_at_epoch`; only a marker
whose SHA-256 and identities match authorizes the heartbeat to consume the
result. A missing or invalid marker never authorizes MR recovery or child
cleanup. If a crash occurs after pushing `L` but before updating state, the
claim-fenced recovery path may repair only `work_branch_sha` after proving
`L` is the single direct log-only child of `B`.

### DAG v2 predecessor plan

The dispatcher resolves every DAG v2 plan without mutating a predecessor's
private state, branch, ref, or MR. GitLab live workflow labels decide whether
the predecessor is complete. For an ordinary predecessor, stable `pr` plus the
exact fetched `issue/<iid>` ref is sufficient regardless of local batch/state
history, and the current ref SHA is frozen directly. Content-addressed DAG
predecessors without that ordinary ref still require their durable terminal
state, exact remote ref SHA, and unique verified MR identity. The DAG planning
path walks persisted predecessor plans to reject cycles.
It then applies transitive reduction: an input already reachable through
another declared input is omitted from `effective_inputs`, but remains in
`declared_inputs` for audit and plan hashing.

A single effective input uses its exact commit as `aggregate_base_sha`.
Multiple incomparable inputs are combined in declared order into a
deterministic aggregate Git object. No ref or MR is created for that object.
An ancestry or identity check failure, missing or moved source, deterministic
merge conflict, or aggregate verification failure blocks the consumer without
changing any predecessor. The same verified snapshots reproduce the same plan
hash, aggregate base, work branch, and failure classification on replay.

The consumer owns its branch and MR independently. Phase 6 verifies that MR's
exact IID/URL, source/target branch, source SHA, author, and open state before
recording `pr`. DAG v2 never enters the automatic-merge mutation path.

### Legacy shared-pair compatibility

The remaining version-1 shared-pair schema is retained only to finish or
recover a previously persisted `issue/<head>+<tail>` job. New DAG v2 planning
must not create `shared_branch_groups`, `branch_migration`,
`dependency_aggregation`, `joined_dependency_group`, or shared
`mr_finalization` records. Legacy replay continues to verify every stored SHA,
branch, MR identity, intent, and execution fence before an external mutation;
it must never silently convert a head/tail record into a DAG v2 plan.

An existing `shared_branch_groups` value keeps its exact
`work_branch`, distinct `head_iid` / `tail_iid`, ordered
`members:[head,tail]`, `scope_id`, and optional `merge_target_branch`. A legacy
fan-in also keeps `dependency_mode:"fan_in"` and ordered unique
`dependency_iids:[head,...]`. Its old key, membership, declaration, and target
validation remains in force within the legacy object; that uniqueness rule
does not constrain any DAG v2 predecessor or consumer.

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
when OpenClaw does not schedule the final model turn, but only after the exact
private `attempt_finalized.json` marker described above is present. The object
has exactly:

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
