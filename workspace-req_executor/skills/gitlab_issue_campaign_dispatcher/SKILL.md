---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-07-11.1] Run GitLab issue campaigns for req_executor as a thin LLM orchestrator over fixed shell wrappers. Supports scheduled campaigns, child callbacks, durable dispatcher-driven batches, executor batch ticks, and the RUN_SINGLE_ISSUE compatibility shim. The executor owns GitLab discovery, a default three-slot strict round-robin scheduler, crash-safe claim fencing, project handoffs, and per-Issue callback outbox delivery. The LLM only performs serial runtime session enumeration/spawn calls and feeds their strict results back to wrappers; it never queries GitLab, expands batch IIDs, handles GitLab tokens from req_dispatcher, or edits scheduler state."
allowed-tools: Bash, Read, sessions_history, sessions_spawn, subagents
---

# GitLab Issue Campaign Dispatcher Skill

This SKILL is a **thin orchestration contract**. Every deterministic
step — trigger parsing, state-file writes, flock, reconcile, eligibility,
per-IID prep, label transitions, executor prompt rendering, Phase 6
callback handling — lives in the dispatcher wrappers under `scripts/`
(see [`references/dispatcher_wrappers.md`](references/dispatcher_wrappers.md)).
The LLM's only job is to call the right wrapper, read its JSON envelope,
and perform the two runtime-tool-only operations that no shell process
can: `sessions_spawn` and `subagents kill`.

All agent runtime files live INSIDE the cloned repo under the fixed
`${REPO_PATH}/.req_executor/` directory — campaign state, dispatcher logs,
locks, per-issue state/logs/summaries, and one shared per-issue linked
git worktree per IID at `${REPO_PATH}/.req_executor/.worktrees/issue-<iid>/`.
The worktree is reused across every attempt of an IID (created on
attempt 1 via `git worktree add -B`, then force-switched in place on
attempt N>1 after preserving the same-IID runtime subtree; `continue`
restores it for resume, while all non-continue entry labels reset from
the target branch and archive the preserved subtree outside the active
worktree).
See [`references/paths.md`](references/paths.md) for the complete layout.

## Two prompts you MUST NOT confuse (read this first)

Per IID, the wrapper produces **two completely different prompt strings**.
Mixing them is the most damaging bug in this workflow — a confused
orchestrator will ship the *inner* prompt as the *outer* spawn payload,
the subagent will then bypass `run_acpx_attempt.sh`, and the whole
`run_acpx_attempt.sh` → `stage_and_guard.sh` chain breaks.

