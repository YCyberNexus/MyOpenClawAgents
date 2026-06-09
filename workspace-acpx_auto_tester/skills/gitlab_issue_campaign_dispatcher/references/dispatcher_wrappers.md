# Dispatcher Wrapper Scripts

Three scripts under `scripts/` collapse the dispatcher's Phase 1–4 / 6
glue into a tight LLM-side loop. The orchestrator LLM no longer walks
the SKILL prose step-by-step — it calls one of these wrappers per
wake-up, then performs only the genuinely LLM-only actions
(`sessions_spawn`, `subagents kill`) that the wrappers cannot.

| Wrapper | Replaces SKILL.md prose | When the LLM calls it |
| ------- | ----------------------- | --------------------- |
| `dispatch_prepare_tick.sh` | Phases 1–4 (Parse, Reconcile, Eligibility, Per-IID Prep) of the scheduled wake-up | Once per `RUN_SCHEDULED_ISSUE_CAMPAIGN` |
| `dispatch_record_spawn.sh` | Phase 5 step 2 (post-launch ack writeback) and §No-Fallback rule 2 retry-exhaustion synth | Once per IID per scheduled wake-up, immediately after each `sessions_spawn` outcome |
| `dispatch_followup.sh`     | Phase 6 (callback Follow-up) and the narrow Phase 2 reconcile that precedes it | Once per `RUN_CHILD_COMPLETION_CALLBACK` |

All three:

- Source `env_paths.sh` + `_dispatch_lib.sh` at the top. `dispatch_prepare_tick.sh`
  may re-source `env_paths.sh` after discovering persisted non-default
  `result_basename` / `data_basename` roots.
- Acquire the dispatcher flock (`${LOCK_FILE}`) non-blocking. On miss
  they emit a single-line JSON envelope and exit 0 — the runtime is
  expected to retry the trigger.
- Persist `${CAMPAIGN_STATE_FILE}` atomically (`mktemp` + `mv`).
- Append every state transition to `${DISPATCHER_LOG_DIR}/wrapper.log`
  for post-mortem.
- Emit a single-line JSON envelope on stdout. The LLM should print the
  envelope's `chat_summary` field to chat verbatim and act on the
  structured fields per the per-wrapper tables below.

The LLM contract reduces to four genuinely LLM-only operations:

1. (per spawn) `sessions_spawn(payload=<file contents>, label=child_label,
   timeoutSeconds=30, runTimeoutSeconds=<envelope.run_timeout_seconds>,
   cleanup="keep")` — anonymous, NO `name=`/`session_name=`/`mode="session"`.
2. (per spawn outcome) `bash scripts/dispatch_record_spawn.sh ...` to
   write back the result.
3. (per terminal IID) `bash scripts/dispatch_followup.sh ...` on each
   `RUN_CHILD_COMPLETION_CALLBACK`.
4. (per `cleanup.action == "kill"`) `subagents kill --target <cleanup.target>`.

Every `bash scripts/<name>.sh ...` invocation above is shorthand for the
chained form `cd "${SKILL_DIR}" && … && bash scripts/<name>.sh ...` issued
inside a SINGLE Bash tool call. OpenClaw starts a fresh shell for every
Bash exec — `cd` issued as its own Bash tool call does NOT persist into
the next call, so the relative `scripts/<name>.sh` path resolves against
OpenClaw's default cwd and aborts with `No such file or directory`. See
[SKILL.md §Working Directory](../SKILL.md) and the rendered orchestrator
pseudocode in [SKILL.md §The orchestrator loop](../SKILL.md) for the
canonical form.

Everything else — trigger parsing, state writes, flock, label sync, glab
calls, prompt rendering, classification — happens inside the wrappers.

---

## `dispatch_prepare_tick.sh`

Path: `scripts/dispatch_prepare_tick.sh`
Trigger: `RUN_SCHEDULED_ISSUE_CAMPAIGN`

### Inputs

