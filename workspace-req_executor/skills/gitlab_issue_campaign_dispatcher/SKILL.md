---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-07-01.6] Run a GitLab issue campaign as a thin LLM orchestrator over dispatcher-side shell wrappers, reachable by THREE trigger commands: the recurring scheduled tick RUN_SCHEDULED_ISSUE_CAMPAIGN (Phases 1–5), the per-subagent terminal RUN_CHILD_COMPLETION_CALLBACK (Phase 6), and the req_dispatcher-driven single-issue entry RUN_SINGLE_ISSUE (I1; dispatch_single_issue.sh reads project/iid/correlation_id/dispatcher_callback_target/optional group, takes every other campaign field — token/branch/quota/timeouts/basenames — from config/campaign_defaults.env pin plus ignored config/campaign_defaults.local.env overrides when present, writes {correlation_id, dispatcher_callback_target, project (full <group>/<project>), iid} to the issue's dispatch_origin.json, then synthesizes an equivalent single-IID RUN_SCHEDULED_ISSUE_CAMPAIGN with quota=1/concurrency=1; on Phase 6 terminal done/failed/timeout the driven path best-effort回投 req_dispatcher via notify_dispatcher.sh with the I2 envelope {correlation_id,iid,project,status,mr_url,wiki_url,reason}, records the envelope locally, calls `openclaw agent` to send RUN_EXECUTOR_RESULT_CALLBACK with worker_result_json to the dispatcher target, and SKIPS the cron-path req_result note). The three wrappers (dispatch_prepare_tick.sh, dispatch_record_spawn.sh, dispatch_followup.sh) own every deterministic step — trigger parsing, state persistence under flock, reconcile, eligibility, per-IID prep, label transitions, executor-prompt rendering, Phase 6 callback handling — and emit single-line JSON envelopes the LLM reads. The LLM only performs the runtime-tool-only operations: anonymous `sessions_spawn` (no name parameter, label=#<iid>-att-<NNN>, timeoutSeconds=30, runTimeoutSeconds=<envelope.run_timeout_seconds>, cleanup=keep, IDENTICAL payload retried up to 3 times with 2-second backoff per §No-Fallback) and best-effort `subagents kill --target <child_session_key>` when followup output or scheduled cleanup_actions request it. Subagents receive the rendered fixed-format executor prompt from a per-IID payload file (the wrapper writes it to ${LOG_DIR}/spawn_payload.txt) and run only the technical workflow described in references/executor_prompt.md. The subagent does NOT load this SKILL and does NOT write state files. Supports quota carryover, backlog-first scheduling, blocked-cc/blocked-dispatcher skip-and-retry (with best-effort partial-work force-push after acpx failures for blocked-cc), terminal timeout parking (acpx wall-clock cap → label=timeout, partial work force-pushed, no MR, no auto-retry; reviewer strips timeout, adds retry, or applies continue to re-enqueue; timeout-shaped dead-subagent terminations — empty/unparseable/status-less worker_result_json or stuck-pending eviction arriving after the run outlived acpx_timeout_seconds−60s since spawned_at — are synthesized as timeout too, never as retryable blocked), v2 split-side label model (blocked-cc=CC/subagent-side failures, blocked-dispatcher=dispatcher-synthesized failures including prep/launch_failed/scope-evict/stuck-non-timeout/reply-downgrade/label-sync-fail; failed-cc / failed-dispatcher mirror same split; timeout is unsplit; completion = label pr only, done is transient before pr lands; model:{tier} is an orthogonal persistent monotone dimension driven by trigger field model_tiers), optional per-batch UI-account allocation from the test-team-owned account pool file (relative path under ${REPO_PATH}, opt in via trigger field ui_accounts_relpath with carry-forward persistence — no default; when unconfigured the entire pool flow is skipped and the rendered Claude Code prompt omits its UI accounts section; the relpath is resolved under the project checkout root so the pool may live under any repo subdirectory, not only the data dir) with max_accounts_per_issue capping (default 14) held until callback drains, optional Phase 6 结果回报 (trigger result_note_enabled, default off, carry-forward: after a terminal done/failed/timeout drains, post_result_note.sh reads the issue's git_issuer-written req_origin marker note and — only if present — posts a structured req_result note for an external 114-side relay to deliver to the original requester; pure glab G1b+G9, best-effort/non-fatal, blocked excluded, no-op when no req_origin), persistent disk state, stuck-pending detection, trigger-scope eviction for pending IIDs outside issue_iids∩[issue_min_iid,issue_max_iid], optional IID whitelist (issue_iids) and live-label inclusion filter (require_labels with or/and combinator) layered on top of the [issue_min_iid,issue_max_iid] range, and compact orchestrator chat output. A workspace-root compatibility wrapper exists at `scripts/dispatch_single_issue.sh` for agents that mistakenly invoke `scripts/` relative to the workspace root; canonical orchestration should still use `cd "${SKILL_DIR}" && bash scripts/<name>.sh`."
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

