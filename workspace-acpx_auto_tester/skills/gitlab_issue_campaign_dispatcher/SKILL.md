---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-05-14.7] Run a recurring scheduled GitLab issue campaign as a single thick orchestrator with async-callback subagent execution. Orchestrator runs Phases 1-5 (Parse, Reconcile, Eligibility, Per-IID Prep, Async Spawn) on every scheduled wake-up. Phase 5 issues anonymous sessions_spawn calls (NO session name passed — runtime returns runId/childSessionKey), records the (iid, runId, child_session_key) mapping into pending_subagents, and IMMEDIATELY returns waiting_for_callbacks. The runtime later pushes RUN_CHILD_COMPLETION_CALLBACK with each subagent's terminal compact JSON; the orchestrator wakes on each callback and runs Phase 6 (Follow-up) for the matched IID — validate compact reply by iid field, write terminal state files, drain pending entry, classify into campaign_state lists, best-effort cleanup of the child runtime session via `subagents kill --target <childSessionKey>` for terminal done/blocked/failed outcomes when local evidence is persisted (gated by `kill_subagent_on_terminal`, default true; legacy `kill_subagent_on_done=false` disables cleanup when the new field is omitted), optional notify. Subagents receive a fully-rendered self-contained fixed-format prompt and run only the technical workflow (acpx → commit/push/wiki/MR/labels/summarize) — they do NOT load this SKILL and do NOT write state files. The active_issue_iids bookkeeping (persisted before spawn) is the structural same-IID-no-parallel guarantee; replies are matched to dispatched IIDs by the iid field of the compact JSON, NOT by runtime session name. acpx runs with `-s issue-<iid>` for session persistence — if the run is interrupted, the next attempt resumes the Claude Code session with a short continue prompt instead of starting from scratch. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, per-batch UI-account allocation from a deployment-pinned pool held until callback drains, persistent disk state, stuck-pending detection, optional IID whitelist (issue_iids) and live-label inclusion filter (require_labels with or/and combinator) layered on top of the [issue_min_iid,issue_max_iid] range, and compact orchestrator chat output."
allowed-tools: Bash, Read, Write, Edit, sessions_history, sessions_spawn, subagents
---

# GitLab Issue Campaign Dispatcher Skill

All agent runtime files live INSIDE the cloned repo at `${REPO_PATH}/${RESULT_BASENAME}/...` — campaign state, dispatcher logs, locks, per-issue state/logs/summaries, and each per-attempt linked git worktree at `${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>-att-<NNN>/`. Each subagent runs `acpx claude exec` from inside its own per-attempt worktree, so multiple attempts can run concurrently without colliding on the parent checkout. The committed output for each issue lives at `${WORKTREE_DIR}/${RESULT_BASENAME}/issue-<iid>/hulat-spec-issue<iid>/` (the worktree-relative path is `${RESULT_BASENAME}/issue-<iid>/hulat-spec-issue<iid>/`, identical to the legacy single-checkout path) and is force-added by `stage_and_guard.sh`. `max_concurrent_subagents` is bounded above by the deployment-pinned UI account pool size (see §UI Account Allocation Policy) — the system under test logs out an account when it logs in twice, so each in-flight subagent must hold a distinct account. The test team commits `.claude/`, `hulat/`, and `${DATA_BASENAME}/` to master+dev, so the worktree checkout already contains those: `prepare_attempt.sh` does NOT create a `hulat` symlink and does NOT copy `.claude`. The `hulat_dir` trigger field is no longer used (the dispatcher derives `HULAT_DIR=${REPO_PATH}/hulat`); old triggers that still pass it are silently accepted. See [`references/paths.md`](references/paths.md) for the complete layout. (`${RESULT_BASENAME}` / `${DATA_BASENAME}` default to `ifp-result` / `ifp-data`; per-project `result_basename` / `data_basename` trigger fields override them automatically.)

## Single-skill, async-callback model (read first)

This workspace has exactly **one SKILL** (this file). The dispatcher runs in **two distinct execution paths**:

### Path A: scheduled wake-up (`RUN_SCHEDULED_ISSUE_CAMPAIGN`)

| Phase | Name              | What happens |
| ----- | ----------------- | ------------ |
| 1     | Parse             | bootstrap, flock, load + override `campaign_state.json` |
| 2     | Reconcile         | mandatory `reconcile.sh` against GitLab; correct disk cache |
| 3     | Eligibility       | tick-level prep (clone/pull, ensure_labels); form a batch of up to `max_concurrent_subagents` IIDs under launch budget / time budget (cap is upper-bounded by UI pool size — see §UI Account Allocation Policy) |
| 4     | Per-IID Prep      | for each batch member: allocate_attempt → load_ui_accounts → prepare_attempt → read issue labels → transition entry labels to `doing` → build_prompt → init state files (status=in_progress) → render fixed-format prompt |
| 5     | Async Spawn       | issue one **anonymous** `sessions_spawn` per IID (NO session name passed — runtime returns `runId`/`childSessionKey`). Persist `(iid, attempt_number, run_id, child_session_key, spawned_at)` into `campaign_state.json.pending_subagents`. Return a `waiting_for_callbacks` summary and exit. **Does NOT wait for subagent completion.** |

### Path B: callback wake-up (`RUN_CHILD_COMPLETION_CALLBACK`)

The runtime delivers ONE callback per subagent completion. Each callback wakes the same orchestrator session with the subagent's terminal compact JSON in the payload.

| Phase | Name      | What happens |
| ----- | --------- | ------------ |
| 1     | Parse     | bootstrap, flock, load `campaign_state.json` (no trigger override on callback path — scalar inputs preserved from disk; `project`/`group`/`gitlab_token` come from the callback payload) |
| 2     | Reconcile | run `reconcile.sh` for the affected IID (single-IID range when feasible, full range otherwise) — GitLab is still ground truth |
| 6     | Follow-up | parse + validate the callback's compact JSON → match to a `pending_subagents` entry by `iid` (Phase 6 validation rule 2 in [`references/state_schema.md`](references/state_schema.md) §Compact Subagent Reply) → write terminal `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` → drain the pending entry → classify into `completed_iids` / `blocked_iids` / `failed_iids` → optional notify_channel summary → return |

The orchestrator does NOT spawn a replacement subagent on the callback path. The next scheduled wake-up forms the next batch once `pending_subagents` permits.

**The subagent does NOT load this SKILL, NOT read SOUL.md / AGENTS.md, NOT write any state file, NOT call sessions_spawn / sessions_history.** Its entire job: receive the rendered fixed-format prompt as the spawn payload, run acpx + post-acpx workflow per the prompt's `<instructions>` block, and emit a single compact JSON line per [`references/state_schema.md`](references/state_schema.md) §Compact Subagent Reply. The runtime captures that compact JSON and forwards it to the orchestrator inside `RUN_CHILD_COMPLETION_CALLBACK`.

The rendered subagent prompt is built from [`references/executor_prompt.md`](references/executor_prompt.md). All scripts the subagent invokes live in this skill's `scripts/` directory and are called by absolute path via `{SCRIPTS_DIR}`.

## Companion files

This SKILL is intentionally short. Detailed bash and fixed reference data live in sibling folders:

- `scripts/env_paths.sh` — single bootstrap for every script (dispatcher AND subagent paths). SOURCE it.
- `scripts/glab_auth.sh` — bootstraps `glab` CLI; prints `GITLAB_HOST`. Reads the deployment pin at `<workspace>/config/gitlab.env`.
- `scripts/reconcile.sh` — Phase 2: queries GitLab for the IID range and writes the evidence file.
- `scripts/allocate_attempt.sh` — Phase 4: atomically allocates the next attempt number for an IID.
- `scripts/load_ui_accounts.sh` — Phase 4: read the deployment-pinned UI test account pool (`<workspace>/config/ui_accounts.env`); used at the top of every batch to allocate one distinct account per IID.
- `scripts/clone_or_pull.sh` — Phase 3: keep the main repo's refs current. Run once per tick before the batch loop.
- `scripts/ensure_labels.sh` — Phase 3: make sure the workflow labels (`todo retry new doing pr done blocked failed continue`) exist. Run once per tick after auth.
- `scripts/prepare_attempt.sh` — Phase 4: create the per-attempt linked git worktree at `${WORKTREE_DIR}` (under `${WORKTREES_ROOT}=${REPO_PATH}/${RESULT_BASENAME}/.worktrees`) checked out into the per-attempt local branch, return `mode_actual` and `LOCAL_ATTEMPT_BRANCH`. The parent checkout at `${REPO_PATH}` is NEVER mutated by an attempt (only `git fetch` runs against it), so multiple attempts can run concurrently. Does NOT symlink hulat or copy `.claude` — both directories are committed in the test team's master+dev branches, so the worktree checkout already contains them.
- `scripts/build_prompt.sh` — Phase 4: build the Claude Code prompt at `${LOG_DIR}/prompt.txt` (UI account injected; continue-mode summaries + reviewer comments included).
- `scripts/set_issue_label.sh` — Phase 4 (dispatcher: doing transitions) + subagent (Step 6 + 7b: done/pr).
- `scripts/stage_and_guard.sh`, `scripts/commit_and_push.sh`, `scripts/post_push_verify.sh`, `scripts/upload_attempt_artifacts.sh`, `scripts/create_mr.sh`, `scripts/summarize_attempt.sh` — invoked by the subagent (by absolute path) per [`references/executor_prompt.md`](references/executor_prompt.md) `<instructions>`.
- `references/executor_prompt.md` — the fixed-format template the dispatcher renders and ships to each subagent.
- `references/paths.md` — full path layout (dispatcher and per-issue) and rules.
- `references/trigger_command.md` — trigger spec and override rules.
- `references/state_schema.md` — `campaign_state.json`, `issue-<iid>/state.json`, `issue-<iid>/attempt_state.json` schemas, **and the canonical compact subagent reply schema**.
- `references/glab_commands.md` — exhaustive list of allowed `glab` invocations across the workspace.
- `references/label_lifecycle.md` — workflow label transitions and how to perform them.
- `references/continue_mode.md` — reviewer contract for the `continue` label and the prompt template injected in continue mode.