- **stdin**: the full trigger text (including the `RUN_SCHEDULED_ISSUE_CAMPAIGN`
  header line and every `key=value` line). The wrapper parses this in
  bash and validates every required / optional field per
  [`trigger_command.md`](./trigger_command.md). The orchestrator MUST
  feed this with a heredoc (`bash scripts/dispatch_prepare_tick.sh <<'TRIGGER_EOF' … TRIGGER_EOF`),
  never with `echo "<multi-line literal>" | bash …`. See
  [§Invocation pitfall](#invocation-pitfall) below — the echo form
  silently breaks once the trigger has more than one line.
- **env (minimum)**: none — `PROJECT` / `GROUP` / `GITLAB_TOKEN` /
  `REPO_PARENT_PATH` / `RESULT_BASENAME` / `DATA_BASENAME` are all
  derived from the trigger.

### Pipeline

1. Trigger parse + fixed-value preflight (`non_interactive=true` etc.).
2. Required-field check + integer validation.
3. Export bootstrap env, source `env_paths.sh`. Apply carry-forward
   for `result_basename` / `data_basename` from persisted state when
   the trigger omits them; re-source `env_paths.sh` if they differ.
4. Acquire flock; load `${CAMPAIGN_STATE_FILE}` (or fresh-init).
5. Apply trigger overrides into the in-memory state JSON; validate
   `max_concurrent_subagents` (1..pool_size), `max_accounts_per_issue`,
   `run_timeout_seconds`, `acpx_timeout_seconds`, `require_labels_match`.
6. Migrate legacy on-disk shapes (`active_issue_iid` → array,
   stale account-count fields dropped).
7. Compute `effective_iid_universe` (`[issue_min_iid,issue_max_iid]`
   intersected with `issue_iids` when supplied). This is the hard
   trigger scope for new dispatch and for scope eviction of old pending
   entries.
8. **Pending eviction.** First, any `pending_subagents` entry whose IID
   is outside `effective_iid_universe` is scope-evicted: synthesize a
   Phase 6 `blocked-dispatcher` reply (a dispatcher-side outcome — no CC
   output exists), drain it, persist it, and add a `cleanup_actions[]`
   kill request for the recorded child session key when present. Then
   apply the stuck-pending backstop to remaining entries where
   `(now - spawned_at) >= stuck_after_minutes` (or a placeholder with
   `spawned_at = null`). Stuck eviction is still classified as
   `blocked-dispatcher` but does not emit a kill request unless future
   tooling adds one.
9. If `pending_subagents` is still non-empty after eviction → emit
   `status:"waiting_for_callbacks"` envelope and exit 0.
10. Run `reconcile.sh` (range mode when whitelist empty, list mode
    otherwise). Failure → `status:"tick_failed", chat_summary:"reconcile_failed: …"`.
11. Apply disk-cache correction from the evidence file.
12. Early-return check: all IIDs in range terminal AND whitelist empty →
    `status:"completed"`.
13. Run `ensure_labels.sh` + `clone_or_pull.sh`. Failure on either →
    `status:"tick_failed"`.
14. **Only when `UI_ACCOUNTS_RELPATH` is non-empty** (trigger-supplied or
    carry-forward persisted) — call `load_ui_accounts.sh`, which reads
    `${REPO_PATH}/${UI_ACCOUNTS_RELPATH}` (no default; configured via
    trigger `ui_accounts_relpath`, carry-forward persisted; resolved
    under the project checkout root, NOT under
    `${REPO_PATH}/${DATA_BASENAME}/`); map exit codes 10–16 to the
    documented tick-level abort strings (`ui_account_pool_too_small`,
    `invalid_ui_accounts_relpath`, etc.). When `UI_ACCOUNTS_RELPATH` is
    empty, skip this step entirely: record `ui_account_pool_size = 0`,
    leave `POOL_LINES` / `SLOT_SIZES_CSV` empty, and proceed with the
    `max_concurrent_subagents ≥ 1` check already done at §6 (no
    pool-size upper bound applies). Subsequent per-IID slicing (§18)
    assigns `ui_account_count = 0` to every IID, and `build_prompt.sh`
    drops the `# UI test accounts` section from the rendered Claude
    Code prompt.
15. Apply `require_labels` / `require_labels_match` filter on the
    evidence file. Compute `label_filtered_in` / `label_filtered_out`.
16. **Batch formation.** Priority order:
    non-blocked unfinished backlog (lowest IID first), then fresh IIDs
    at or above `next_new_issue_iid`, then blocked IIDs whose
    `blocked_cooldown_ticks` has elapsed. Cap by
    `min(max_concurrent_subagents, hourly_issue_quota - quota_launched_this_tick)`.
17. For each IID in the batch (sequential):
    1. `allocate_attempt.sh` → attempt number.
18. `load_ui_accounts.sh` already ran in step 14; slice the captured
    pool into per-IID account slots via `SLOT_SIZES` from stderr.
19. **Pre-spawn persist.** Write placeholder pending entries
    (`placeholder:true`, `spawned_at:null`) for every batch IID.
    Persist. This is the structural guarantee against same-IID double
    spawn across crashes.
20. **Per-IID prep loop** (sequential). For each IID:
    1. Resolve `ISSUE_MODE` (`continue` if `needs_continue` from
       reconcile OR persisted state mode == continue; else `fresh`).
    1b. **resolve_model_tier** (v2 §6). From the issue's PRIOR live labels in
       the reconcile evidence (`has_blocked_cc` / `has_timeout` /
       `has_failed_cc` = hard trigger; `quality:low` / `continue_count ≥
       model_upgrade_continue_threshold` = soft trigger; `blocked-dispatcher`
       / `failed-dispatcher` never upgrade) plus the cached `model_tier`,
       decide the new tier (raise one tier, or hold at the cap, or hold). A
       new issue with no `model:{tier}` label is TIER_0. Captures `MODEL`
       (the resolved model name) and `MODEL_TIER_LABEL` for steps 5b / 6. The
       upgrade ladder is the EFFECTIVE tier list — `model_tiers` intersected
       with the `<tier>-settings.json` actually present in `model_settings_dir`
       (auto-discovered each tick via `derive_effective_model_tiers`);
       `reconcile.sh` maps `model:<tier>` labels to integer indices against the
       same effective list, while `ensure_labels.sh` / `set_issue_label.sh` use
       the full `model_tiers`. A configured `model_settings_dir` with none of
       the tiers' `<tier>-settings.json` present aborts the tick
       (`no_model_settings_files`).
    2. `prepare_attempt.sh` → `mode_actual`, `LOCAL_ATTEMPT_BRANCH`.
       Failure → `prep_blocked` (drains pending, classifies as blocked,
       skips IID).
    3. Optional per-tier model-settings copy: when `model_settings_dir` is
       configured, copy `${model_settings_dir}/${MODEL}-settings.json` →
       `${WORKTREE_DIR}/.claude/settings.json` (renamed on copy) +
       `update-index --skip-worktree` so the resolved `model:{tier}` actually
       drives acpx's model. A configured dir whose `${MODEL}-settings.json` is
       missing/unreadable → `prep_blocked` (blocked-dispatcher). Replaces the
       retired `claude_settings_path` single-file override.
    4. `glab api projects/${PROJECT_URI}/issues/${iid}` → title, URL,
       labels, description (truncated to 4 KB).
    5. `set_issue_label.sh remove <entry-label>` × N then `add doing` (the
       "进 doing 清除集" = the whole workflow group; model:{tier} and
       quality:low are deliberately NOT removed).
    5b. `set_issue_label.sh add ${MODEL_TIER_LABEL}` (stamps the resolved
       model tier; the model dimension is internally exclusive). On a
       soft-trigger upgrade that used `quality:low`, also
       `set_issue_label.sh remove quality:low` (one-shot consumption).
    6. `build_prompt.sh` (writes `${LOG_DIR}/prompt.txt`, with `MODEL`
       injected into the prompt's Working environment section).
    7. Initialize `${ATTEMPT_STATE_FILE}` + `${ISSUE_STATE_FILE}` with
       `status=in_progress` (the issue state also stamps `model_tier` /
       `model` / `continue_count`).
    8. Render `references/executor_prompt.md` fenced block via
       inline `python3 -c '…'` (handles multi-line `{ISSUE_BODY}` safely;
       does pure `str.replace` of `{NAME}` → value, no format-string
       gymnastics). The template is extracted by awk bounded by the paired
       sentinels `# ACPX_AUTO_TESTER_EXECUTOR_PROMPT_V1` (opener) and
       `# ACPX_AUTO_TESTER_EXECUTOR_PROMPT_V1_END` (closer), NOT by the
       surrounding triple-backtick fence — this makes nested ```code```
       examples inside the rendered block safe. Missing closer sentinel →
       awk exits 2 → `prep_blocked "executor_prompt.md missing end-sentinel …"`.
       Postcondition grep for any leftover `{[A-Z_…]+}` and fail-fast on
       unsubstituted placeholders.
    9. Sentinel check: rendered first line MUST equal
       `# ACPX_AUTO_TESTER_EXECUTOR_PROMPT_V1`. Mismatch → `prep_blocked`
       with the verbatim `block_reason` from SKILL.md §Phase 5 step 0.
    10. Write the rendered payload to `${LOG_DIR}/spawn_payload.txt`.
        The renderer replaces only dispatcher placeholders like
        `{WORKTREE_DIR}` and intentionally leaves shell literals like
        `${WORKTREE_DIR}` / `${TASK_OUTPUT_DIR}` untouched.
        Add an entry to `dispatch_entries[]`.
21. Emit the final envelope.

### Output (stdout, single line JSON)

| Field | Meaning |
| ----- | ------- |
| `status` | `"ready"` (LLM should spawn), `"waiting_for_callbacks"` (no new batch this tick), `"no_eligible_iids"` (nothing eligible OR all batch IIDs blocked during prep), `"completed"` (every IID in range terminal), `"lock_held"` (another dispatcher tick is holding the flock — safe to retry on the next scheduled trigger), `"tick_failed"` (hard failure — auth, reconcile_failed, ensure_labels_failed, clone_or_pull_failed; chat_summary has the verbatim reason). `lock_held` is distinct from `tick_failed` on purpose: the runtime can re-deliver the trigger soon, while `tick_failed` usually needs operator attention. |
| `dispatch_entries` | Array of `{iid, attempt_number, child_label, payload_path}` objects; empty unless `status == "ready"`. The LLM `Read`s each `payload_path` and feeds the file contents to `sessions_spawn(payload=...)`. **Token-sensitive:** the file holds the GitLab token in cleartext (substituted from `{GITLAB_TOKEN}`); the wrapper writes it with mode 0600 and `dispatch_record_spawn.sh STATUS=spawned` truncates it once the runtime has it. The wrapper.log MUST NEVER include the rendered prompt contents. |
| `run_timeout_seconds` | Pass as `runTimeoutSeconds=` to every `sessions_spawn` in this tick. |
| `max_launch_retries` | Always `3` today. LLM retries the IDENTICAL spawn payload this many times. |
| `backoff_seconds` | Always `2` today. Sleep between retries. |
| `evicted_iids` | IIDs that were evicted from `pending_subagents` at the top of this tick, either because they were outside the current trigger scope or because they were stuck past `stuck_after_minutes`. |
| `scope_evicted_iids` | Subset of `evicted_iids` evicted because the IID was outside `issue_iids ∩ [issue_min_iid,issue_max_iid]`. |
| `cleanup_actions` | Array of best-effort runtime cleanup requests. The LLM must call `subagents kill --target <target>` for each `{action:"kill"}` before spawning new entries from the same envelope. Scope eviction uses this to stop the old subagent/process tree after the issue is marked blocked-dispatcher. |
| `label_filtered_in` / `label_filtered_out` | Optional — only emitted when `require_labels` is non-empty. |
| `tick_outcome_per_iid` | Optional map; populated when per-IID prep failures pushed an IID into blocked-dispatcher. |
| `last_reconcile_evidence` | Absolute path to the `reconcile-<ts>.json` evidence file this tick produced. |
| `chat_summary` | One-line human-readable string for the chat. |

### Exit codes

- `0` — always, even on `tick_failed`. The envelope carries the failure
  reason. (This makes the LLM's calling pattern trivial: always run,
  always parse stdout, never branch on `$?`.)

---

## `dispatch_record_spawn.sh`

Path: `scripts/dispatch_record_spawn.sh`
Called: once per IID per scheduled wake-up, immediately after each
`sessions_spawn` outcome.

### Inputs (env)

| Var | Required | Meaning |
| --- | -------- | ------- |
| `PROJECT`, `GROUP`, `GITLAB_TOKEN` | always | dispatcher minimum |
| `IID` | always | batch IID |
| `ATTEMPT_NUMBER` | always | the attempt number from `dispatch_entries[].attempt_number` |
| `STATUS` | always | `spawned` or `launch_failed` |
| `RUN_ID` | when `STATUS=spawned` | launch ack's `runId` |
| `CHILD_SESSION_KEY` | when `STATUS=spawned` | launch ack's `childSessionKey` |
| `LAUNCH_ATTEMPTS` | when `STATUS=launch_failed` (default 3) | how many spawn attempts were burned |
| `LAUNCH_ERROR` | when `STATUS=launch_failed` | verbatim last error / raw response (preserved into `block_reason`) |
| `REPO_PARENT_PATH`, `RESULT_BASENAME`, `DATA_BASENAME` | when non-default | forwarded same as the prep wrapper |

### Behavior

- `STATUS=spawned`: replaces the pre-spawn placeholder with the launch
  ack values (`run_id`, `child_session_key`, `spawned_at` = now), drops
  `placeholder:true`, bumps `quota_launched_this_tick`, sets
  `campaign_status = "waiting_for_callbacks"`, persists, then truncates
  `${LOG_DIR}/spawn_payload.txt` to scrub the GitLab token.
- `STATUS=launch_failed`: synthesizes a `blocked-dispatcher` Phase 6
  reply (launch is a dispatcher-side step — no CC attempt ran) with
  `block_reason="sessions_spawn failed after ${LAUNCH_ATTEMPTS} attempts (2s backoff): ${LAUNCH_ERROR}"`,
  runs `phase6_process` with `is_launch_synth=true` (so retry_count is
  NOT incremented — launch-side failures get their cross-tick
  reschedule for free via `blocked_iids`), drains the pending entry,
  classifies, persists, and also truncates `${LOG_DIR}/spawn_payload.txt`
  because no runtime owns the prompt after launch exhaustion. Returns the cleanup decision (almost always
  `skip: no_child_session_key` because the failed launch never produced
  one).

### Output (stdout, single line JSON)

| Field | Notes |
| ----- | ----- |
| `status` | `"spawned"` or `"launch_failed_recorded"` |
| `iid`, `attempt_number` | echo of input |
| `final_status` | only on `launch_failed_recorded` — always `"blocked"` (never `failed`; the cross-tick promotion rule excludes launch-side replies) |
| `cleanup` | only on `launch_failed_recorded` — pass `cleanup.target` to `subagents kill` only when `cleanup.action == "kill"` |
| `remaining_pending_count` | how many pending entries remain in `pending_subagents` after this update |
| `chat_summary` | one-line human-readable string |

### Exit codes

- `0` — recorded.
- `2` — invalid input (missing env, unknown `STATUS`, attempt/iid
  mismatch with pending entry).
- `3` — flock could not be acquired.

---

## `dispatch_followup.sh`

Path: `scripts/dispatch_followup.sh`
Trigger: `RUN_CHILD_COMPLETION_CALLBACK`

### Inputs

- **stdin**: the subagent's terminal compact JSON (the runtime's
  `worker_result_json` payload). Empty stdin → synthesized blocked-dispatcher
  reply with `block_reason="callback worker_result_json was empty"` (a
  callback that arrived but is empty is an orchestration/transport anomaly —
  `dispatch_followup.sh` defaults to `block_side="dispatcher"`).
  The orchestrator MUST feed this with a heredoc
  (`… bash scripts/dispatch_followup.sh <<'WORKER_JSON_EOF' … WORKER_JSON_EOF`),
  never with `echo "<literal>" | … bash …`. The compact JSON is
  normally one line, but the heredoc form is the only shape that
  stays correct if a future runtime delivers a multi-line payload —
  see [§Invocation pitfall](#invocation-pitfall) below.
- **env (minimum)**: `PROJECT`, `GROUP`, `GITLAB_TOKEN`, `IID` (the
  callback IID). Optional: `ATTEMPT_NUMBER` (used only for logging when
  the JSON is unparseable), `REPO_PARENT_PATH`, `RESULT_BASENAME`,
  `DATA_BASENAME`.

### Pipeline

1. Source env_paths.sh + lib; acquire flock.
2. Run `reconcile.sh MIN_IID=<iid> MAX_IID=<iid>` (best-effort; failure
   logged but not aborting).
3. Load campaign_state.json; look up `pending_subagents[IID]`. Missing
   → emit `callback_status:"stale_or_already_drained"`, exit 0.
4. Parse compact reply via `phase6_normalize_reply` (unparseable payloads
   synthesized as a blocked-dispatcher reply — an unusable payload is a
   dispatcher-side anomaly; a *parseable* reply missing `block_side` still
   defaults to `block_side:"cc"`, preserving the real-callback = CC-side
   invariant).
5. Cross-check `reply.attempt_number == pending.attempt_number`; mismatch
   → stale, exit 0.
6. Run `phase6_process` with `is_launch_synth=false`:
   - map reply.status + `block_side` to the v2 internal final_status
     (`done` / `blocked_cc` / `blocked_dispatcher` / `failed_cc` /
     `failed_dispatcher` / `timeout`); a real callback is CC-side
   - sync labels (`done` → `pr` (replaces done); `blocked_cc` → `blocked-cc`;
     `blocked_dispatcher` → `blocked-dispatcher`; `failed_cc` → `failed-cc`;
     `failed_dispatcher` → `failed-dispatcher`; `timeout` → `timeout`; label
     sync failure on a non-failed / non-timeout outcome → append to
     block_reason and demote to the same-side `blocked_*` variant)
   - write `${ISSUE_STATE_FILE}` + `${ATTEMPT_STATE_FILE}` per
     state_schema.md §Phase 6 Write Mapping
   - bump retry_count + maybe promote `blocked_cc → failed_cc` /
     `blocked_dispatcher → failed_dispatcher` (`timeout` never consumes
     retry_count and never promotes)
   - drain pending entry, classify into completed/blocked/failed/timeout lists
     (the campaign lists are side-agnostic unions)
7. Decide cleanup (`phase6_decide_cleanup`).
8. Persist campaign_state.json (with `campaign_status="running"` when
   `pending_subagents` reaches empty).
9. Emit envelope.

### Output (stdout, single line JSON)

| Field | Notes |
| ----- | ----- |
| `callback_status` | `"handled"` or `"stale_or_already_drained"` |
| `iid`, `attempt_number` | echo |
| `terminal_status` | final status after label sync + retry promotion (`done` / `blocked_cc` / `blocked_dispatcher` / `failed_cc` / `failed_dispatcher` / `timeout`) |
| `merge_request_url` | from the compact reply |
| `block_reason` | from the compact reply (with any label-sync error appended) |
| `cleanup` | `{action, target, reason}`. LLM should call `subagents kill --target <target>` iff `action == "kill"` |
| `remaining_pending_iids` | the post-drain `pending_subagents` keys |
| `campaign_status` | `"running"` once pending is empty; else preserves prior value |
| `chat_summary` | one-line human-readable string |

### Exit codes

- `0` — handled, stale, OR lock_held (the envelope reports which).

---

## What stays LLM-only

These are the operations the wrappers explicitly do NOT do:

| Operation | Why |
| --------- | --- |
| `sessions_spawn(...)` | OpenClaw runtime tool; only callable from the LLM tool surface. |
| `subagents kill --target <key>` | Same — runtime tool. |
| 3-attempt `sessions_spawn` retry loop with 2-second backoff | The retry payload contract (`launch_retry_max_attempts=3`, `launch_retry_backoff_seconds=2`, IDENTICAL payload) is owned by the LLM because each attempt is itself a `sessions_spawn` call. `dispatch_record_spawn.sh` documents the policy and accepts the post-exhaustion outcome. |
| Chat output | The LLM prints `chat_summary` to chat. Wrappers only emit the envelope to stdout. |

Everything else — including all `set_issue_label.sh` calls, all glab
reads, all state-file writes, all flock — is now wrapper-side.

---

## Diagnostics

Every wrapper appends timestamped lines to
`${RESULT_ROOT}/_dispatcher/log/wrapper.log` (created on demand):

```
[2026-05-18T14:22:01Z] [prepare_tick] tick started project=px_ifp_hulat
[2026-05-18T14:22:09Z] [prepare_tick] prepared iid=14 attempt=3 payload=/data/.../spawn_payload.txt
[2026-05-18T14:42:18Z] [followup] callback received iid=14 attempt=3
[2026-05-18T14:42:21Z] [followup] callback handled iid=14 attempt=3 final_status=done cleanup=kill
```

The wrappers do NOT log secrets — `GITLAB_TOKEN` is forwarded to
underlying scripts via env vars but never appears in the wrapper log.

For deep debugging, run the wrapper manually and inspect the JSON
envelope on stdout + the wrapper log:

```bash
cd workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher
bash scripts/dispatch_prepare_tick.sh <<'TRIGGER_EOF'
RUN_SCHEDULED_ISSUE_CAMPAIGN
group=…
project=…
gitlab_token=…
…(every trigger key=value line)
TRIGGER_EOF
```

## Invocation pitfall

`dispatch_prepare_tick.sh` and `dispatch_followup.sh` both read their
primary input from stdin. The orchestrator MUST feed that input with a
heredoc:

```bash
# correct — heredoc, multi-line safe
bash scripts/dispatch_prepare_tick.sh <<'TRIGGER_EOF'
group=ai-infra
project=pts_ui_testing
…
acpx_timeout_seconds=36000
TRIGGER_EOF
```

The naive `echo "<multi-line literal>" | bash …` form is forbidden
because it silently breaks once the literal spans more than one line.
Observed failure mode in production:

```bash
# WRONG — bash aborts before the wrapper even starts
echo "group=ai-infra
project=pts_ui_testing
…
acpx_timeout_seconds=36000"
   | bash scripts/dispatch_prepare_tick.sh 2>&1
```

```
/bin/bash: -c:行23: 未预期的符号 `|' 附近有语法错误
/bin/bash: -c:行23: `   | bash scripts/dispatch_prepare_tick.sh 2>&1'
```

What happens: the closing `"` on the last `key=value` line ends the
`echo` argument and the newline terminates the `echo` command. The next
line begins with `|`, which bash parses as a brand-new statement
starting with a pipe operator — a syntax error.

Tempting "fixes" that are still fragile and SHOULD NOT be used:

- Backslash-continued echo (`echo "…" \` then `  | bash …`). Works in
  isolation but a stray trailing space after the `\` silently re-breaks
  it, and any embedded `$`, backtick, or `!` inside the trigger gets
  shell-expanded before reaching the wrapper.
- `printf '%s\n' "$trigger_text" | bash …`. Same expansion hazard, and
  the orchestrator usually splices the literal text in place rather
  than referencing a real `$trigger_text` variable, so the multi-line
  problem returns.

Heredocs avoid both problems: the body is read verbatim until the
delimiter, no quoting is required, and the `bash …` command is fully
formed on the line that opens the heredoc.

The same rule applies to `dispatch_followup.sh`: even though the
compact JSON is normally one line today, use a heredoc
(`bash scripts/dispatch_followup.sh <<'WORKER_JSON_EOF' … WORKER_JSON_EOF`)
so the invocation stays correct if the payload ever grows.