All agent runtime files live INSIDE the cloned repo at
`${REPO_PATH}/${RESULT_BASENAME}/...` — campaign state, dispatcher logs,
locks, per-issue state/logs/summaries, and one shared per-issue linked
git worktree per IID at `${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>/`.
The worktree is reused across every attempt of an IID (created on
attempt 1 via `git worktree add -B`, then force-switched in place on
attempt N>1 after preserving the same-IID runtime subtree; `continue`
restores it for resume, while all non-continue entry labels reset from
the clean baseline and archive the preserved subtree outside the active
worktree).
See [`references/paths.md`](references/paths.md) for the complete layout.
(`${RESULT_BASENAME}` / `${DATA_BASENAME}` default to `ifp-result` / `ifp-data`;
per-project `result_basename` / `data_basename` trigger fields override
them automatically.)

## Two prompts you MUST NOT confuse (read this first)

Per IID, the wrapper produces **two completely different prompt strings**.
Mixing them is the most damaging bug in this workflow — a confused
orchestrator will ship the *inner* prompt as the *outer* spawn payload,
the subagent will then execute the inner prompt directly (running hulat
agents itself, bypassing `acpx` entirely), and the whole
`run_acpx_attempt.sh` → `stage_and_guard.sh` chain breaks.

| | Outer **executor prompt** (the spawn payload) | Inner **Claude Code prompt** (acpx's `-f` argument) |
| -- | -- | -- |
| Built from | rendering [`references/executor_prompt.md`](references/executor_prompt.md), written by `dispatch_prepare_tick.sh` to `${LOG_DIR}/spawn_payload.txt` | running `scripts/build_prompt.sh`, which writes `${LOG_DIR}/prompt.txt` |
| Audience | the OUTER subagent (the runtime-spawned model) | the INNER Claude Code session that `acpx claude exec -f ${LOG_DIR}/prompt.txt` starts |
| Tells it to | run Steps 0–10: `bash run_acpx_attempt.sh` → stage → push → verify → wiki → labels → MR → pr → summarize → emit compact JSON | implement the GitLab issue and write its deliverables (code / tests / specs / docs — whatever the issue asks for) |
| Shape | starts with sentinel `# REQ_EXECUTOR_EXECUTOR_PROMPT_V1`, contains `<config>` / `<issue>` / `<env_contract>` / `<instructions>` XML-style blocks | starts with "You are working on GitLab issue #<iid>. Implement the change ...", markdown headers |
| Sent how | `sessions_spawn(payload=<contents of spawn_payload.txt>, label="#<iid>-att-<NNN>", timeoutSeconds=30, runTimeoutSeconds=<run_timeout_seconds>, cleanup="keep")` — anonymous, no session name | NEVER sent over `sessions_spawn`; only read by `acpx` from disk via its `-f` flag inside `run_acpx_attempt.sh` |
| File on disk | persisted at `${LOG_DIR}/spawn_payload.txt` by the wrapper | persisted at `${LOG_DIR}/prompt.txt` by `build_prompt.sh`, force-added into the MR diff by `stage_and_guard.sh` |

**HARD RULE: `${LOG_DIR}/prompt.txt` is NEVER the spawn payload.** The
wrapper's pre-spawn sentinel grep on the rendered string guards against
this confusion; the LLM does not need to re-check, but MUST always feed
`sessions_spawn` the contents of `payload_path` from the
`dispatch_entries[]` returned by `dispatch_prepare_tick.sh` — never any
other file.

## The orchestrator loop (replaces Phases 1–6)

There are **two trigger commands and two execution paths**, both
reduced to a small fixed shape.

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
                 payload=payload,
                 label=entry.child_label,
                 timeoutSeconds=30,
                 runTimeoutSeconds=envelope.run_timeout_seconds,
                 cleanup="keep")
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
         (+ standard env: PROJECT, GROUP, GITLAB_TOKEN, REPO_PARENT_PATH,
          RESULT_BASENAME, DATA_BASENAME) \
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