When in doubt about a path / schema / command, READ the matching reference file. Do NOT reconstruct content from memory.

---

## No-Fallback (Dispatcher-Specific)

Universal rules (script failures, glab-only access, abort-on-missing-input, no improvised recovery): [`SOUL.md`](../../SOUL.md) §Shared Operational Policies → No-Fallback. Dispatcher-specific additions:

1. If `flock` cannot acquire the lock, the dispatcher MUST NOT bypass it (no `rm`-the-lockfile, no `--no-lock`, no second-attempt loops). Return a one-line status summary and exit.
2. If `sessions_spawn` for an issue subagent run fails or times out — covering ALL error shapes: launch ack missing `runId`/`childSessionKey`, `gateway timeout`, `status:"error"`, runtime/network/transport error, the spawn tool call itself raising — the dispatcher MUST retry the SAME spawn call **up to 3 total attempts** with a **fixed 2-second sleep between attempts** (`launch_retry_max_attempts=3`, `launch_retry_backoff_seconds=2`). Each retry re-issues the IDENTICAL payload: same rendered prompt, same `timeoutSeconds=30`/`runTimeoutSeconds=18000`/`label="#<iid>-att-<NNN>"`/`cleanup="keep"`, no session name. Do NOT mutate the payload between attempts, do NOT add a session-name parameter, do NOT run the subagent's logic inline. Only after all 3 attempts fail does the dispatcher mark the IID `blocked` with `block_reason="sessions_spawn failed after 3 attempts (2s backoff): <last verbatim error or raw response>"`, run best-effort live-label sync (`remove doing`; `add blocked`), and continue per Blocked Skip-and-Retry. Launch-side failures do NOT increment `retry_count` (that counter governs cross-tick subagent retries under `blocked_retry_limit`; launch failures get their cross-tick reschedule for free via `blocked_iids`). (`label="#<iid>-att-<NNN>"` parameter schema rejection is a deterministic deployment bug that will fail the same way on every retry — the standard 3-attempt loop still runs first, then the whole-batch abort fires from §Concurrency Policy "Session label for runtime UI".)
3. If a per-IID prep step fails (clone_or_pull, prepare_attempt, build_prompt, set_issue_label for `doing`, render), the dispatcher MUST NOT spawn that IID with a partial / improvised setup. Mark the IID `blocked` with the verbatim error as `block_reason`, run best-effort live-label sync (`remove doing`; `add blocked`), and end this serial batch.
4. If `ensure_labels.sh` fails, the dispatcher MUST treat that as a tick-level failure. Return a one-line summary; do NOT skip the call.
5. **Phase 6 reply validation failures.** If a subagent's compact reply fails any validation rule in [`references/state_schema.md`](references/state_schema.md) §Compact Subagent Reply (parse error, IID/attempt mismatch, blocked/failed without block_reason), the dispatcher MUST mark the IID `blocked` with the corresponding `block_reason`, sync the live label to `blocked`, and write that to the state files. Do NOT fabricate a "successful" reply on the subagent's behalf.

On failure:

- Per-IID failure → mark that IID `blocked` (retryable) or `failed` (retry-exhausted) per Blocked Skip-and-Retry; persist; continue with later IIDs.
- Tick-level failure (lock, auth, reconciliation evidence missing, ensure_labels broken, etc.) → return a one-line failure summary; do not early-return as "completed".

---

## Concurrency Policy (Dispatcher-Specific)

Universal contract (same-IID never parallel, async-callback delivery): [`SOUL.md`](../../SOUL.md) §Subagent Concurrency Policy. Dispatcher-specific operational details:

- **Per-attempt worktree isolation (cross-IID parallelism enabled).** Each subagent runs `acpx claude exec` inside its own per-attempt linked git worktree at `${WORKTREE_DIR}=${REPO_PATH}/${RESULT_BASENAME}/.worktrees/issue-<iid>-att-<NNN>/`, created by `scripts/prepare_attempt.sh` via `git worktree add -B`. The parent checkout at `${REPO_PATH}` is NEVER mutated by an attempt — only `git fetch` runs against it under `${RESULT_ROOT}/_dispatcher/locks/repo.lock`, which serializes the fetch step but releases before the worktree is added so concurrent attempts can prep without blocking each other for long. There is no path-based cross-attempt write conflict because each worktree's `${OUTPUT_DIR}` is a distinct directory.
- **Batch size cap.** `max_concurrent_subagents` controls the per-tick batch size and the maximum in-flight subagent count. The trigger value is bounded above by the UI account pool size (see §UI Account Allocation Policy step 3 — pool-too-small is a tick-level failure). Pick up to `min(max_concurrent_subagents, launch_budget_remaining, eligible_iids_remaining)` IIDs in the standard backlog-first order. Allocate one attempt number per IID, one DISTINCT UI account per IID, run prep per IID, and Phase 5 issues one anonymous `sessions_spawn` per surviving IID.
- **No new spawn while pending non-empty (single-batch-in-flight invariant).** The orchestrator MUST NOT form a new batch on a scheduled wake-up while `pending_subagents` is non-empty. UI account safety depends on this — the next batch's account is read fresh from the pool only after pending is empty. If a scheduled wake-up arrives while pending_subagents is non-empty, return a `waiting_for_callbacks` summary and exit. The next batch forms only after every prior pending entry has been drained by callbacks (or evicted by stuck-pending detection).
- **Spawn shape — anonymous, no name (HARD).** Each `sessions_spawn` call sends a fully-rendered fixed-format string built from [`references/executor_prompt.md`](references/executor_prompt.md) as the entire payload. **Pass NO session name to `sessions_spawn`.** Do NOT pass `name=`, `mode="session"`, or any "deterministic session name" parameter — historically that triggered runtime `errorCode=thread_required` on channels (e.g. webchat) that don't support thread-bound named sessions. The runtime is free to pick `mode="run"` or any anonymous mode and return `runId` + `childSessionKey` (e.g. `agent:acpx_auto_tester:subagent:<uuid>`). Set `timeoutSeconds=30` (launch-ack wait — without this the harness/gateway defaults to ~10s and has been observed to time out before the runtime returns the ack, leaving an orphaned `childSessionKey` with no real subagent behind it), `runTimeoutSeconds=18000` (subagent runtime cap), `cleanup="keep"`. If the trigger supplied `--model` (reserved; not currently a trigger field), forward it. Issue `sessions_spawn` STRICTLY one-at-a-time — never batch multiple `sessions_spawn` calls into a single parallel tool-call block. The local loopback gateway serializes spawn handling per channel with a ~10s forwarding ceiling that `timeoutSeconds` cannot override, so parallel batching causes the 2nd+ spawn to return `gateway timeout after 10000ms` with an orphaned `childSessionKey`. Serial spawn + async callback IS the N-concurrent-subagent design; subagents themselves still run concurrently in the runtime backend. Additionally pass a human-readable session label `#<iid>-att-<NNN>` so the OpenClaw Sessions UI LABEL column shows the IID and attempt number instead of `(optional)` — see Phase 5 "Session label for runtime UI" for the exact template and the parameter-name resolution policy.
- **Launch acknowledgement contract.** `sessions_spawn` MUST return a launch ack containing both `runId` AND `childSessionKey` (the runtime may also return `status=accepted`, `mode`, etc. — those are informational). Record the ack into `pending_subagents` (see [`references/state_schema.md`](references/state_schema.md)). A response missing both `runId` and `childSessionKey` is a launch failure for that IID — apply the in-tick retry policy (up to 3 total attempts, 2-second fixed backoff between attempts, IDENTICAL payload each time; see §No-Fallback rule 2 for the full retry contract). Only AFTER all 3 attempts fail does the orchestrator synthesize a Phase 6 blocked reply (`block_reason="sessions_spawn returned no runId/childSessionKey after 3 attempts (2s backoff): <last raw response>"`) and process it on the spot before exiting the scheduled wake-up.
- **Completion contract.** Each subagent's terminal compact JSON is delivered via `RUN_CHILD_COMPLETION_CALLBACK`. The orchestrator wakes on the callback, runs Phase 6 for the matched IID, drains the pending entry. If a callback never arrives within `pending_subagents[iid].stuck_after_minutes` (default: 330 min) after `spawned_at`, the next scheduled wake-up performs **stuck-pending eviction** — synthesize a blocked reply (`block_reason="no callback received within stuck_after_minutes"`) and process it as Phase 6.
- **Subagent identity is the `iid` field of the compact JSON, not the runtime session-key label.** The "same IID never runs twice in parallel" guarantee comes from `active_issue_iids` / `pending_subagents` bookkeeping (Phase 4 step 5 persists the IID before spawn, Phase 6 drains it on callback). The "match callback to pending entry" guarantee comes from Phase 6 validation rule 2 (`reply.iid` is in `pending_subagents` keys AND `reply.attempt_number == pending_subagents[reply.iid].attempt_number`). A callback whose `iid` does not match any pending entry, or whose `attempt_number` is stale, is treated as idempotent / late and dropped (record `"callback_status":"stale_or_already_drained"` in the chat summary).
- **Time budget on the scheduled wake-up only.** `max_runtime_minutes` is checked before launching a new batch (Phase 3). Callback wake-ups process completion + cleanup regardless of the originating tick's wall-clock budget (the budget was for spawning, not for waiting; callbacks are the runtime's, not ours).
- **No mid-batch top-up.** The orchestrator MUST NOT spawn a replacement subagent on a callback wake-up when a single pending entry drains. The next scheduled wake-up forms the next batch once `pending_subagents` is empty.

---

## UI Account Allocation Policy

The system under test does NOT log out the older session on duplicate login (confirmed by the test team). All concurrent subagents therefore share a single UI test account.

1. The account is pinned at deployment time as the first entry in `<workspace>/config/ui_accounts.env`. The trigger does NOT carry account credentials.
2. In Phase 4, before per-IID prep, the dispatcher runs `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> bash scripts/load_ui_accounts.sh` (no BATCH_SIZE needed). The script:
   - prints the first valid `user:pass` entry and exits 0; OR
   - exits 10 if the pool file is missing (deployment incomplete);
   - exits 11 if the pool is empty (no valid entries);
   - exits 12 if the first entry is malformed (no `:` separator).
