---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-06-09.3] Run a recurring scheduled GitLab issue campaign as a thin LLM orchestrator over three dispatcher-side shell wrappers (dispatch_prepare_tick.sh, dispatch_record_spawn.sh, dispatch_followup.sh). The wrappers own every deterministic step — trigger parsing, state persistence under flock, reconcile, eligibility, per-IID prep (incl. resolve_model_tier), label transitions, executor-prompt rendering, Phase 6 callback handling — and emit single-line JSON envelopes the LLM reads. The LLM only performs the runtime-tool-only operations: anonymous `sessions_spawn` (no name parameter, label=#<iid>-att-<NNN>, timeoutSeconds=30, runTimeoutSeconds=<envelope.run_timeout_seconds>, cleanup=keep, IDENTICAL payload retried up to 3 times with 2-second backoff per §No-Fallback) and best-effort `subagents kill --target <child_session_key>` when followup output or scheduled cleanup_actions request it. Subagents receive the rendered fixed-format executor prompt from a per-IID payload file (the wrapper writes it to ${LOG_DIR}/spawn_payload.txt) and run only the technical workflow described in references/executor_prompt.md. The subagent does NOT load this SKILL and does NOT write state files. v2 label model: per-side blocked-cc / blocked-dispatcher and failed-cc / failed-dispatcher (replacing single blocked / failed), pr REPLACES done after MR creation, plus a persistent model:{tier} dimension (model:flash→model:pro→model:max, monotone for life) and the one-shot quality:low signal. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry with best-effort partial-work force-push after acpx failures (CC side → blocked-cc), dispatcher-side failures → blocked-dispatcher, retry-over-limit promotion blocked-cc→failed-cc / blocked-dispatcher→failed-dispatcher, terminal timeout parking (acpx wall-clock cap → label=timeout, partial work force-pushed, no MR, no auto-retry, never promoted; reviewer strips timeout, adds retry, or applies continue to re-enqueue), per-issue model upgrade in PREPARE (CC-side outcome blocked-cc/timeout/failed-cc or quality:low or continue_count≥N upgrades one tier; dispatcher-side never upgrades), optional per-batch UI-account allocation from the test-team-owned account pool file (relative path under ${REPO_PATH}, opt in via trigger field ui_accounts_relpath with carry-forward persistence — no default; when unconfigured the entire pool flow is skipped and the rendered Claude Code prompt omits its UI accounts section; the relpath is resolved under the project checkout root so the pool may live under any repo subdirectory, not only the data dir) with max_accounts_per_issue capping (default 14) held until callback drains, persistent disk state, stuck-pending detection, trigger-scope eviction for pending IIDs outside issue_iids∩[issue_min_iid,issue_max_iid], optional IID whitelist (issue_iids) and live-label inclusion filter (require_labels with or/and combinator) layered on top of the [issue_min_iid,issue_max_iid] range, and compact orchestrator chat output."
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
| Tells it to | run Steps 0–10: `bash run_acpx_attempt.sh` → stage → push → verify → wiki → labels → MR → pr → summarize → emit compact JSON | implement the GitLab issue using `hulat/agents/*.md` and write spec output under `${OUTPUT_DIR}` |
| Shape | starts with sentinel `# ACPX_AUTO_TESTER_EXECUTOR_PROMPT_V1`, contains `<config>` / `<issue>` / `<env_contract>` / `<instructions>` XML-style blocks | starts with "You are working on GitLab issue #<iid>. Implement the change ...", markdown headers |
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
the Phase 6 blocked-dispatcher reply when exhaustion happens, so by the time the
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

`PROJECT` / `GROUP` / `GITLAB_TOKEN` come from the trigger / callback
payload. `REPO_PARENT_PATH` defaults to `/data` inside `env_paths.sh`
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
| Per-IID prep (allocate_attempt, resolve_model_tier, prepare_attempt, claude_settings copy, glab issue read, label transitions to `doing`, model:{tier} stamp + quality:low consumption, build_prompt with MODEL injected, state-file init) | `dispatch_prepare_tick.sh` step 20 |
| v2 label model (per-side blocked-cc / blocked-dispatcher / failed-cc / failed-dispatcher, pr replaces done, model:{tier} dimension, quality:low) | `references/label_lifecycle.md`; `_dispatch_lib.sh::phase6_sync_labels`; `set_issue_label.sh` |
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
- `dispatch_followup.sh` runs a narrow `reconcile.sh MIN_IID=<iid> MAX_IID=<iid>`
  before writing terminal state, so reviewer relabels between spawn and
  callback get picked up.

Disk cache is corrected to match GitLab — never the other way around.
The LLM does NOT need to second-guess this; the wrappers handle it.

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