### Path C — `RUN_SINGLE_ISSUE` (req_dispatcher-driven single-issue entry, I1)

This is the **driven** entry point: `req_dispatcher` orchestrates one issue
end-to-end and wants this executor to process exactly that one IID, then report
the terminal result back so `req_dispatcher` can push it to the original
requester. It is NOT the cron path — the scheduled `RUN_SCHEDULED_ISSUE_CAMPAIGN`
+ cron continues to serve batch/backfill and non-driven sources unchanged
(§3.6 of the active-orchestration design).

**I1 trigger inputs** (multi-line key=value, same text format as the scheduled
trigger). Only these five are sent; **every other campaign field is read from
the deployment pin, never from the trigger** (token / branch / quota /
concurrency / timeouts / basenames / repo layout):

| Field | Required | Meaning |
| ----- | -------- | ------- |
| `project` | yes | GitLab project slug to process (透传 from the git_issuer callback by req_dispatcher). |
| `iid` | yes | The single issue IID to process (positive integer). |
| `correlation_id` | yes | req_dispatcher's关联 token. Echoed back verbatim in the I2 result envelope so req_dispatcher can match its pending entry. |
| `dispatcher_callback_target` | yes (I2) | The callback target req_dispatcher reports to. Supports `agent:req_dispatcher:main` or a bare agent id; carried opaquely into `dispatch_origin.json`. |
| `group` | no | Falls back to the `GROUP` pin in `config/campaign_defaults.env` / ignored `config/campaign_defaults.local.env` / `gitlab.env` when omitted. |

```
1. cd "${SKILL_DIR}" && bash scripts/dispatch_single_issue.sh <<'TRIGGER_EOF'  → envelope
   RUN_SINGLE_ISSUE
   project=<project>
   iid=<iid>
   correlation_id=<correlation_id>
   dispatcher_callback_target=<dispatcher_callback_target>
   group=<group>            # optional; omit to use the pin
   TRIGGER_EOF
   # Same `cd`-chaining + heredoc rules as Path A.
   #
   # dispatch_single_issue.sh:
   #   • validates project / iid (positive integer) / correlation_id (exit 2 on
   #     malformed CONFIG-shape input — surface it and stop per §No-Fallback);
   #   • sources config/gitlab.env + config/campaign_defaults.env, then optional
   #     ignored config/campaign_defaults.local.env; requires
   #     GITLAB_TOKEN from the sourced deployment pin or environment (never sent
   #     by req_dispatcher) and a GROUP from trigger/env/pin;
   #   • writes {correlation_id, dispatcher_callback_target, project, iid} to
   #     ${ISSUE_ROOT}/dispatch_origin.json (= ${ISSUES_ROOT}/issue-<iid>/dispatch_origin.json)
   #     so Phase 6 can find req_dispatcher to report back to;
   #   • synthesizes an equivalent single-IID RUN_SCHEDULED_ISSUE_CAMPAIGN
   #     (issue_iids=[iid], issue_min_iid=issue_max_iid=iid, hourly_issue_quota=1,
   #     max_concurrent_subagents=1, fixed-value preflight fields) and pipes it
   #     into dispatch_prepare_tick.sh, forwarding its envelope unchanged on stdout.
2. From here the envelope is a normal Path A `dispatch_prepare_tick.sh` envelope:
   enter the SAME spawn loop (step 4 of Path A), spawn the one IID, record it.
   The driven setup is transparent to the per-IID subagent and to Phase 6 — the
   ONLY driven-specific artifact is the issue's dispatch_origin.json, consumed at
   §Phase 6 dispatcher result callback below.
```