3. The same account is used for every IID in the batch. The pair `(UI_ACCOUNT, UI_PASSWORD)` is passed to `scripts/build_prompt.sh` as env vars; the script appends the credentials to the Claude Code prompt's `# Working environment` section. `pending_subagents[iid]` does NOT track an account index — all subagents share the same account.
4. **Forbidden workarounds.** The dispatcher MUST NOT:
   - read account credentials from `gitlab.env`, the trigger, the issue body, or any other source
   - skip the `load_ui_accounts.sh` call (the script validates the pool file exists and is well-formed)
   - inject the account into the rendered subagent prompt (the subagent does not need the credentials — they live in the Claude Code prompt only, where Claude Code reads them)

If `<workspace>/config/ui_accounts.env` is missing or malformed, the deployment is incomplete; abort the tick.

---

## GitLab Access (Workspace-Wide)

Universal rules (`glab`-only, forbidden libraries, `--hostname` rule, host pinning, exit-code mapping for `scripts/glab_auth.sh`): [`SOUL.md`](../../SOUL.md) §Shared Operational Policies → GitLab Access / GitLab Host Pinning. The allowed glab invocations across the workspace are listed in [`references/glab_commands.md`](references/glab_commands.md). This list applies to BOTH dispatcher prep scripts and subagent post-acpx scripts — the rules are workspace-wide, not role-specific, because both halves run from the same `scripts/` directory.

Failure mapping:

- If a per-IID prep call to glab fails (e.g. `build_prompt.sh` cannot read the issue, `set_issue_label.sh` cannot transition), mark that IID `blocked` with `block_reason="dispatcher prep failed: <verbatim error>"`, sync the live label to `blocked` when possible, and end this serial batch.
- If `glab auth status` fails after `scripts/glab_auth.sh`, or `scripts/glab_auth.sh` itself exits 10/11/12 (deployment-pin missing/malformed) or 13 (trigger mismatch), abort the tick with a one-line summary.

---

## Source-of-Truth Policy (READ FIRST — HARD RULE)

**GitLab is the ground truth for per-issue workflow state. Disk state is only the dispatcher's progress cache.** When the two disagree, GitLab wins. Disk is corrected to match.

Concrete rules:

1. On every wake-up, BEFORE any "already done" / "already completed" / "skip this IID" / "early return" decision, run `scripts/reconcile.sh` for the full `[issue_min_iid, issue_max_iid]` range (Phase 2). The script writes `${DISPATCHER_LOG_DIR}/reconcile-<ts>.json`. **No evidence file = reconciliation didn't happen = the tick is failed; do not early-return.**
2. The dispatcher MUST NOT use `campaign_state.json.completed_iids`, `campaign_state.json.campaign_status`, or any per-issue `issue-<iid>/state.json.status` to decide an IID is finished. Those are caches.
3. Ground truth per IID comes from the evidence file. Key signals:
   - `is_closed_on_gitlab` ⇔ live GitLab state is literal `closed`. Closed issues are hard terminal and MUST NEVER be scheduled, even if they have `continue` or lack `done`+`pr`.
   - `has_done_pr` ⇔ live GitLab labels contain both literal `done` and literal `pr`.
   - `is_done_on_gitlab` ⇔ `is_closed_on_gitlab == true` OR `has_done_pr == true`. This backward-compatible terminal-skip field is what the dispatcher uses for "do not schedule".
   - `needs_continue` ⇔ the issue is opened and live GitLab labels contain literal `continue` (or legacy misspelling `contiune`). This is set by a human reviewer who has noticed that a previous `done` + `pr` result was incorrect and wants the agent to resume on the existing work branch. `continue` wins if it is present alongside `done` and/or `pr`, but only while the issue is opened.
   - `user_reopened` ⇔ the issue is opened, does not have the completed pair `done`+`pr`, and none of `failed`, `blocked`, `continue`, or `contiune` are present in live labels.
4. **Disk cache correction is mandatory** when they disagree:
   - If `is_closed_on_gitlab == true`: remove IID from `unfinished_iids`/`blocked_iids`/`failed_iids`/`active_issue_iids`; add to `completed_iids`; update per-issue state file only if needed (`status=done`, `mode="fresh"`); persist.
   - Else if `needs_continue == true`: remove from `completed_iids`/`failed_iids`; add to `unfinished_iids`; per-issue state `status=pending`, `mode="continue"` (leave `attempts_total` untouched); force `campaign_status=running`; persist.
   - Else if disk says finished but `user_reopened == true`: same as above but `mode="fresh"`.
   - If disk says unfinished but `is_done_on_gitlab == true` AND `needs_continue == false`, mark it finished on disk and skip.
5. An "already completed" reply is allowed only when the evidence file from this tick exists AND every IID in range has `is_done_on_gitlab == true` AND `needs_continue == false` in it AND `issue_iids_whitelist` is empty for this tick (a whitelist narrows reconcile to a subset of the range, so the evidence file cannot speak for the whole range — see Phase 2).

In short: **trust the evidence file, not the JSON cache. If you didn't run `reconcile.sh` this tick, you have no right to say anything is done.**

---

## Inputs and Trigger Command

See `references/trigger_command.md` for the full trigger spec, required fields, expected fixed values, and the trigger-input override rule.

Key requirements:

- All scalar trigger inputs (`issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, `max_concurrent_subagents`) are authoritative for this tick. Overwrite the disk copy in `campaign_state.json` before running the algorithm. `max_concurrent_subagents` must satisfy `1 ≤ max_concurrent_subagents`; values below 1 abort the tick with `"invalid_max_concurrent_subagents: must be >= 1"`. There is no pool-size upper bound — all concurrent subagents share the same UI account.
- The optional filter fields (`issue_iids`, `require_labels`, `require_labels_match`) follow the same trigger-authoritative rule. Each tick's trigger value (or its absence) wins; the dispatcher does NOT carry stale filter values forward when the next trigger drops the field. See `references/trigger_command.md` for the parse / validation contract and Phase 1 step 2 for how the dispatcher applies them.
- The optional clone parent `repo_path` is a bootstrap path input. When omitted, scripts default to parent `/data` and final repo root `/data/${project}`. When supplied, validate it is an absolute parent directory (not `/`, no `..`, no whitespace, no shell-unsafe characters outside `[A-Za-z0-9_./-]`), then forward it as `REPO_PARENT_PATH=...` on dispatcher script execs. `env_paths.sh` derives final `REPO_PATH=${repo_path}/${project}` and the dispatcher renders that final path into the executor prompt. Non-default deployments must keep passing `repo_path` on scheduled triggers and callbacks because the dispatcher needs it before locating `campaign_state.json`.
- The optional per-project basenames `result_basename` / `data_basename` use **carry-forward** semantics, NOT the per-tick reset rule above. When the trigger supplies them they overwrite the persisted values; when the trigger omits them the persisted values stay (or `ifp-result` / `ifp-data` on a fresh deployment). They are forwarded as `RESULT_BASENAME=...` / `DATA_BASENAME=...` env vars to every script and substituted as `{RESULT_BASENAME}` / `{DATA_BASENAME}` in the executor prompt. Validate that each value is a plain directory name (no `/`, `..`, or whitespace); abort the tick with `"invalid_result_basename"` / `"invalid_data_basename"` on violation. See `references/trigger_command.md` for the full contract.
- `non_interactive=true`, `session_mode=per_issue`, `scheduling_mode=quota_carryover`, `blocked_policy=skip_and_retry` are required fixed values; abort if missing.

---

## Locking

Inline at the start of the dispatcher's bash session, after `scripts/env_paths.sh` is sourced:

```bash
exec 9>"${LOCK_FILE}"
flock -n 9 || exit 0
```

If the lock cannot be acquired, return a one-line status summary and exit 0.

---

## Per-Issue Subagent Rules

Each issue uses its own subagent. The **runtime** session name is **always anonymous** — the orchestrator does NOT pass a name to `sessions_spawn`. The runtime returns `runId` + `childSessionKey` (e.g. `agent:acpx_auto_tester:subagent:<uuid>`) which the orchestrator records into `pending_subagents` for audit and stuck-detection. The "logical" name `issue-<project>-<iid>` only appears in human-readable logs / `active_issue_sessions` for debugging — it is NOT the runtime session-key.

1. Never reuse a subagent for a different issue. (The rendered prompt embeds the IID; reuse is structurally impossible because the work order is per-IID.)
2. The dispatcher creates a fresh anonymous subagent for each spawn. Resume of a prior subagent is not part of this contract.
3. The dispatcher sends each subagent the rendered `references/executor_prompt.md` string as the entire `sessions_spawn` payload. There is no separate trigger envelope — the rendered prompt IS the work order.
4. **`active_issue_iids` + `pending_subagents` are updated atomically per batch and are the structural guarantee against same-IID parallelism.** Before issuing each `sessions_spawn` (Phase 5), append the IID to `active_issue_iids` and write a placeholder pending entry; after the launch ack returns, populate `pending_subagents[iid]` with `(attempt_number, run_id, child_session_key, spawned_at)` and persist `campaign_state.json`. After Phase 6 (callback wake-up) has processed an IID, drain it from BOTH `active_issue_iids` and `pending_subagents`, classify into the appropriate completed/blocked/failed list, persist again. The combined size of `pending_subagents` MUST never exceed `max_concurrent_subagents`. **The dispatcher MUST NOT spawn a subagent for an IID that is already in `active_issue_iids` / `pending_subagents`** — this is the rule that replaces the old session-name dedup.
5. **No spawn while pending non-empty.** The dispatcher MUST NOT form a new batch on a scheduled wake-up while `pending_subagents` is non-empty (after stuck-pending eviction at the top of the wake-up). Return `waiting_for_callbacks` and exit; the next scheduled wake-up tries again.
6. **No spawn on the callback path.** Phase 6 (callback wake-up) drains pending entries and writes terminal state; it does NOT issue a replacement spawn even if quota / time budget remain.

---

## Subagent Runtime Cleanup Policy

After every terminal Phase 6 outcome (callback path or inline-synthesized reply) the orchestrator's Phase 6 (step 9) MAY call the runtime-side `subagents` tool to release the subagent's runtime session and transcript-store entry. This is a **best-effort cleanup pass**, not part of the correctness contract — its only purpose is to stop the runtime session store from growing unbounded as terminal subagents accumulate. The corresponding bulk-prune CLI (`openclaw sessions cleanup --enforce`) is operator-side maintenance scheduled independently, NOT invoked from inside this orchestrator.

1. **Tool + invocation shape.** Use the `subagents` tool with `action="kill"` and `target=<child_session_key>`, where `child_session_key` is the value captured into `pending_subagents[iid].child_session_key` at Phase 5 launch ack. The `subagents` tool exposes `list` / `kill` / `steer` actions; only `kill` is used by this SKILL.
2. **Gate — terminal outcomes, opt-out via trigger.** Cleanup MUST fire only when ALL THREE conditions hold:
   - `final_status in {"done","blocked","failed"}` after Phase 6 step 5's retry-promotion.
   - `kill_subagent_on_terminal` is true on the post-override `campaign_state.json` (trigger-controlled, defaults to `true` when omitted — see [`references/trigger_command.md`](references/trigger_command.md)). Legacy compatibility: if `kill_subagent_on_terminal` is omitted but legacy `kill_subagent_on_done=false` is present, cleanup is disabled.
   - The captured `child_session_key` is a non-empty string (orphan-pending entries with `null` `child_session_key` are skipped because there is no target to kill).
3. **Local-evidence gate for `blocked` / `failed`.** Before killing a failed or blocked subagent, the dispatcher MUST verify local evidence exists so operators can debug without `sessions_history`:
   - `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` have already been written by Phase 6.
   - `${SUMMARY_FILE}` exists under `${ISSUE_ROOT}`.
   - `${LOG_DIR}/prompt.txt` exists when `reply.log_dir` / derived `${LOG_DIR}` is non-empty.
   - `${LOG_DIR}/claude_result.txt`, `${LOG_DIR}/acpx_raw.log`, `${LOG_DIR}/git_status.txt`, and `${LOG_DIR}/git_diff.patch` are preserved when they exist, but their absence is not itself a cleanup blocker because failures can happen before the corresponding step starts.
   Failure paths MUST NOT publish evidence to GitLab Wiki; local disk evidence under `${LOG_DIR}` / `${ISSUE_ROOT}` is the postmortem source. If required local evidence is missing, skip cleanup and report `"cleanup_status":"skipped: local_evidence_missing"`.
4. **Best-effort error handling.** Cleanup failure (tool not registered on this runtime, target session not found, RPC timeout) MUST NOT mutate state files, MUST NOT re-classify the IID into `blocked_iids` / `failed_iids`, MUST NOT retry within this callback wake-up. Record the verbatim error in the chat summary's `cleanup_status` field and proceed. The next scheduled wake-up does NOT replay the cleanup — leaving the orphan runtime session in place is the documented degradation mode; operators reclaim those entries later via `openclaw sessions cleanup --enforce`.
5. **Ordering inside Phase 6.** Cleanup runs AFTER step 8 (drain pending entry + persist) so the state-file invariants are committed first. Capture `child_session_key` from the `pending_subagents` entry BEFORE step 8 drains it — once drained, the value is gone from disk.

The compact chat summary on handled callback and inline-synthesized paths carries one `cleanup_status` value:

| Value                                          | Meaning                                                                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `"killed"`                                     | `subagents kill` succeeded; the runtime session is gone.                                   |
| `"failed: <verbatim error>"`                   | `subagents kill` returned an error. State files are unaffected.                            |
| `"skipped: cleanup_disabled"`                  | Gate failed: terminal cleanup is disabled by trigger / legacy compatibility.               |
| `"skipped: no_child_session_key"`              | Gate failed: drained pending entry had `null` / empty `child_session_key` (orphan-pending).|
| `"skipped: local_evidence_missing"`            | Gate failed: blocked/failed local evidence is missing, so the runtime transcript is kept.  |

---

## Per-Exec Env Contract (Dispatcher Minimum Vars)

Universal frame: [`SOUL.md`](../../SOUL.md) §Per-Exec Env Contract. Each Bash exec runs in a fresh shell; export the minimum on the same line.

Dispatcher's bash exec minimum (varies by script):

- Always: `PROJECT`, `GROUP`, `GITLAB_TOKEN`. Also always when non-default is in use: `REPO_PARENT_PATH`, `RESULT_BASENAME`, `DATA_BASENAME`. `REPO_PARENT_PATH` defaults inside `env_paths.sh` to `/data` if unset, and final `REPO_PATH` is derived as `${REPO_PARENT_PATH}/${PROJECT}`; the basenames default to `ifp-result` / `ifp-data`. The orchestrator MUST forward the post-override values so projects that ship custom paths or basenames get them on every exec.
- `reconcile.sh`: either `MIN_IID` + `MAX_IID` (range mode), OR `IID_LIST` (list mode, comma-separated; takes precedence over `MIN_IID`/`MAX_IID` when set, even when empty). When `IID_LIST` is the empty string and `MIN_IID`/`MAX_IID` are unset, the script writes an empty evidence array and exits 0.
- `allocate_attempt.sh`: also `IID`.
- `load_ui_accounts.sh`: optional `BATCH_SIZE`.
- `clone_or_pull.sh`: also `BRANCH`.
- `prepare_attempt.sh`, `build_prompt.sh`: also `ISSUE_IID`, `ATTEMPT_NUMBER`, `BRANCH`, `DEV_BRANCH`, `ISSUE_MODE` (and for `build_prompt.sh`: `UI_ACCOUNT`, `UI_PASSWORD`). `HULAT_DIR` is derived inside `env_paths.sh` and does not need to be passed.
- `set_issue_label.sh`, `ensure_labels.sh`: also `ISSUE_IID` (label.sh only).

Recommended pattern:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat GROUP=claw_gitlab GITLAB_TOKEN=<token> \
REPO_PARENT_PATH=/data \
RESULT_BASENAME=ifp-result DATA_BASENAME=ifp-data \
ISSUE_IID=14 ATTEMPT_NUMBER=3 BRANCH=master DEV_BRANCH=dev \
ISSUE_MODE=fresh \
bash scripts/<script>.sh
```

The script self-bootstraps via `env_paths.sh`: derives paths (dispatcher and per-issue layers when `ISSUE_IID` is set), runs glab auth, computes `PROJECT_FULL` / `PROJECT_URI`.

---

## Working Directory

See [`SOUL.md`](../../SOUL.md) §Working Directory. The skill directory for THIS skill is the directory containing this SKILL.md (e.g. `<workspace>/skills/gitlab_issue_campaign_dispatcher/`). Run `cd "${SKILL_DIR}"` ONCE per session before any `bash scripts/...` invocation.

---

## Dispatcher Algorithm (two execution paths)

Run on every wake-up. There are two trigger commands and therefore two execution paths:

- **`RUN_SCHEDULED_ISSUE_CAMPAIGN`** (scheduled wake-up) — Phases 1 → 5 below. After Phase 5, return `waiting_for_callbacks` and exit. No Phase 6 happens on this path (except inline-blocked synthesis for launch failures).
- **`RUN_CHILD_COMPLETION_CALLBACK`** (callback wake-up) — see §Callback Wake-up Algorithm at the end of this section.

When a step below says `bash scripts/X.sh`, that is shorthand for the script action — in an actual OpenClaw Bash tool call, prefix the command with the minimum env vars from the Per-Exec Env Contract plus any script-specific vars in the same exec. Never rely on exports from a previous Bash tool call.

### Phase 1 — Parse (scheduled wake-up)

1. **Bootstrap.**
   - `cd ${SKILL_DIR}` — see "Working Directory" above; mandatory before any relative `scripts/...` invocation.
   - Source `scripts/env_paths.sh` with `PROJECT`, `GROUP`, `GITLAB_TOKEN`, and `REPO_PARENT_PATH=<repo_path>` if the trigger supplied a non-default clone parent. This must happen before acquiring the flock because `LOCK_FILE` is derived from the selected final repo path.
   - Acquire the flock above.
   - If the lock cannot be acquired, return a one-line `"lock_held"` summary and exit 0.
2. **Load + override campaign state.**
   - Read `${CAMPAIGN_STATE_FILE}`, or initialize using fresh-init values from `references/state_schema.md` if absent.
   - Apply schema migration if the on-disk file uses the legacy scalar `active_issue_iid` / `active_issue_session` — see `references/state_schema.md` "Legacy on-disk shapes the loader must tolerate" for the rule. Default `max_concurrent_subagents` to `1` if missing. If `pending_subagents` is missing (legacy file), initialize to `{}`. If `issue_iids_whitelist` / `require_labels` / `require_labels_match` are missing (older file), initialize to `[]` / `[]` / `"or"`.
   - Apply trigger-input override: overwrite `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, `max_concurrent_subagents`, and (optionally) `stuck_after_minutes` / `acpx_resume` / `kill_subagent_on_terminal` with the trigger values. When the trigger omits `max_concurrent_subagents`, default it to `1` for the tick AND persist that default. The post-override value must satisfy `1 ≤ max_concurrent_subagents`; values below 1 abort the tick with `"invalid_max_concurrent_subagents: must be >= 1"`. There is no pool-size upper bound — all concurrent subagents share the same UI account. When the trigger omits `stuck_after_minutes`, default to `330` and persist. When the trigger omits `acpx_resume`, default to `false` and persist. When the trigger omits `kill_subagent_on_terminal`, default to `true` and persist, except that legacy `kill_subagent_on_done=false` with no new field disables terminal cleanup for compatibility.
   - **Repo path override.** When the trigger supplies `repo_path`, validate it is an absolute parent directory (reject `/`, dot segments, whitespace, and shell-unsafe characters outside `[A-Za-z0-9_./-]`; abort with `"invalid_repo_path"`) and use it for this tick. When omitted, default the parent to `/data`. Forward the selected parent as `REPO_PARENT_PATH=...` on every subsequent dispatcher script exec this tick, derive final `REPO_PATH=${repo_path}/${project}`, and render that final path into the executor prompt as `{WORKTREE_DIR}`. Persist `campaign_state.json.repo_path` as the parent path for audit after the state file has been loaded, but do not rely on the persisted value to bootstrap a non-default deployment; the trigger/callback must keep carrying it.
   - **Claude settings path override.** When the trigger supplies `claude_settings_path`, validate the value is an absolute file path using the same safety rules as `repo_path` (reject `/` as the path itself, dot segments, whitespace, and shell-unsafe characters outside `[A-Za-z0-9_./-]`; abort with `"invalid_claude_settings_path"`). When omitted or empty, no settings copy is performed and only the committed `.claude/settings.json` is used. This is a bootstrap path input like `repo_path` — it is NOT persisted to `campaign_state.json` and must be re-supplied on every scheduled wake-up where custom settings are desired.
   - **Per-project basename override (carry-forward semantics).** When the trigger supplies `result_basename` / `data_basename`, validate each value is a plain directory name (reject if it contains `/`, `..`, or whitespace; abort the tick with `"invalid_result_basename"` / `"invalid_data_basename"`) and overwrite `campaign_state.json.result_basename` / `.data_basename`. When the trigger omits the field, KEEP the persisted value; on a fresh deployment with no persisted value, default to `"ifp-result"` / `"ifp-data"` and persist. Forward the post-override values as `RESULT_BASENAME=...` / `DATA_BASENAME=...` on every subsequent script exec this tick, and substitute them for `{RESULT_BASENAME}` / `{DATA_BASENAME}` when rendering the executor prompt in Phase 4 step 7.
   - **Optional filter override.**
     - `issue_iids` (trigger field, comma-separated integers). Parse, trim whitespace, drop empty tokens. If any token is non-integer, abort the tick with `"invalid_issue_iids"`. Persist the parsed list (possibly `[]`) into `issue_iids_whitelist`. The trigger's authoritative voice means: if the trigger omits the field OR sends an empty string, `issue_iids_whitelist` is overwritten to `[]` (whitelist disabled this tick) — stale values from disk are NOT carried forward.
     - `require_labels` (trigger field, comma-separated label names). Parse, trim whitespace around commas, drop empty tokens. Persist into `require_labels`. Same trigger-authoritative semantics as above.
     - `require_labels_match` (trigger field, `or` / `and`). If `require_labels` is empty, normalize to `"or"` (and the field is ignored downstream). If `require_labels` is non-empty: when the trigger omits the field, default to `"or"`; when the trigger supplies a value, accept exactly `"or"` or `"and"` (case-sensitive); any other value → abort the tick with `"invalid_require_labels_match"`. Persist.
   - Persist.
3. **Stuck-pending eviction (NOT subject to the new whitelist / label filter).** Before Phase 2, scan `pending_subagents`. For each entry where `(now - spawned_at) >= stuck_after_minutes`, synthesize a Phase 6 blocked reply (`block_reason="no callback received within stuck_after_minutes (<X> min)"`) and process it inline (write terminal state files, classify into blocked_iids, drain the pending entry, then run Phase 6 cleanup if terminal cleanup is enabled and a `child_session_key` exists). The eviction iterates over `pending_subagents` keys regardless of whether those IIDs are in `issue_iids_whitelist` or satisfy `require_labels` — already-in-flight subagents reflect resources that must be cleaned up no matter what the new tick's filter says. After eviction, `pending_subagents` may be empty (allowing a new batch this tick) or still non-empty (waiting on younger callbacks).
4. **Compute `effective_iid_universe` for this tick.** Let `range = [issue_min_iid, issue_max_iid]`. If `issue_iids_whitelist` is empty, `effective_iid_universe = range`. Otherwise, `effective_iid_universe = sorted(set(issue_iids_whitelist) ∩ set(range))` — IIDs outside the range are silently dropped (this is the "whitelist on top of range" semantic; if the operator wants IIDs outside the range, they must adjust the range). `effective_iid_universe` may be empty (then Phase 2 reconcile produces a degenerate evidence file with zero entries, and Phase 3 returns `"no_eligible_iids"`). The `require_labels` filter is NOT applied at this phase — it requires GitLab data and is applied in Phase 3 against the reconcile evidence file.

### Phase 2 — Reconcile (mandatory, always runs)

1. **Reconcile against the `effective_iid_universe` from Phase 1 step 4.** Two invocation shapes are supported:
   - **Range mode** (whitelist empty — current default behavior): `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> MIN_IID=<min> MAX_IID=<max> bash scripts/reconcile.sh`.
   - **List mode** (whitelist non-empty): `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> IID_LIST="<comma-separated effective_iid_universe>" bash scripts/reconcile.sh`. When `IID_LIST` is non-empty, the script ignores `MIN_IID` / `MAX_IID` and queries exactly the listed IIDs. If `effective_iid_universe == []`, pass `IID_LIST=""`; the script writes an evidence file containing an empty JSON array.
2. Apply disk cache correction per the Source-of-Truth Policy above. **When in list mode, only IIDs present in the evidence file are corrected** — IIDs in `[issue_min_iid, issue_max_iid]` that are outside `effective_iid_universe` are intentionally NOT inspected this tick (their disk cache stays as-is; they will be reconciled on a future tick whose trigger does not narrow them out).
3. Record the evidence file path into `campaign_state.json.last_reconcile_evidence`.

If `reconcile.sh` fails or no evidence file is produced, abort the tick with `"reconcile_failed"`. Do NOT early-return as completed.

**Source-of-Truth Policy interaction with whitelist.** The "early-return as completed" rule (every IID in range is `is_done_on_gitlab && !needs_continue`) requires evidence for **every IID in the configured range**, not just the whitelist. When `issue_iids_whitelist` is non-empty, the evidence file is by construction a partial view of the range, so the dispatcher MUST NOT set `campaign_status="completed"` on this tick. It returns `"running"` (or `"waiting_for_callbacks"` if a batch fires) and lets a future tick without the whitelist make the completion call.

### Phase 3 — Eligibility + tick-level prep

1. **If `pending_subagents` is still non-empty after stuck-eviction**, return `"campaign_status":"waiting_for_callbacks"` immediately. Do NOT form a new batch. Do NOT touch labels. The next scheduled wake-up will re-evaluate.
2. **Tick-level prep — once per tick, only if pending is empty.**
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> bash scripts/ensure_labels.sh` — idempotent; creates the workflow labels if missing. Failure → tick-level `"ensure_labels_failed"` summary and stop.
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> BRANCH=<branch> bash scripts/clone_or_pull.sh` — keeps the main repo's refs current. Failure → tick-level `"clone_or_pull_failed"` summary and stop.
3. **Early-return only if allowed.** Permitted iff:
   - the evidence file from this tick exists
   - every IID in range has `is_done_on_gitlab == true` in it
   - every IID in range has `needs_continue == false` in it
   - `unfinished_iids` is empty and `campaign_status = completed`
   - `issue_iids_whitelist` is empty (whitelist active = partial reconcile evidence; cannot make a "whole range completed" claim — see Phase 2's interaction note)
4. **Apply `require_labels` filter to the eligibility candidates.** When `require_labels` is non-empty, walk the reconcile evidence file and drop any IID whose live `labels` array does not satisfy the match:
   - `require_labels_match == "or"`: keep if `labels ∩ require_labels` is non-empty (at least one match).
   - `require_labels_match == "and"`: keep if `require_labels ⊆ labels` (every required label present).
   - An IID with `missing == true` in the evidence file (glab GET failed) is dropped from this tick's candidates regardless — no live labels available.
   The label filter is applied AFTER the standard "is this IID schedulable" gates (closed → skip; `is_done_on_gitlab && !needs_continue` → skip; blocked deferral / retry policy → maybe skip), not before — i.e., it only narrows the otherwise-eligible set, it does not promote terminal IIDs back into eligibility. When `require_labels` is empty, this step is a no-op.
5. `quota_launched_this_tick = 0`; record `tick_start_time`.

In the async-callback model **the scheduled wake-up forms exactly one batch** (no inner loop). Phase 4 runs once (looping over the IIDs picked into the batch), Phase 5 fires the spawns, and the wake-up exits. Subsequent batches are formed by future scheduled wake-ups (after callbacks have drained the previous batch's `pending_subagents`).

### Phase 4 — Per-IID Prep

This phase runs ONCE per scheduled wake-up. Steps 3–6 iterate over the batch IIDs (1 ≤ batch_size ≤ `max_concurrent_subagents`):

1. **Check time budget.** If `now - tick_start_time >= max_runtime_minutes`, return `"campaign_status":"running","reason":"time_budget"` and exit. (Time is checked once at the top of Phase 4. Once Phase 5 fires, the tick is over regardless of remaining budget — the budget governs *spawning*, not *waiting for callbacks*.)
2. **Form this tick's batch.** Compute `batch_size = min(max_concurrent_subagents, hourly_issue_quota - quota_launched_this_tick, remaining_eligible_iids)`. Pick up to `batch_size` IIDs in this strict order:
   1. lowest-IID non-blocked unfinished backlog items (`todo`, `retry`, `new`, `continue`, `contiune`, `user_reopened`, or required trigger label);
   2. lowest-IID fresh items from `next_new_issue_iid` upward;
   3. lowest-IID retryable blocked items, only after every non-blocked backlog and fresh candidate has been exhausted.

   A lower-numbered `blocked` IID must not be selected ahead of a higher-numbered non-blocked IID. For example, if #305 is `blocked` and #306 is otherwise eligible, the next scheduled wake-up must choose #306 before retrying #305. If `batch_size == 0`, return `"campaign_status":"running","reason":"no_eligible_iids"` (or `"completed"` if every IID in range is terminal) and exit.
3. **Allocate attempt numbers SEQUENTIALLY.** For each IID in the batch, run `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> IID=<iid> bash scripts/allocate_attempt.sh` in its own Bash exec, capturing the printed number `N_iid`.
4. **Load the UI account.** Run `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> bash scripts/load_ui_accounts.sh` in a single Bash exec, capturing one line of `user:pass` form. Use this same account for every IID in the batch. On any non-zero exit code (10/11/12), abort the tick.
5. **Pre-spawn persist.** For every IID in the batch, write a placeholder pending entry: `pending_subagents[iid] = {attempt_number: N_iid, run_id: null, child_session_key: null, spawned_at: null, placeholder: true}` and append `iid` to `active_issue_iids` (and a human-readable label `issue-<project>-<iid>` to `active_issue_sessions` for logging). Persist `campaign_state.json` BEFORE any glab mutation. **This persist is the structural guarantee that the orchestrator does not double-spawn the same IID across crashes / concurrent ticks** — see §Per-Issue Subagent Rules. Phase 5 replaces the placeholder with the real `run_id` / `child_session_key` / `spawned_at` after `sessions_spawn` returns its launch ack.
6. **Per-IID prep.** For each IID in the batch (run all sub-steps for one IID before moving to the next; `prepare_attempt.sh` serializes its `git fetch` + `git worktree add` segment under `${RESULT_ROOT}/_dispatcher/locks/repo.lock`, but that segment is short and other prep work runs without the lock):
   1. Resolve `ISSUE_MODE` for this IID:
      - if reconciliation marked the IID `needs_continue == true`, OR per-issue state has `mode="continue"`, set `ISSUE_MODE=continue`
      - else `ISSUE_MODE=fresh`
   1.5. **Detect resume.** Read `acpx_resume` from `campaign_state.json` (persisted from trigger override, default `false`). If `acpx_resume == true` AND `attempts_total > 0` (not the first attempt), set `ACPX_RESUME=true`. Otherwise `ACPX_RESUME=false`. Does NOT force `ISSUE_MODE=continue` — worktree setup follows the normal reconciliation result (Step 1). The resume mechanism relies on the persisted Claude Code session (`-s issue-<iid>`), not on the worktree's base branch.
   2. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> BRANCH=<branch> DEV_BRANCH=<dev_branch> ISSUE_MODE=<mode> bash scripts/prepare_attempt.sh`. Capture `mode_actual` (line 1) and `LOCAL_ATTEMPT_BRANCH` (line 2). If `mode_actual=fresh` while `ISSUE_MODE=continue` was requested, record `mode_downgraded_from="continue"` later in the attempt state.
   2.5. **Copy Claude Code settings (if configured).** If `claude_settings_path` is non-empty, source `env_paths.sh` with the per-issue vars to derive `${WORKTREE_DIR}`, then:
        - Copy the file to the worktree, replacing the committed `settings.json`: `cp "<claude_settings_path value>" "${WORKTREE_DIR}/.claude/settings.json"`. If the source file does not exist or is not readable, mark the IID `blocked` with `block_reason="claude_settings_path file not found or not readable: <path>"` and skip this IID for the batch. The worktree's `.claude/` directory already exists from `prepare_attempt.sh` (committed in the base branch), so the target directory is guaranteed to exist.
        - Prevent the replacement from being staged into issue MRs: `git -C "${WORKTREE_DIR}" update-index --skip-worktree .claude/settings.json`. This tells git to ignore local changes to the file in this specific worktree's index — `stage_and_guard.sh`'s `git add -A` will not pick it up. The flag is per-worktree (linked worktrees have independent indexes), so other concurrent attempts are unaffected.
   3. Read the live issue title, URL, and labels via `glab api projects/${PROJECT_URI}/issues/${ISSUE_IID}` so the dispatcher can substitute `{ISSUE_TITLE}` / `{ISSUE_TITLE_QUOTED}` / `{ISSUE_URL}` / `{ISSUE_LABELS}` / `{ISSUE_BODY}` (truncated to ≤ 4 KB) into the executor prompt.
   4. **Transition to `doing`.** Use `scripts/set_issue_label.sh` with single-label calls only:
      - Build the entry-label removal set from fixed entry labels plus this tick's trigger labels: `todo`, `retry`, `new`, `continue`, `contiune`, `blocked`, `done`, `pr`, plus every label in `require_labels` that is present on this issue's live label snapshot. Deduplicate the set.
      - Remove each entry label in its own exec (removes are idempotent), then add `doing` in its own exec.
      - This applies to fresh and continue mode. `contiune` is a tolerated misspelling for removal/reconciliation only; do not create it in `ensure_labels.sh`.
      The dispatcher MUST NOT use `-f labels=...` (full-set overwrite) — it would wipe manually-added labels outside the explicit entry-label set.
   5. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> BRANCH=<branch> DEV_BRANCH=<dev_branch> ISSUE_MODE=<mode_actual> UI_ACCOUNT=<user> UI_PASSWORD=<pass> ACPX_RESUME=<true|false> bash scripts/build_prompt.sh`. Writes `${LOG_DIR}/prompt.txt`. When `ACPX_RESUME=true`, writes a short "continue from where you left off" resume prompt instead of the full task prompt. Capture stderr (`CONTINUE_MODE_NO_REVIEWER_COMMENTS`, `CONTINUE_MODE_PRIOR_ATTEMPT_COUNT`) for the attempt state.
   6. **Initialize state files.** Write/refresh `${ATTEMPT_STATE_FILE}` with `{iid, attempt_number, attempt_started_at, mode_requested, mode_actual, mode_downgraded_from, no_reviewer_comments, prior_attempt_count, local_branch, log_dir, status:"in_progress"}`. Write/refresh `${ISSUE_STATE_FILE}` with `{iid, session, status:"in_progress", mode:<mode_actual>, attempts_total:<N_iid>, latest_attempt_number:<N_iid>, latest_attempt_dir, retry_count:<from prior>, updated_at}`.
   7. **Render the executor prompt.** Substitute every `{...}` placeholder in `references/executor_prompt.md` with the per-IID values; verify no unsubstituted placeholders remain. If render fails (missing variable, unsubstituted token), mark the IID `blocked` with `block_reason="prompt template render incomplete: <name>"` and skip this IID for the batch.

   If any sub-step fails for an IID, mark THAT IID `blocked` with `block_reason="dispatcher prep failed: <verbatim error>"`, run best-effort live-label sync (`remove doing`; `add blocked`), drain its placeholder pending entry, and SKIP spawning it. Other IIDs in the batch whose prep succeeded still proceed to Phase 5. The allocated UI accounts for the failed IID return to the pool (no persistence).

### Phase 5 — Async Spawn (fire-and-record)

**Spawn the surviving batch.** Issue one `sessions_spawn` per IID whose Phase 4 prep succeeded — **STRICTLY ONE-AT-A-TIME in the orchestrator**. The entire payload of each spawn is that IID's rendered subagent prompt.

**HARD RULE — no parallel tool-call batching.** Do NOT place multiple `sessions_spawn` invocations in a single parallel tool-call block. Issue spawn-1, wait for its launch ack (or error), validate it per step 1 below, persist `campaign_state.json`, THEN issue spawn-2. Anonymous spawns return launch acks within seconds, so serializing N spawns adds only seconds of wall-clock — not minutes.

**Why this matters.** The local loopback gateway (`ws://127.0.0.1:18789`) processes spawns serially per channel AND enforces an independent ~10s per-call forwarding ceiling that `timeoutSeconds` cannot override. Parallel `sessions_spawn` tool calls therefore queue inside the gateway; from the 2nd call onward they routinely return `status:"error", error:"gateway timeout after 10000ms"` with an orphaned `childSessionKey` and no `runId` — the orphan-pending shape described in §Concurrency Policy.

**Note — this does NOT serialize subagent execution.** Each `sessions_spawn` is the *launch interface*; the subagent runs for hours in the runtime backend and reports back via `RUN_CHILD_COMPLETION_CALLBACK`. Serial spawn calls + async callbacks IS the N-concurrent-subagent design — parallelizing the spawn call itself breaks it instead of speeding it up.

**Spawn shape (HARD):** anonymous, no name passed.
- Do NOT pass a session-name parameter (no `name=`, no `session_name=`, no `mode="session"`, no thread-bound flag). Earlier deployments hit `errorCode=thread_required` on channels that don't support thread bindings; passing no name avoids that path entirely.
- The runtime is free to pick `mode="run"` or any anonymous mode. It MUST return both `runId` and `childSessionKey` in the launch ack (the runtime's auto-generated identifiers like `agent:acpx_auto_tester:subagent:<uuid>` are fine — they're for runtime-side audit, not for matching).
- Set `timeoutSeconds=30` (launch-ack wait — without this the harness/gateway defaults to ~10s and the spawn was observed to return only a `childSessionKey` placeholder with no `runId`, no real subagent ever started). Set `runTimeoutSeconds=18000` (subagent runtime cap), `cleanup="keep"`. If the trigger supplied `--model` (reserved), forward it.
- **Session label for runtime UI.** Pass `label="#<iid>-att-<NNN>"` — literal `#`, decimal `<iid>`, literal `-att-`, attempt number zero-padded to 3 digits, where `<NNN>` is the SAME value as the worktree path `issue-<iid>-att-<NNN>` allocated by `scripts/allocate_attempt.sh` and used by `scripts/prepare_attempt.sh`. Example: IID 7 attempt 1 → `label="#7-att-001"`. This populates the LABEL column in the OpenClaw Sessions UI (currently `(optional)` for spawned subagents because no label is passed; cron sessions already use the same field, e.g. `Cron: worker_ifp2`). The label is **cosmetic only** — callbacks are still matched back to dispatched IIDs by the `iid` field of the compact JSON (Phase 6 validation rule 2), NEVER by label. **Parameter-name resolution policy:** `label=` is the FIRST-CHOICE parameter name (matches the UI column name and how cron sessions populate this field). If the runtime returns a schema error rejecting `label=` (e.g. `unknown field`, `unexpected parameter`), the standard §No-Fallback rule 2 in-tick retry (3 attempts, 2s backoff, IDENTICAL payload) still applies first — the schema error is deterministic so all 3 attempts will fail the same way, but the orchestrator MUST run the loop rather than special-casing this error shape inline. After the 3-attempt loop exhausts, the orchestrator MUST surface the verbatim error in the chat summary AND mark every IID in this tick's batch as `blocked` with `block_reason="sessions_spawn rejected label= parameter after 3 attempts: <raw>"` — do NOT silently strip the label between retries (the IDENTICAL-payload rule forbids it), and do NOT guess at alternative parameter names (`displayName=`, `metadata.label=`, etc.) inline. This SKILL will be updated to the correct parameter name in the next deployment. Roll-out note: validate with a single-IID `issue_iids` whitelist run BEFORE scaling to multi-IID batches so a wrong parameter name does not block the entire backlog.

**The dispatcher does NOT wait for the subagent to finish.** Each `sessions_spawn` returns a launch ack within seconds. For each ack:

1. **Validate the ack with in-tick retry.** A launch failure means any of: ack missing `runId` and/or `childSessionKey`, tool error response (`status:"error"`, `gateway timeout`, `errorCode=...`), network/transport/runtime error, or the spawn tool call itself raising. On any failure, sleep **2 seconds** (fixed backoff) and re-issue the IDENTICAL `sessions_spawn` call — same rendered prompt, same `timeoutSeconds=30`/`runTimeoutSeconds=18000`/`label="#<iid>-att-<NNN>"`/`cleanup="keep"`, no session-name parameter added between attempts, no model/payload mutation. Total cap is **3 attempts per IID** (`launch_retry_max_attempts=3`, `launch_retry_backoff_seconds=2`). Persist nothing between attempts beyond the placeholder pending entry written in Phase 4 step 5. If any attempt returns a valid ack (`runId` AND `childSessionKey` both present), continue with step 2 immediately (do NOT wait for remaining backoff). If all 3 attempts fail, synthesize a Phase 6 blocked reply for THIS IID immediately (`block_reason="sessions_spawn failed after 3 attempts (2s backoff): <last raw response or error>"`), process it on the spot (write terminal state files, classify as `blocked`; do NOT increment `retry_count` — launch-side failures are governed by `blocked_iids` cross-tick reschedule only), and DO NOT add to `pending_subagents`. Surface the per-IID attempt count in the chat summary's `launch_retries[iid] = <1|2|3>` field so operators can spot transient gateway flapping.
2. Populate `pending_subagents[iid]` with `{attempt_number, run_id, child_session_key, spawned_at: <ISO-8601 UTC now>}`. The placeholder entry written before spawn (Phase 4 step 5) is replaced.
3. Persist `campaign_state.json`.

After all `sessions_spawn` calls in the block return their acks (this is fast — no actual subagent work happens here), the orchestrator:

4. Increments `quota_launched_this_tick` by the number of successful launches (NOT `quota_completed_this_tick` — that counts callbacks).
5. Returns the compact chat summary with `"campaign_status": "waiting_for_callbacks"` and the populated `pending_subagents`. **Phase 6 does NOT run on the scheduled wake-up.** Each callback delivers Phase 6 for one IID later.

If the runtime returns an error on `sessions_spawn` (e.g., `gateway timeout`, channel-rejects-spawn, `status:"error"`, `errorCode=...`, network/transport error), the affected IID enters the step-1 in-tick retry loop (up to 3 total attempts, 2s fixed backoff, IDENTICAL payload). Only after retry exhaustion is the IID processed as Phase 6 blocked on the spot. Other IIDs in the batch whose acks succeeded still go to `pending_subagents`.

**Spawn-time failure note.** The dispatcher MUST retry a failed launch inside this tick **exactly up to 3 total attempts with a 2-second fixed backoff between attempts** — IDENTICAL payload each time, no parameter mutation. Retry covers ALL `sessions_spawn` error shapes (ack missing `runId`/`childSessionKey`, `gateway timeout`, `status:"error"`, `errorCode=...`, network/transport error, tool-call raise). Only after retry exhaustion is the IID marked `blocked` (NOT `failed`) with the last verbatim error preserved in `block_reason`; the IID is then queued for cross-tick reschedule via `blocked_iids` under `blocked_retry_limit`. `retry_count` is NOT incremented for launch-side failures — that counter tracks subagent-run retries, not launch retries.

### Phase 6 — Follow-up (orchestrator owns ALL terminal bookkeeping)

Phase 6 runs in two contexts:

**(a) On the callback path (`RUN_CHILD_COMPLETION_CALLBACK`)** — process exactly one IID per wake-up. The callback payload contains the subagent's terminal compact JSON. See §Callback Wake-up Algorithm below for the full step list.

**(b) Inline on the scheduled wake-up** — for synthesized blocked replies (Phase 5 launch retry exhaustion, including ack missing `runId`/`childSessionKey`, or stuck-pending eviction at the top of the tick). Same step list as (a), processed on the spot before Phase 5, except that launch-side synthesized replies skip `retry_count` increment as described in step 5.

In both contexts:

1. **Validate the compact reply** per `references/state_schema.md` §Compact Subagent Reply → "Dispatcher-side validation". Validation failures (parse error, iid mismatch, attempt mismatch, blocked-without-reason) produce a synthetic blocked classification with the appropriate `block_reason` — do not silently accept malformed replies.
2. **Match to a `pending_subagents` entry by `iid` + `attempt_number`.** If `pending_subagents[reply.iid]` does not exist, OR `pending_subagents[reply.iid].attempt_number != reply.attempt_number`, treat as stale / late callback: drop with chat summary `"callback_status":"stale_or_already_drained"` and return. Do NOT mutate state files.
3. **Compute preliminary terminal status.** Start from the compact reply status. Normalize legacy `no_changes` replies to `blocked` with `block_reason="subagent produced no staged changes"` if the reply did not provide one.
4. **Synchronize live workflow labels as the final source-of-truth safety net.** Use `scripts/set_issue_label.sh` single-label calls:
   - final `done`: remove `doing`, `blocked`, `failed`; add `done`; add `pr`. This enforces the user-visible `doing → done → done+pr` end state after the callback is received.
   - final `blocked`: remove `doing`; add `blocked`. Preserve `done` if it was already added before a later failure, so a failure between `done` and `pr` is visible as `done` + `blocked`.
   - final `failed`: remove `doing`; remove `blocked`; add `failed`.
   - legacy `no_changes` after normalization: remove `doing`; add `blocked`.
   Any required live-label sync failure is itself a blocked result unless the status is already `failed`: append `phase6 label sync failed: <stderr>` to `block_reason`, set final status to `blocked`, and run best-effort blocked sync (`remove doing`; `add blocked`).
5. **Promote `blocked → failed` if retry budget exhausted.** Increment `retry_count` first if final `status in {blocked, failed}`, except for launch-side synthesized blocked replies from Phase 5 `sessions_spawn` retry exhaustion; those preserve the prior `retry_count` and are not promoted to `failed` on this tick. For all other blocked/failed outcomes, if `retry_count > blocked_retry_limit`, promote `status=failed` and run the `failed` label sync (`remove doing`; `remove blocked`; `add failed`).
6. **Write the terminal state files** per `references/state_schema.md` §Phase 6 Write Mapping, using the final status after label sync / legacy `no_changes` normalization / retry promotion. The dispatcher writes BOTH `${ATTEMPT_STATE_FILE}` and `${ISSUE_STATE_FILE}` from the compact reply plus label-sync errors. The subagent does not touch them.
7. **Classify into `campaign_state.json` lists.**
   - `done`: add to `completed_iids`; remove from `unfinished_iids`/`blocked_iids`/`failed_iids`. Increment `quota_completed_this_tick` (counted on the callback path).
   - `blocked` (including normalized legacy `no_changes`, not promoted): add to `blocked_iids` with the cooldown-tracking semantics per Blocked Skip-and-Retry; remove from `completed_iids`/`failed_iids`; keep in `unfinished_iids`.
   - `failed` (terminal or promoted): add to `failed_iids`; remove from `unfinished_iids`/`blocked_iids`/`completed_iids`.
8. **Drain the pending entry.** Remove `iid` from `active_issue_iids`, `active_issue_sessions`, and `pending_subagents`. Persist `campaign_state.json`. **Capture `child_session_key` from the drained entry BEFORE removing it** so step 9 can target the right runtime session.
9. **Best-effort subagent runtime cleanup (terminal).** If terminal cleanup is enabled, `final_status in {"done","blocked","failed"}`, and the captured `child_session_key` is a non-empty string, call the `subagents` tool with `action="kill"` and `target=<child_session_key>` to release the terminal subagent's runtime session and transcript-store entry. `kill_subagent_on_terminal` is the primary gate (default `true`); legacy `kill_subagent_on_done=false` disables cleanup when the new field is omitted. For `blocked` / `failed`, first verify local evidence exists (`${ISSUE_STATE_FILE}`, `${ATTEMPT_STATE_FILE}`, `${SUMMARY_FILE}`, and `${LOG_DIR}/prompt.txt` when a log dir exists). Failure paths MUST NOT publish Wiki evidence; `${LOG_DIR}` and `${ISSUE_ROOT}` are the postmortem source. The runtime call is **best-effort and OUT OF BAND of the main correctness path**: any error (tool not registered, target not found, RPC timeout) is recorded as `"cleanup_status":"failed: <verbatim error>"` in the chat summary but MUST NOT mutate state files, MUST NOT re-classify the IID into blocked/failed, MUST NOT retry within this callback wake-up. On success, record `"cleanup_status":"killed"`. When the gate condition is not met, record one of `"cleanup_status":"skipped: cleanup_disabled"` / `"skipped: no_child_session_key"` / `"skipped: local_evidence_missing"` and proceed.
10. **Optional notify.** If a notification channel is configured (reserved trigger field; currently not part of the trigger), post a one-line per-IID summary built from the compact reply: `"#<iid> <status> mr=<merge_request_url> wiki=<wiki_url> mr_action=<mr_action>"`. Skip silently if no channel.

After Phase 6 on the callback path, return the compact `callback_handled` chat summary and exit. The next scheduled wake-up forms the next batch (if quota / time budget remain AND `pending_subagents` is empty after eviction).

### End-of-tick cleanup (scheduled wake-up only)

After Phase 5 fires the spawns and before returning the chat summary:

1. Update `next_new_issue_iid` if fresh issues were introduced.
2. If `pending_subagents` is empty AND every IID in `[issue_min_iid, issue_max_iid]` is terminal (per the latest Phase 2 evidence), set `campaign_status = completed`. Otherwise keep `running`.
3. Persist `campaign_state.json`.
4. Return the compact chat summary (see Chat Output Policy below) with `"campaign_status":"waiting_for_callbacks"` if any spawns succeeded, or `"running"` / `"completed"` if no spawns happened this tick.

### Callback Wake-up Algorithm (`RUN_CHILD_COMPLETION_CALLBACK`)

The runtime wakes the orchestrator session whenever a subagent's terminal compact JSON is available. Payload schema is in `references/trigger_command.md` §Child completion callback trigger; minimum fields are `iid`, `attempt_number`, the subagent's terminal compact JSON (full or split into top-level fields), `runId` or `childSessionKey`, plus the rescheduling scalars (`project`, `group`, `gitlab_token`).

Steps:

1. **Bootstrap.** `cd ${SKILL_DIR}`, source `env_paths.sh` with the callback's `project` / `group` / `gitlab_token` (plus `REPO_PARENT_PATH` when the scheduled trigger used non-default `repo_path`, and plus `RESULT_BASENAME` / `DATA_BASENAME` if the callback payload carries them — otherwise env_paths.sh's hardcoded parent `/data`, `ifp-result`, and `ifp-data` defaults bootstrap the path layout for the initial state-file read), acquire flock. If the lock is held, return `"lock_held"` and exit 0 — the callback is idempotent at the runtime level (it will be retried, OR the holder of the lock is a still-running scheduled tick that will replay state on its next wake-up). Do NOT spin.
2. **Load campaign state.** Read `${CAMPAIGN_STATE_FILE}`. The callback path does NOT apply trigger overrides — the scalar inputs (`hourly_issue_quota`, `max_runtime_minutes`, etc.) come from disk. The persisted `result_basename` / `data_basename` ARE authoritative on this path: if they differ from the bootstrap values used to source `env_paths.sh` in step 1 (e.g., a non-default-basename project whose callback envelope didn't carry the fields), re-source `env_paths.sh` with the persisted values before any subsequent per-script exec, so `${CAMPAIGN_STATE_FILE}` and the per-issue state file paths resolve correctly. Forward those persisted values as `RESULT_BASENAME=...` / `DATA_BASENAME=...` on every script invocation in steps 3–5.
3. **Reconcile narrowly.** Run `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> REPO_PARENT_PATH=<repo_path> RESULT_BASENAME=<result_basename> DATA_BASENAME=<data_basename> MIN_IID=<iid> MAX_IID=<iid> bash scripts/reconcile.sh` (single-IID reconciliation when feasible; full-range fallback if the script does not support narrow ranges). GitLab is still ground truth — if the live label state contradicts the callback's compact JSON (e.g., reviewer flipped to `continue` while the callback was in flight), the source-of-truth policy still wins.
4. **Run Phase 6 inline** for this one IID (validate compact JSON → match pending entry → write state files → classify → drain). See Phase 6 step list above.
5. **Persist + return.** Persist `campaign_state.json`. Return the compact chat summary with `"callback_status":"handled"` (or `"stale_or_already_drained"` if step 2 of Phase 6 found no matching pending entry).

The callback path **never spawns a new subagent.** Even if the IID just drained leaves `pending_subagents` smaller than `max_concurrent_subagents`, the next scheduled wake-up is responsible for forming the next batch. This preserves the simple "one batch per scheduled wake-up" semantics and avoids re-entrant spawn logic on the callback path.

---

## Blocked Skip-and-Retry

1. Blocked issues record `block_reason` in their per-issue state file.
2. A blocked issue is retryable only after `blocked_cooldown_ticks` ticks have elapsed since the last attempt.
3. If `retry_count > blocked_retry_limit` (after Phase 6 increment), the issue is promoted to `failed`. Launch-side `sessions_spawn` failures after the 3-attempt in-tick retry loop still enter `blocked_iids` for cooldown/reschedule, but do NOT increment `retry_count` or promote to `failed` solely through this counter.
4. A blocked issue must not block later non-blocked issues from using quota. Even after cooldown, blocked retries are selected only after all currently eligible non-blocked backlog and fresh candidates have been launched or ruled out.

---

## Terminal Completion Policy

Successful MR creation plus both workflow labels (`done` and `pr`) being present is the terminal completion condition for a normal attempt. Separately, GitLab `state=closed` is a hard terminal skip condition: the dispatcher MUST NOT schedule a closed issue, even if `continue` is present or `done`/`pr` are absent.

The subagent (per `references/executor_prompt.md` `<instructions>`) changes `doing` to `done` after Wiki evidence is published, then adds `pr` after MR creation / rotation succeeds. The dispatcher's Phase 6 — not the subagent — writes the terminal `status=done` to disk based on the subagent's compact reply, and idempotently re-applies the final live-label state (`done` + `pr`) after the callback is received.

For opened issues, the dispatcher MUST NOT schedule that issue again unless reconciliation finds `needs_continue == true` or `user_reopened == true` on GitLab. `continue` wins over cached `done` state and over an existing MR only while the issue is opened.

---

## Chat Output Policy

Return a single compact JSON summary. The shape depends on the wake-up path.

**Scheduled wake-up — typical (just spawned a batch, waiting for callbacks):**

```json
{
  "campaign_status": "waiting_for_callbacks",
  "active_issue_iids": [14],
  "active_issue_sessions": ["issue-px_ifp_hulat-14"],
  "pending_subagents": {
    "14": {"attempt_number": 3, "run_id": "9710b359-...", "child_session_key": "agent:acpx_auto_tester:subagent:b6719233-...", "spawned_at": "2026-05-07T13:42:01Z"}
  },
  "max_concurrent_subagents": 1,
  "ui_account_pool_size": 40,
  "issue_iids_whitelist": [],
  "require_labels": [],
  "require_labels_match": "or",
  "unfinished_iids": [9, 10, 14, 15],
  "next_new_issue_iid": 19,
  "quota_launched_this_tick": 1,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/<project>/ifp-result/_dispatcher/log/reconcile-<ts>.json"
}
```

**Scheduled wake-up with whitelist + label filter:**

```json
{
  "campaign_status": "waiting_for_callbacks",
  "active_issue_iids": [14],
  "active_issue_sessions": ["issue-px_ifp_hulat-14"],
  "pending_subagents": {
    "14": {"attempt_number": 1, "run_id": "...", "child_session_key": "...", "spawned_at": "2026-05-08T09:10:00Z"}
  },
  "max_concurrent_subagents": 1,
  "ui_account_pool_size": 40,
  "issue_iids_whitelist": [14, 17, 20],
  "require_labels": ["acpx-auto", "priority::high"],
  "require_labels_match": "and",
  "effective_iid_universe": [14, 17, 20],
  "label_filtered_in": [14],
  "label_filtered_out": [17, 20],
  "unfinished_iids": [14, 17, 20],
  "next_new_issue_iid": 19,
  "quota_launched_this_tick": 1,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/<project>/ifp-result/_dispatcher/log/reconcile-<ts>.json"
}
```

`effective_iid_universe`, `label_filtered_in`, `label_filtered_out` are optional but recommended fields when filters are active — they let the operator see exactly which IIDs the filters narrowed down to. Omit them when both filters are inactive.

`launch_retries` is an optional map (`{<iid>: <attempt_count_1_to_3>}`) emitted on the scheduled wake-up when Phase 5 step 1's in-tick retry loop fired for at least one IID. Only IIDs whose final attempt count was ≥2 are listed (a single-attempt success is uninteresting). Example: `"launch_retries": {"14": 2, "17": 3}` means IID 14 succeeded on its 2nd attempt and IID 17 burned all 3 attempts (which means IID 17 is also classified `blocked` on this tick). Omit the field entirely when no IID retried. This is the operator's visibility into transient gateway flapping vs. deterministic launch errors.

**Callback wake-up — typical (one IID drained):**

```json
{
  "callback_status": "handled",
  "iid": 14,
  "attempt_number": 3,
  "terminal_status": "done",
  "merge_request_url": "https://gitlab.example.com/.../merge_requests/123",
  "cleanup_status": "killed",
  "remaining_pending_iids": [],
  "campaign_status": "running"
}
```

`cleanup_status` reflects the Phase 6 step 9 subagent runtime cleanup outcome. See §Subagent Runtime Cleanup Policy for the full value table. Always emitted on the callback path (handled variant) and for inline-synthesized Phase 6 outcomes that drain a pending entry; omitted from the stale/late variant.

**Stale / late callback:** `"callback_status": "stale_or_already_drained"` plus `"iid"`, `"attempt_number"`. No state file mutation. No `cleanup_status` either (no entry was drained, so no `child_session_key` to act on).

**Other variants:**

```json
{
  "campaign_status": "running",
  "active_issue_iids": [],
  "active_issue_sessions": [],
  "pending_subagents": {},
  "max_concurrent_subagents": 1,
  "ui_account_pool_size": 40,
  "issue_iids_whitelist": [],
  "require_labels": [],
  "require_labels_match": "or",
  "unfinished_iids": [9, 10, 14],
  "next_new_issue_iid": 19,
  "quota_launched_this_tick": 0,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/<project>/ifp-result/_dispatcher/log/reconcile-<ts>.json",
  "tick_outcome_per_iid": {
    "14": "done",
    "15": "blocked: subagent reply missing block_reason"
  }
}
```

Between batches, while a batch is in flight (Phase 5), `active_issue_iids` reflects the IIDs currently in flight. After Phase 6 drains the batch, the list is empty before the next Phase 4 iteration.

`tick_outcome_per_iid` is optional but recommended — it gives the operator a per-IID summary of this tick at a glance. Pull the values from the validated compact replies.

Never paste full logs, full diffs, or long issue bodies into chat.