| | Outer **executor prompt** (the spawn payload) | Inner **Claude Code prompt** (acpx's `-f` argument) |
| -- | -- | -- |
| Built from | rendering [`references/executor_prompt.md`](references/executor_prompt.md), written by `dispatch_prepare_tick.sh` to `${LOG_DIR}/spawn_payload.txt` | running `scripts/build_prompt.sh`, which writes `${LOG_DIR}/prompt.txt` |
| Audience | the OUTER subagent (the runtime-spawned model) | the INNER Claude Code session that `acpx claude exec -f ${LOG_DIR}/prompt.txt` starts |
| Tells it to | run Steps 0–9: `bash run_acpx_attempt.sh` → stage → push → verify → labels → MR → pr → summarize → emit compact JSON | implement the GitLab issue and write its deliverables (code / tests / specs / docs — whatever the issue asks for) |
| Shape | starts with sentinel `# REQ_EXECUTOR_EXECUTOR_PROMPT_V1`, contains `<config>` / `<issue>` / `<env_contract>` / `<instructions>` XML-style blocks | starts with "You are working on GitLab issue #<iid>. Implement the change ...", markdown headers |
| Sent how | `sessions_spawn(task=<contents of spawn_payload.txt>, label=<entry.child_label>, runtime="subagent", mode="run", cleanup="keep", context="isolated")` — scheduled entries use `#<iid>-att-<NNN>`; driven grants use the globally unique safe label described in Path D; both are anonymous, with no session name | NEVER sent over `sessions_spawn`; only read by `acpx` from disk via its `-f` flag inside `run_acpx_attempt.sh` |
| File on disk | persisted at `${LOG_DIR}/spawn_payload.txt` by the wrapper | persisted at `${LOG_DIR}/prompt.txt` by `build_prompt.sh`; it stays on the runner and is not committed into the MR diff |

**HARD RULE: `${LOG_DIR}/prompt.txt` is NEVER the spawn payload.** The
wrapper's pre-spawn sentinel grep on the rendered string guards against
this confusion; the LLM does not need to re-check, but MUST always feed
`sessions_spawn` the contents of `payload_path` from the
`dispatch_entries[]` returned by `dispatch_prepare_tick.sh` or the
`spawn_grants[]` returned by `run_executor_batch_tick.sh` — never any
other file.

## The orchestrator loop (replaces Phases 1–6)

There are **five trigger commands and five execution paths**, all
reduced to fixed wrapper calls and strict JSON branches.

> The legacy "Phase 1–6" numbering is **not** retired — the wrapper
> scripts (`dispatch_prepare_tick.sh` / `dispatch_record_spawn.sh` /
> `dispatch_followup.sh`) still perform those phases internally, and the
> other reference docs keep the Phase numbers as stable cross-document
> anchors. "Replaces Phases 1–6" means the orchestrator no longer runs
> them as hand-written prose steps, not that the phases ceased to exist.

### Path A — `RUN_SCHEDULED_ISSUE_CAMPAIGN`

```
1. cd "${SKILL_DIR}" && bash scripts/dispatch_prepare_tick.sh <<'TRIGGER_EOF'  → envelope
   <verbatim multi-line trigger_text — every key=value line, no surrounding quotes>
   TRIGGER_EOF
   # The `cd` and the `bash` MUST be in the SAME Bash tool call, joined by `&&`.
   # `cd` does NOT persist across exec calls (§Working Directory + SOUL.md
   # §Per-Exec Env Contract); issuing them as two separate tool calls leaves
   # the wrapper exec back in OpenClaw's default cwd and aborts with
   # `bash: scripts/dispatch_prepare_tick.sh: No such file or directory`.
   #
   # The trigger text MUST come in as a heredoc, not
   # `echo "<multi-line literal>" | bash ...`. See §Invocation pitfall in
   # references/dispatcher_wrappers.md — putting `|` on a new line after a
   # closing `"` aborts the tick with a bash syntax error before the wrapper
   # even starts.
2. for each action in envelope.cleanup_actions where action.action == "kill":
     try: subagents kill --target action.target
     except: pass    # best-effort; state is already persisted as blocked
3. switch envelope.status:
     "ready"                    → enter spawn loop (step 4)
     "waiting_for_callbacks"    → print chat_summary, EXIT
     "no_eligible_iids"         → print chat_summary, EXIT
     "completed"                → print chat_summary, EXIT
     "lock_held"                → print chat_summary, EXIT
     "tick_failed"              → print chat_summary, EXIT
4. for each entry in envelope.dispatch_entries (STRICTLY one at a time):
     payload   = Read(entry.payload_path)         # tool: Read
     attempts  = 0
     ack       = null
     while attempts < envelope.max_launch_retries and ack is null:
       attempts += 1
       try:
         ack = sessions_spawn(
                 task=payload,
                 label=entry.child_label,
                 runtime="subagent",
                 mode="run",
                 cleanup="keep",
                 context="isolated")
         # ack is valid iff both runId AND childSessionKey are non-empty.
         if ack.runId is empty or ack.childSessionKey is empty: ack = null
       except: ack = null
       if ack is null and attempts < envelope.max_launch_retries:
         sleep envelope.backoff_seconds   # IDENTICAL payload next try
     if ack is null:
       cd "${SKILL_DIR}" && \
         IID=<entry.iid> ATTEMPT_NUMBER=<entry.attempt_number> \
         STATUS=launch_failed LAUNCH_ATTEMPTS=<attempts> \
         LAUNCH_ERROR="<verbatim last error or raw response>" \
         (+ standard env: PROJECT, GROUP, GITLAB_TOKEN, REPO_PARENT_PATH) \
         bash scripts/dispatch_record_spawn.sh                    → record_envelope
       # record_envelope may carry cleanup.action == "kill" if a partial
       # session is detectable — almost always action == "skip" here.
     else:
       cd "${SKILL_DIR}" && \
         IID=<entry.iid> ATTEMPT_NUMBER=<entry.attempt_number> \
         STATUS=spawned RUN_ID=<ack.runId> \
         CHILD_SESSION_KEY=<ack.childSessionKey> \
         (+ standard env) \
         bash scripts/dispatch_record_spawn.sh                    → record_envelope
     # Both branches: `cd` MUST share the SAME Bash tool call as the
     # wrapper invocation — see §Working Directory.
     print record_envelope.chat_summary
5. print envelope.chat_summary, EXIT (still "waiting_for_callbacks" overall)
```

The 3-attempt + 2-second-backoff retry loop is the **only** retry logic
the LLM owns — `dispatch_record_spawn.sh STATUS=launch_failed` synthesizes
the Phase 6 blocked reply when exhaustion happens, so by the time the
script returns, state is durable and the next IID can be spawned.

### Path B — `RUN_CHILD_COMPLETION_CALLBACK`

```
1. cd "${SKILL_DIR}" && \
     IID=<callback.iid> ATTEMPT_NUMBER=<callback.attempt_number> \
     (+ standard env from callback payload) \
     bash scripts/dispatch_followup.sh <<'WORKER_JSON_EOF'        → envelope
   <verbatim worker_result_json — normally a single compact JSON line>
   WORKER_JSON_EOF
   # Same `cd`-chaining rule as Path A: the `cd` MUST share the SAME Bash
   # tool call as the wrapper invocation (see §Working Directory).
   #
   # Same heredoc rule as Path A: do NOT use `echo "<literal>" | bash ...`
   # with `|` on a separate line. The compact JSON is usually single-line,
   # but if a future runtime delivers multi-line payloads the echo form
   # breaks identically (bash sees a stray `|` after the closing quote).
2. if envelope.cleanup.action == "kill":
     try: subagents kill --target envelope.cleanup.target
     except: pass    # cleanup is best-effort; failures only update chat_summary
3. print envelope.chat_summary, EXIT
```

That's the entire callback path. No Phase 6 prose, no Bash chains, no
state writes from the LLM side.

### Path C — `RUN_DRIVEN_ISSUE_BATCH`

Pass the complete I1 trigger verbatim to the fixed intake wrapper:

```
1. cd "${SKILL_DIR}" && bash scripts/run_driven_issue_batch.sh <<'TRIGGER_EOF' → envelope
   <verbatim RUN_DRIVEN_ISSUE_BATCH trigger>
   TRIGGER_EOF
2. Process envelope.reconcile_actions and envelope.spawn_grants using Path D.
3. If the envelope has no non-empty batch_id, or Path D cannot resolve an
   action unambiguously, print envelope.chat_summary and EXIT without a public
   acceptance.
4. cd "${SKILL_DIR}" && BATCH_ID="<verbatim envelope.batch_id>" \
     bash scripts/emit_driven_batch_acceptance.sh → acceptance
5. Return exactly acceptance's sole compact JSON line as the final assistant
   reply, then EXIT. Do not print envelope.chat_summary, the rich envelope, a
   code fence, or surrounding prose after/beside it.
```

The wrapper owns GitLab pagination, OPEN filtering, immutable snapshot creation,
batch idempotency, strict round-robin reservation, live preflight, claim
allocation and binding, claim-0 skips, project handoff import, and outbox drain.
The trigger never contains a GitLab token, and the envelope never contains one.
Do not query GitLab, expand the snapshot IID list, call `RUN_SINGLE_ISSUE` once
per IID, or invoke scheduler/project helper scripts directly.

The public acceptance wrapper re-reads the named batch while holding the
scheduler lock, verifies its unique registration, canonical request/snapshot
digests, and batch-state invariants, and emits exactly `status`, `batch_id`,
`matched_count`, `snapshot_digest`, and `scheduler_status`. Never construct
those five fields in the LLM. The richer intake/tick envelope is runtime work
input only and is rejected by req_dispatcher as a public receipt.

### Path D — `RUN_EXECUTOR_BATCH_TICK`

```
1. cd "${SKILL_DIR}" && bash scripts/run_executor_batch_tick.sh → envelope
2. for each action in envelope.reconcile_actions (STRICT ARRAY ORDER):
     require action.action == "reconcile_emitted_spawn"
     call `subagents list` once and match the exact action.child_label
     if exactly one matching child has non-empty runId and childSessionKey:
       cd "${SKILL_DIR}" && bash scripts/resolve_executor_batch_reconcile.sh <<'JSON_EOF'
       {"job_id":"<action.job_id>","claim_generation":<action.claim_generation>,
        "resolution":"spawned","run_id":"<runId>",
        "child_session_key":"<childSessionKey>"}
       JSON_EOF
     else if no child matches:
       call the same wrapper with
       {"job_id":"<action.job_id>","claim_generation":<action.claim_generation>,
        "resolution":"not_found","evidence":"subagents_list_no_matching_label"}
     else:
       print chat_summary, EXIT  # ambiguous runtime evidence; never guess
3. for each grant in envelope.spawn_grants (STRICT ARRAY ORDER, never parallel):
     payload = Read(grant.payload_path)
     call sessions_spawn with the fixed parameters and retry contract below
     immediately pass the ack or final launch error as one strict JSON object to
       cd "${SKILL_DIR}" && bash scripts/record_executor_batch_spawn.sh
4. Print envelope.chat_summary, EXIT.
```

For a successful spawn, the result JSON contains exactly
`job_id`, `claim_generation`, `project`, `iid`, `attempt_number`,
`status:"spawned"`, `run_id`, and `child_session_key`. For exhausted launch
retries it contains the same identity plus `status:"launch_failed"`,
`launch_attempts`, and `launch_error`. Never pass a claim token: the fixed
recorder recovers it privately and records project state before scheduler state.
The project recorder commits a token-hash-bound exact-outcome receipt in the
same campaign-state write as `spawned`/`launch_failed`; the scheduler commits a
token-hash-bound `launch_failed` tombstone in the same transaction that removes
the active job. Exact tick replays therefore return idempotent success without
incrementing quota, refreshing `spawned_at`, repeating Phase 6, or touching a
new claim. Conflicting run/session/outcome/generation/token evidence fails
closed. Project receipt replay and coordinator acknowledgement both validate
the complete exact project result: integer remaining count, non-empty
control-free summary, and, for driven launch failure, only
`final_status:"blocked"` with one of the two exact Phase 6 cleanup shapes.
Malformed or merely partial recorder output leaves recovery at
`ack_received`; recorder exit status alone never advances the coordinator.

Every driven `child_label` has the fixed form
`reqx-iid<IID>-gen<generation>-<40 lowercase hex>`. The readable prefix keeps
IID and claim generation visible; the 160-bit SHA-256 prefix binds full
`project`, physical `job_id`, IID, attempt and generation. Labels use only
`[A-Za-z0-9._-]`, are at most 96 bytes, are stable across replay, differ across
projects sharing the same IID, and differ again when a later generation is
explicitly authorized. Match this exact value during runtime reconciliation;
never reconstruct it in the LLM.

An `action_emitted` lease that expires is never automatically re-spawned.
`not_found` requires the explicit runtime enumeration evidence above before a
later tick may allocate the next claim generation. If the child is found, the
wrapper restores that exact generation and the later tick must not spawn it
again. `should_spawn=false` and claim-0 skips are handled entirely inside the
tick wrapper and therefore never authorize a runtime call.

`RUN_EXECUTOR_BATCH_TICK` is recovery-first: it scans durable project intents,
imports terminal handoffs, drains the callback outbox, then resumes every
durable post-spawn coordinator at `ack_received`, `project_recorded`, or
`scheduler_recorded` before it reserves/refills slots. The original caller does
not resend a spawn acknowledgement after a crash; the tick rebuilds the strict
recorder input from the durable coordinator. This includes the two ambiguity
windows where a downstream project/scheduler commit succeeded but its following
coordinator stage write did not. Invoke only the fixed wrapper;
never edit scheduler JSON, manually bind a claim, or reconstruct
retry/round-robin logic in the LLM.

### Path E — `RUN_SINGLE_ISSUE` compatibility shim

```
1. cd "${SKILL_DIR}" && bash scripts/dispatch_single_issue.sh <<'TRIGGER_EOF' → envelope
   <verbatim RUN_SINGLE_ISSUE trigger>
   TRIGGER_EOF
2. Process envelope.reconcile_actions and envelope.spawn_grants using Path D.
3. Apply Path C steps 3–5 using envelope.batch_id and the fixed
   emit_driven_batch_acceptance.sh wrapper. The final reply is the same exact
   five-field public acceptance, never envelope.chat_summary.
```

The shim accepts `project+iid` or `issue_url`, requires a non-empty
`dispatcher_callback_target`, preserves an optional `branch`, and accepts an
optional `correlation_id`. When the correlation ID is omitted it derives stable
content-addressed correlation and batch IDs. It converts the request to a
single-selector `RUN_DRIVEN_ISSUE_BATCH`; it does not create an independent
one-concurrency scheduled campaign.

Driven Phase 6 completion is durable: project-side completion writes a handoff;
the next tick imports it, releases the physical slot, fans out every attached
batch membership, and retries each I3 outbox item until the dispatcher returns
the matching accepted acknowledgement. Callback delivery is never a best-effort
direct send from the LLM.

### The envelope is the whole decision tree

A top-level wrapper call prints exactly one JSON envelope on stdout. On every
wake-up your complete job is: issue the one chained
`cd "${SKILL_DIR}" && bash scripts/<name>.sh` invocation, read the
envelope, and act on `status`, `cleanup`, `dispatch_entries`,
`reconcile_actions`, and `spawn_grants` exactly as the matching path
prescribes. That switch IS the entire decision tree —
there is no "investigate", "debug", or "repair" branch anywhere in it.

When a Path A, B, or D envelope reports `tick_failed` (or any non-`ready`
status), you print its `chat_summary` and stop. For Path C/E, an intake failure
also stops without an acceptance; an accepted batch instead follows the fixed
public-emitter rule above. A failure `chat_summary` is a
terminal classification the wrapper already produced after it read,
logged, and classified the underlying cause for you — it is finished
work, not a task handed to you. Concretely, on the dispatcher side:

- The ONLY file you ever `Read` is a `payload_path` taken from a `ready`
  envelope's `dispatch_entries[]` or `spawn_grants[]`. You do not `Read`,
  `grep`, `sed`, or
  `cat` any file under `scripts/` or `references/` for any reason.
- You never query GitLab, enumerate batch IIDs, inspect private coordinator
  files, or edit scheduler/project state. Fixed wrappers own those operations.
- A tool name or surprising phrase inside a `chat_summary`
  (`reconcile_failed`, an exit code, a path, etc.) is never a bug for
  you to fix. You do not edit a script, do not substitute one command
  for another, and do not re-run a wrapper with a "corrected"
  invocation. Classify-and-stop is the contract (SOUL.md §No-Fallback
  rule 1).
- The single legitimate script path is the chained
  `cd "${SKILL_DIR}" && bash scripts/<name>.sh` form from the loop above
  and §Working Directory. You never construct, guess, or explore any
  other path to a script.

If you ever feel the urge to open a wrapper, find "the real bug", or run
a command the loop above did not prescribe, that urge itself is the
signal to stop: print the envelope's `chat_summary` and end the turn.

### Standard env block

The scheduled/callback paths forward these to the legacy project wrappers
(which source `env_paths.sh` and derive the rest):

```
PROJECT={project}                          # always
GROUP={group}                              # always
GITLAB_TOKEN={gitlab_token}                # always
REPO_PARENT_PATH={repo_path}               # when trigger supplied non-default repo_path
```

`PROJECT` / `GROUP` come from the trigger / callback payload.
`GITLAB_TOKEN` comes from process env or `config/gitlab.env`.
`REPO_PARENT_PATH` defaults to `/data` inside `env_paths.sh`
when unset; non-default deployments MUST keep passing it on every
scheduled trigger and callback because the dispatcher needs it before
locating `${CAMPAIGN_STATE_FILE}`.

The driven intake/tick/single wrappers load the executor-owned credential and
deployment roots themselves. `req_dispatcher` never supplies a token, and the
LLM never copies a token into a trigger, result JSON, or chat response.

## What the wrappers handle (don't second-guess them)

These topics used to be multi-page prose sections in this SKILL. They
now live inside the wrappers and are documented in their reference
files. **Do not reconstruct from memory** — trust the wrappers.

| Topic | Where it lives now |
| ----- | ------------------ |
| Trigger field schema + override rules + fixed-value preflight | `dispatch_prepare_tick.sh` step 1; reference: [`trigger_command.md`](references/trigger_command.md) |
| `campaign_state.json` schema + per-issue state + compact reply | reference: [`state_schema.md`](references/state_schema.md) |
| Pending eviction (`stuck_after_minutes` plus trigger-scope eviction) | `dispatch_prepare_tick.sh` pending-eviction block |
| Reconcile + disk-cache correction + Source-of-Truth Policy | `dispatch_prepare_tick.sh` steps 10–11; `dispatch_followup.sh` step 2 |
| Eligibility batch formation (backlog → blocked retry, quota cap) | `dispatch_prepare_tick.sh` step 16 |
| Per-IID prep (allocate_attempt, prepare_attempt, claude_settings copy, glab issue read, label transitions to `doing`, build_prompt, state-file init) | `dispatch_prepare_tick.sh` step 20 |
| Executor prompt rendering + sentinel check | `dispatch_prepare_tick.sh` step 20.8–20.9 |
| `pending_subagents` placeholder + post-launch writeback | `dispatch_prepare_tick.sh` step 19; `dispatch_record_spawn.sh` |
| Phase 6 validation + label sync + state writes + classification + drain | `dispatch_followup.sh` + `_dispatch_lib.sh::phase6_process` |
| Best-effort terminal cleanup decision (preserves all terminal child sessions for diagnosis; no `subagents kill` request is emitted) | `_dispatch_lib.sh::phase6_decide_cleanup`; LLM acts on `envelope.cleanup.action` |
| Driven batch intake, OPEN snapshot, and idempotency | `run_driven_issue_batch.sh` → `create_driven_batch.sh` |
| Recovery-first handoff/outbox/coordinator replay and strict round-robin refill | `run_executor_batch_tick.sh` |
| Preparing claim, bind, emitted-action fence, and claim-0 skip | `run_executor_batch_tick.sh` plus its fixed helpers |
| Runtime-evidence reconciliation | `resolve_executor_batch_reconcile.sh` |
| Project-first spawn/launch-failure record | `record_executor_batch_spawn.sh` |
| Exact five-field public I1/single-shim receipt | `emit_driven_batch_acceptance.sh` |

For the exhaustive contract of what each wrapper accepts and emits, see
[`references/dispatcher_wrappers.md`](references/dispatcher_wrappers.md).

## What the LLM still owns

| Concern | Why it stays here |
| ------- | ----------------- |
| `sessions_spawn(...)` per IID | OpenClaw runtime tool — not callable from a shell process |
| 3-attempt × 2-second-backoff retry around `sessions_spawn` | Each retry is itself a runtime-tool call. `dispatch_record_spawn.sh` documents and stores the outcome but cannot make the runtime call. |
| One `subagents list` for each `reconcile_actions[]` item | Only the runtime can prove whether an emitted spawn already created a child session. |
| `subagents kill --target <key>` | Runtime tool — same reason |
| Printing `chat_summary`, or the fixed Path C/E acceptance, to chat | Only the LLM produces user-visible chat; it never hand-builds the acceptance |
| Reading `payload_path` files via the `Read` tool | The wrapper writes them; the LLM passes the contents to `sessions_spawn` |

Nothing else is the LLM's responsibility on the dispatcher side.

## No-Fallback (LLM-side rules)

The wrappers enforce the §No-Fallback rules for everything they own
(script failures, glab-only access, abort-on-missing-input, no
improvised state writes). The LLM still has two rules to follow that
the wrappers cannot enforce:

1. **`sessions_spawn` retry contract.** Up to 3 total attempts per IID
   with a fixed 2-second backoff between attempts. Every attempt
   re-issues the IDENTICAL payload (same contents from `payload_path`,
   same `label`, same `runtime="subagent"`, same `mode="run"`, same
   `cleanup="keep"`, same `context="isolated"`). Do NOT mutate the payload between attempts;
   do NOT add a session-name parameter; do NOT switch to a different
   spawn mode; do NOT call any other LLM tool inline. A launch failure
   is anything where the ack does not carry both `runId` AND
   `childSessionKey` — that includes `status:"error"`, gateway
   timeouts, network/transport errors, runtime errors, and the spawn
   tool call itself raising. After 3 attempts fail, immediately call
   `dispatch_record_spawn.sh STATUS=launch_failed` on Path A, or pass the strict
   `launch_failed` JSON to `record_executor_batch_spawn.sh` on Path D. **No fourth
   attempt, no payload mutation, no "try once more without the label
   parameter".**
2. **Strictly serial `sessions_spawn` calls.** Never batch multiple
   spawns in a single parallel tool-call block. The local loopback
   gateway serializes spawn handling per channel with a finite forwarding
   ceiling; parallel batching
   causes the 2nd+ spawn to return `gateway timeout after 10000ms` with
   an orphaned `childSessionKey`. Issue spawn-1, wait for its ack,
   record it, THEN issue spawn-2.

If the runtime returns a schema error rejecting the `label=` parameter
(e.g. `unknown field`, `unexpected parameter`), still run the standard
3-attempt loop (the error is deterministic so all 3 will fail the
same way) before recording `launch_failed`. Do NOT strip the label
between retries — that violates the IDENTICAL-payload rule and
silently hides a deployment issue.

## Source-of-Truth Policy (still HARD)

**GitLab is the ground truth for per-issue workflow state. Disk state
is only the dispatcher's progress cache.** Both wrappers enforce this:

- `dispatch_prepare_tick.sh` runs `reconcile.sh` mandatorily and writes
  an evidence file at `${DISPATCHER_LOG_DIR}/reconcile-<ts>.json` before
  any "early return / skip" decision. No evidence file = tick fails.
  As of `2026-06-11.1`, reconcile + the disk-cache correction run on
  **every reachable scheduled tick, including ticks where a batch is in
  flight** (the `waiting_for_callbacks` gate was moved to AFTER reconcile),
  so a reviewer's live label edit during an active batch is synced on the
  very next tick instead of waiting for the batch to drain. In-flight and
  same-tick-evicted IIDs are skipped by the correction so Phase 6 stays
  their sole owner. Two operator-visible consequences: (a) a `reconcile.sh`
  failure during an active batch now surfaces as `tick_failed` in chat
  instead of a silent `waiting_for_callbacks` (pending bookkeeping is
  already persisted, so the next tick recovers — nothing is lost); (b)
  reconcile now hits GitLab over the full `[issue_min_iid, issue_max_iid]`
  range on every wake-up, so per-tick `glab api` volume scales with the
  range size even while idle-waiting. Widen the schedule interval if the
  call volume is a concern.
- `dispatch_followup.sh` runs a narrow `reconcile.sh MIN_IID=<iid> MAX_IID=<iid>`
  before writing terminal state, so reviewer relabels between spawn and
  callback get picked up.

Disk cache is corrected to match GitLab — never the other way around.
A hand-applied bare `blocked` / `blocked-cc` / `blocked-dispatcher` / `failed` / `failed-cc` / `failed-dispatcher` label (one the dispatcher did
not itself write into `blocked_iids` / `failed_iids`) is honored as a
**terminal park**: the IID is excluded from `backlog` and `fresh`
selection and is NOT auto-retried; a reviewer re-runs it by applying
`retry` (fresh reset, wins over the lingering label) or `continue`
(resume). Dispatcher-applied `blocked-cc` (CC/subagent-side failures,
tracked in `blocked_iids` with `block_side=cc`) and `blocked-dispatcher`
(dispatcher-synthesized failures: prep, launch_failed, scope-evict,
stuck-non-timeout, reply-downgrade, label-sync failures; `block_side=dispatcher`)
keep their existing cooldown-then-retry behavior; both feed the same
`blocked_iids` classification and the same retry_count/blocked_retry_limit
promotion to `failed-cc` / `failed-dispatcher`. Bare `blocked` / `failed`
without suffix are recognized as legacy compat and treated as `blocked-cc`
/ `failed-cc` respectively when consumed by reconcile (already in the
live issue's labels). The LLM does NOT need to second-guess any of this;
the wrappers handle it.

## Locking

Every wrapper acquires the dispatcher flock at `${LOCK_FILE}` non-blocking
on entry and releases it on exit. If the lock is held, the wrapper
emits an envelope with `chat_summary` containing `lock_held` and exits 0;
the LLM should print that summary and stop. The runtime is expected to
deliver the trigger again later.

The LLM MUST NOT acquire its own flock. The LLM MUST NOT pass `--no-lock`
or rewrite the wrapper invocation to bypass the lock.

## Companion files

This SKILL stays short by design. Detailed reference data lives in
sibling folders:

- [`references/dispatcher_wrappers.md`](references/dispatcher_wrappers.md) — the **canonical** input/output contract for the three wrappers. Read this whenever you need to know what a wrapper expects or emits.
- [`references/trigger_command.md`](references/trigger_command.md) — trigger spec, required fields, optional fields, override semantics. The wrapper validates per this file.
- [`references/state_schema.md`](references/state_schema.md) — `campaign_state.json`, per-issue state, per-attempt state, compact subagent reply schemas; Phase 6 Write Mapping; wrapper-side write ownership.
- [`references/executor_prompt.md`](references/executor_prompt.md) — the fixed-format template the wrapper renders and writes to `${LOG_DIR}/spawn_payload.txt`. The OUTER spawn payload.
- [`references/paths.md`](references/paths.md) — full path layout (dispatcher + per-issue subtrees + per-issue worktrees).
- [`references/glab_commands.md`](references/glab_commands.md) — the workspace-wide allowed `glab` command list (G1–G13). Wrappers and subagent scripts both consume this.
- [`references/label_lifecycle.md`](references/label_lifecycle.md) — workflow label transitions.
- [`references/continue_mode.md`](references/continue_mode.md) — reviewer contract for the `continue` label and the prompt template injected in continue mode.

When in doubt about a path / schema / command / behavior, READ the
matching reference file. Do NOT reconstruct from memory — these
contracts are deliberately exhaustive and the agent's correctness
depends on following them literally.

## Subagent contract (unchanged)

The subagent receives the rendered fixed-format executor prompt as the
entire `sessions_spawn` payload and runs Steps 0–9 from the prompt's
`<instructions>` block. **It does NOT load this SKILL, NOT read
SOUL.md / AGENTS.md, NOT call `sessions_spawn` / `sessions_history`,
NOT write any state file.** Its compact JSON reply is the single
artifact the orchestrator reads from it (via
`RUN_CHILD_COMPLETION_CALLBACK` → `dispatch_followup.sh`).

The subagent invokes scripts at `<workspace>/skills/gitlab_issue_campaign_dispatcher/scripts/<name>.sh`
by absolute path (the wrapper renders `{SCRIPTS_DIR}` into the prompt).
See [`references/executor_prompt.md`](references/executor_prompt.md) for
the full subagent prompt and [`references/state_schema.md`](references/state_schema.md)
§Compact Subagent Reply for the reply schema the wrapper validates.

## Working Directory

OpenClaw starts a fresh shell for every Bash tool call (per SOUL.md
§Per-Exec Env Contract), so `cd` does NOT persist across exec calls.
`cd "${SKILL_DIR}"` issued as a standalone Bash tool call is a no-op
for the next exec — the orchestrator MUST chain
`cd "${SKILL_DIR}" && … && bash scripts/<name>.sh` in the SAME Bash
tool call. The skill directory is the directory containing this SKILL.md
(e.g. `<workspace>/skills/gitlab_issue_campaign_dispatcher/`); pin its
absolute path and reuse the chained form on every dispatcher script
invocation. Failing to chain produces
`bash: scripts/dispatch_prepare_tick.sh: No such file or directory`
because the wrapper relative path resolves against OpenClaw's default cwd.

The subagent uses absolute paths via the rendered `{SCRIPTS_DIR}`
placeholder so this rule only applies to the orchestrator session.

## Chat Output Policy

Every rich orchestration envelope carries a `chat_summary` field — a one-line
human-readable string. Paths A, B, and D print exactly that line (no surrounding
prose, no rewording, no JSON dump) and exit. Successful Path C/E intake is the
only exception: after runtime actions, print exactly the sole compact JSON line
from `emit_driven_batch_acceptance.sh`, with nothing after or around it. Never
print the rich envelope itself and never hand-build the public receipt.
**Never paste full logs, full diffs, long issue bodies, or frozen IID arrays
into chat.** Operators reading ordinary tick chat see the summary and dig into
`${RESULT_ROOT}/_dispatcher/log/wrapper.log` for structured trace when needed.