The driven path reuses the entire existing campaign machine — subagent Steps
0–10, per-issue worktree, anonymous spawn, the callback path — completely
unchanged. The only two new pieces are this entry script (which just pins
config + records the origin + delegates) and the Phase 6 callback below.

### Phase 6 dispatcher result callback (I2 — driven path only)

`dispatch_followup.sh` (Path B) decides, at Phase 6 terminal time, between two
**mutually exclusive, best-effort** result-report paths based on whether the
issue carries a driven origin:

- **driven** — `${ISSUE_ROOT}/dispatch_origin.json` exists AND carries a
  non-empty `correlation_id` + `dispatcher_callback_target`. The wrapper runs
  `scripts/notify_dispatcher.sh` to报回 req_dispatcher and **SKIPS**
  `post_result_note.sh` entirely (no `req_result` note — the user-facing回投 is
  req_dispatcher's job on this path; a truncated origin missing the target falls
  back to cron semantics).
- **cron** — no `dispatch_origin.json`. The existing `result_note_enabled`-gated
  `post_result_note.sh` path is unchanged (§trigger `result_note_enabled`).

`notify_dispatcher.sh` only fires for terminal `done` / `failed` / `timeout`
(never `blocked` — retryable, would re-post each attempt). It emits the **I2
result envelope** (one compact JSON line):

```json
{"correlation_id":"<echo of I1>","iid":<int>,"project":"<group/project>","status":"done|failed|timeout","mr_url":<string|null>,"wiki_url":<string|null>,"reason":<string|null>}
```

`status` is the Phase 6 `final_status`. Isolation matches `post_result_note.sh`:
the wrapper calls it with `set +e`, stdout → `/dev/null`, and a non-zero exit is
logged to `wrapper.log` but NEVER aborts Phase 6.

`notify_dispatcher.sh` records the I2 JSON to
`${WORK_ROOT}/log/dispatcher_callbacks.jsonl`, then calls `openclaw agent` with
`RUN_EXECUTOR_RESULT_CALLBACK` and `worker_result_json=<I2>` for the configured
target. Send failures remain best-effort (`exit 0`) after the envelope is
recorded; only malformed input or callback timeout shape exits non-zero. When
`dispatcher_callback_target` is empty it is a no-op (`exit 0`). See
[`references/trigger_command.md`](references/trigger_command.md) §RUN_SINGLE_ISSUE
and §Result callback for the full I1/I2 contract.

### The envelope is the whole decision tree

A wrapper call ALWAYS exits 0 and ALWAYS prints exactly one JSON envelope
on stdout. On every wake-up your complete job is: issue the one chained
`cd "${SKILL_DIR}" && bash scripts/<name>.sh` invocation, read the
envelope, and act on `status` / `cleanup` / `dispatch_entries` exactly as
the loop above prescribes. That switch IS the entire decision tree —
there is no "investigate", "debug", or "repair" branch anywhere in it.

When an envelope reports `tick_failed` (or any non-`ready` status), you
print its `chat_summary` and stop. A failure `chat_summary` is a
terminal classification the wrapper already produced after it read,
logged, and classified the underlying cause for you — it is finished
work, not a task handed to you. Concretely, on the dispatcher side:

- The ONLY file you ever `Read` is a `payload_path` taken from a `ready`
  envelope's `dispatch_entries[]`. You do not `Read`, `grep`, `sed`, or
  `cat` any file under `scripts/` or `references/` for any reason.
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

The orchestrator forwards these on every dispatcher script invocation
(they all source `env_paths.sh` which derives the rest):

```
PROJECT={project}                          # always
GROUP={group}                              # always
GITLAB_TOKEN={gitlab_token}                # always
REPO_PARENT_PATH={repo_path}               # when trigger supplied non-default repo_path
RESULT_BASENAME={result_basename}          # when project uses non-default basenames
DATA_BASENAME={data_basename}              # idem
```

`PROJECT` / `GROUP` come from the trigger / callback payload.
`GITLAB_TOKEN` comes from the deployment pin or environment.
`REPO_PARENT_PATH` defaults to `/data` inside `env_paths.sh`
when unset; non-default deployments MUST keep passing it on every
scheduled trigger and callback because the dispatcher needs it before
locating `${CAMPAIGN_STATE_FILE}`. Basenames carry-forward from the
persisted state when the trigger omits them; the wrappers re-source
`env_paths.sh` with the persisted values when needed.

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
| UI account allocation (slot sizes, `max_accounts_per_issue` cap, pool-too-small abort) | `dispatch_prepare_tick.sh` steps 14 + 18 |
| Per-IID prep (allocate_attempt, prepare_attempt, claude_settings copy, glab issue read, label transitions to `doing`, build_prompt, state-file init) | `dispatch_prepare_tick.sh` step 20 |
| Executor prompt rendering + sentinel check | `dispatch_prepare_tick.sh` step 20.8–20.9 |
| `pending_subagents` placeholder + post-launch writeback | `dispatch_prepare_tick.sh` step 19; `dispatch_record_spawn.sh` |
| Phase 6 validation + label sync + state writes + classification + drain | `dispatch_followup.sh` + `_dispatch_lib.sh::phase6_process` |
| Best-effort terminal cleanup decision (`kill_subagent_on_terminal` gate, local-evidence gate) | `_dispatch_lib.sh::phase6_decide_cleanup`; LLM acts on `envelope.cleanup.action` |

For the exhaustive contract of what each wrapper accepts and emits, see
[`references/dispatcher_wrappers.md`](references/dispatcher_wrappers.md).

## What the LLM still owns

| Concern | Why it stays here |
| ------- | ----------------- |
| `sessions_spawn(...)` per IID | OpenClaw runtime tool — not callable from a shell process |
| 3-attempt × 2-second-backoff retry around `sessions_spawn` | Each retry is itself a runtime-tool call. `dispatch_record_spawn.sh` documents and stores the outcome but cannot make the runtime call. |
| `subagents kill --target <key>` | Runtime tool — same reason |
| Printing `chat_summary` to chat | Only the LLM produces user-visible chat |
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
   same `label`, same `timeoutSeconds=30`, same `runTimeoutSeconds`,
   same `cleanup="keep"`). Do NOT mutate the payload between attempts;
   do NOT add a session-name parameter; do NOT switch to a different
   spawn mode; do NOT call any other LLM tool inline. A launch failure
   is anything where the ack does not carry both `runId` AND
   `childSessionKey` — that includes `status:"error"`, gateway
   timeouts, network/transport errors, runtime errors, and the spawn
   tool call itself raising. After 3 attempts fail, immediately call
   `dispatch_record_spawn.sh STATUS=launch_failed`. **No fourth
   attempt, no payload mutation, no "try once more without the label
   parameter".**
2. **Strictly serial `sessions_spawn` calls.** Never batch multiple
   spawns in a single parallel tool-call block. The local loopback
   gateway serializes spawn handling per channel with a ~10s forwarding
   ceiling that `timeoutSeconds=30` cannot override; parallel batching
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
entire `sessions_spawn` payload and runs Steps 0–10 from the prompt's
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

Every wrapper envelope carries a `chat_summary` field — a one-line
human-readable string. The LLM prints exactly that line (no surrounding
prose, no rewording, no JSON dump) to chat and exits. **Never paste
full logs, full diffs, long issue bodies, or the full envelope JSON
into chat.** Operators reading the chat see the summary and dig into
`${RESULT_ROOT}/_dispatcher/log/wrapper.log` for the structured trace
when they need more detail.
