---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-05-07.0] Run a recurring scheduled GitLab issue campaign as a single thick orchestrator with async-callback subagent execution. Orchestrator runs Phases 1-5 (Parse, Reconcile, Eligibility, Per-IID Prep, Async Spawn) on every scheduled wake-up. Phase 5 issues anonymous sessions_spawn calls (NO session name passed — runtime returns runId/childSessionKey), records the (iid, runId, child_session_key) mapping into pending_subagents, and IMMEDIATELY returns waiting_for_callbacks. The runtime later pushes RUN_CHILD_COMPLETION_CALLBACK with each subagent's terminal compact JSON; the orchestrator wakes on each callback and runs Phase 6 (Follow-up) for the matched IID — validate compact reply by iid field, write terminal state files, drain pending entry, classify into campaign_state lists, optional notify. Subagents receive a fully-rendered self-contained fixed-format prompt and run only the technical workflow (acpx → commit/push/wiki/MR/labels/summarize) — they do NOT load this SKILL and do NOT write state files. The active_issue_iids bookkeeping (persisted before spawn) is the structural same-IID-no-parallel guarantee; replies are matched to dispatched IIDs by the iid field of the compact JSON, NOT by runtime session name. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, per-batch UI-account allocation from a deployment-pinned pool held until callback drains, persistent disk state, stuck-pending detection, and compact orchestrator chat output."
allowed-tools: Bash, Read, Write, Edit, sessions_history, sessions_spawn
---

# GitLab Issue Campaign Dispatcher Skill

**SKILL_VERSION: 2026-05-07.0**

On every wake-up, the dispatcher MUST echo the literal string `SKILL_VERSION=2026-05-07.0` in its compact chat summary (add a `"skill_version"` field to the returned JSON). This lets the operator verify which version of the skill is actually loaded. The dispatcher MUST also reject subagent compact replies whose `skill_version` does not equal this literal — see [`references/state_schema.md`](references/state_schema.md) §Compact Subagent Reply.

**Layout change in `2026-05-07.0`.** All agent runtime files (campaign state, dispatcher logs, locks, per-issue worktrees + state + logs + summaries) now live INSIDE the cloned repo at `${REPO_PATH}/ifp_result/...`. The test team commits `.claude/`, `hulat/`, and `ifp_data/` to master+dev, so worktree checkouts already contain those — `prepare_attempt.sh` no longer creates a `hulat` symlink or copies `.claude`. The `hulat_dir` trigger field is no longer used (the dispatcher derives `HULAT_DIR=${REPO_PATH}/hulat`). Old triggers that still pass it are silently accepted. See [`references/paths.md`](references/paths.md) for the complete new layout and the operator migration steps.

## Single-skill, async-callback model (read first)

This workspace has exactly **one SKILL** (this file). The dispatcher runs in **two distinct execution paths**:

### Path A: scheduled wake-up (`RUN_SCHEDULED_ISSUE_CAMPAIGN`)

| Phase | Name              | What happens |
| ----- | ----------------- | ------------ |
| 1     | Parse             | bootstrap, flock, load + override `campaign_state.json` |
| 2     | Reconcile         | mandatory `reconcile.sh` against GitLab; correct disk cache |
| 3     | Eligibility       | tick-level prep (clone/pull, ensure_labels), form bounded batch under `max_concurrent_subagents` / launch budget / time budget |
| 4     | Per-IID Prep      | for each batch member: allocate_attempt → load_ui_accounts → prepare_attempt → build_prompt → label `doing` → init state files (status=in_progress) → render fixed-format prompt |
| 5     | Async Spawn       | issue one **anonymous** `sessions_spawn` per IID (NO session name passed — runtime returns `runId`/`childSessionKey`). Persist `(iid, attempt_number, run_id, child_session_key, ui_account_index, spawned_at)` into `campaign_state.json.pending_subagents`. Return a `waiting_for_callbacks` summary and exit. **Does NOT wait for subagent completion.** |

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
- `scripts/ensure_labels.sh` — Phase 3: make sure the seven workflow labels (`todo doing pr done blocked failed continue`) exist. Run once per tick after auth.
- `scripts/prepare_attempt.sh` — Phase 4: replace the issue's git worktree (a linked worktree at `${REPO_PATH}/ifp_result/issue-<iid>/worktree/`), return `mode_actual` and `LOCAL_ATTEMPT_BRANCH`. As of `2026-05-07.0` it does NOT symlink hulat or copy `.claude` — both directories are committed in the test team's master+dev branches, so the worktree checkout already contains them.
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

Universal rules: [`SOUL.md`](../../SOUL.md) §Shared Operational Policies → No-Fallback. Dispatcher-specific additions:

1. If `flock` cannot acquire the lock, the dispatcher MUST NOT bypass it (no `rm`-the-lockfile, no `--no-lock`, no second-attempt loops). Return a one-line status summary and exit.
2. If `sessions_spawn` for an issue session fails or times out, the dispatcher MUST NOT run the subagent's logic inline in the dispatcher session, spawn a non-dedicated session as a substitute, or retry by spawning a different session name. Mark the IID `blocked` with an accurate `block_reason` and continue per Blocked Skip-and-Retry.
3. **Anonymous async-callback spawns are the contract** (see Concurrency Policy below). `sessions_spawn` returns a launch acknowledgement (`accepted` + `runId` + `childSessionKey`); the orchestrator records that ack into `pending_subagents` and exits. The terminal compact JSON arrives later inside `RUN_CHILD_COMPLETION_CALLBACK`. The orchestrator MUST NOT pass any session name (`mode="session"` / `name=...`) — historically that triggered runtime `errorCode=thread_required` on channels that don't support thread-bound named sessions. The orchestrator MUST NOT switch to a "wait inline for the spawn to return compact JSON" mode (no synchronous batch wait) — that contract was retired in `2026-05-06.7`. Fire-and-forget WITHOUT a callback is still forbidden — if the runtime cannot deliver `RUN_CHILD_COMPLETION_CALLBACK` for this deployment, that is a tick-level failure (record as deployment incompatibility and abort).
4. If a per-IID prep step fails (clone_or_pull, prepare_attempt, build_prompt, set_issue_label for `doing`, render), the dispatcher MUST NOT spawn that IID with a partial / improvised setup. Mark the IID `blocked` with the verbatim error as `block_reason` and continue with the OTHER batch members whose prep succeeded.
5. If `ensure_labels.sh` fails, the dispatcher MUST treat that as a tick-level failure. Return a one-line summary; do NOT skip the call.
6. **Phase 6 reply validation failures.** If a subagent's compact reply fails any validation rule in [`references/state_schema.md`](references/state_schema.md) §Compact Subagent Reply (parse error, IID/attempt mismatch, skill_version mismatch, blocked/failed without block_reason), the dispatcher MUST mark the IID `blocked` with the corresponding `block_reason` and write that to the state files. Do NOT fabricate a "successful" reply on the subagent's behalf.

On failure:

- Per-IID failure → mark that IID `blocked` (retryable) or `failed` (retry-exhausted) per Blocked Skip-and-Retry; persist; continue with later IIDs.
- Tick-level failure (lock, auth, reconciliation evidence missing, ensure_labels broken, etc.) → return a one-line failure summary; do not early-return as "completed".

---

## Concurrency Policy (Dispatcher-Specific)

Universal contract (cap = `max_concurrent_subagents`, same-IID never parallel, async-callback delivery): [`SOUL.md`](../../SOUL.md) §Subagent Concurrency Policy. Dispatcher-specific operational details:

- **Batch shape (scheduled wake-up only).** Pick at most `min(max_concurrent_subagents - len(pending_subagents), launch_budget_remaining, eligible_iids_remaining)` distinct IIDs (backlog-first, then fresh). Allocate attempt numbers SEQUENTIALLY (`scripts/allocate_attempt.sh` per IID, one fresh Bash exec per call). Run per-IID prep (Phase 4) for each batch member. Phase 5 spawns the surviving batch as parallel `sessions_spawn` calls in a SINGLE tool-call block. With `max_concurrent_subagents=1` this degenerates to one spawn per block.
- **No new spawn while pending non-empty (single-batch-in-flight invariant).** The orchestrator MUST NOT form a new batch on a scheduled wake-up while `pending_subagents` is non-empty. UI account safety depends on this — accounts allocated to in-flight subagents stay in `pending_subagents[*].ui_account_index` until the corresponding callback drains them. If a scheduled wake-up arrives while pending_subagents is non-empty, return a `waiting_for_callbacks` summary and exit. The next batch forms only after every prior pending entry has been drained by callbacks (or evicted by stuck-pending detection).
- **Spawn shape — anonymous, no name (HARD).** Each `sessions_spawn` call sends a fully-rendered fixed-format string built from [`references/executor_prompt.md`](references/executor_prompt.md) as the entire payload. **Pass NO session name to `sessions_spawn`.** Do NOT pass `name=`, `mode="session"`, or any "deterministic session name" parameter — historically that triggered runtime `errorCode=thread_required` on channels (e.g. webchat) that don't support thread-bound named sessions. The runtime is free to pick `mode="run"` or any anonymous mode and return `runId` + `childSessionKey` (e.g. `agent:acpx_auto_tester:subagent:<uuid>`). Set `runTimeoutSeconds=3600`, `cleanup="keep"`. If the trigger supplied `--model` (reserved; not currently a trigger field), forward it.
- **Launch acknowledgement contract.** `sessions_spawn` MUST return a launch ack containing both `runId` AND `childSessionKey` (the runtime may also return `status=accepted`, `mode`, etc. — those are informational). Record the ack into `pending_subagents` (see [`references/state_schema.md`](references/state_schema.md)). A response missing both `runId` and `childSessionKey` is a launch failure for that IID — synthesize a Phase 6 blocked reply (`block_reason="sessions_spawn returned no runId/childSessionKey"`) and process it on the spot before exiting the scheduled wake-up.
- **Completion contract.** Each subagent's terminal compact JSON is delivered via `RUN_CHILD_COMPLETION_CALLBACK`. The orchestrator wakes on the callback, runs Phase 6 for the matched IID, drains the pending entry. If a callback never arrives within `pending_subagents[iid].stuck_after_minutes` (default: 90 min) after `spawned_at`, the next scheduled wake-up performs **stuck-pending eviction** — synthesize a blocked reply (`block_reason="no callback received within stuck_after_minutes"`) and process it as Phase 6.
- **Subagent identity is the `iid` field of the compact JSON, not the runtime session-key label.** The "same IID never runs twice in parallel" guarantee comes from `active_issue_iids` / `pending_subagents` bookkeeping (Phase 4 step 5 persists the IID before spawn, Phase 6 drains it on callback). The "match callback to pending entry" guarantee comes from Phase 6 validation rule 2 (`reply.iid` is in `pending_subagents` keys AND `reply.attempt_number == pending_subagents[reply.iid].attempt_number`). A callback whose `iid` does not match any pending entry, or whose `attempt_number` is stale, is treated as idempotent / late and dropped (record `"callback_status":"stale_or_already_drained"` in the chat summary).
- **Time budget on the scheduled wake-up only.** `max_runtime_minutes` is checked before launching a new batch (Phase 3). Callback wake-ups process completion + cleanup regardless of the originating tick's wall-clock budget (the budget was for spawning, not for waiting; callbacks are the runtime's, not ours).
- **No mid-batch top-up.** The orchestrator MUST NOT spawn a replacement subagent on a callback wake-up when a single pending entry drains. The next scheduled wake-up forms the next batch once `pending_subagents` is empty.

---

## UI Account Allocation Policy (READ FIRST — HARD RULE)

The system under test is a UI / web app. When the same UI account logs in twice, the older session is logged out. Two concurrent subagents that share an account therefore continuously kick each other out — the work product is unreliable, and the issue cannot complete.

The dispatcher MUST therefore allocate a **distinct UI account per IID** for every concurrent batch:

1. The pool of available accounts is pinned at deployment time in `<workspace>/config/ui_accounts.env`. The trigger does NOT carry account credentials.
2. In Phase 4, before per-IID prep, the dispatcher runs `BATCH_SIZE=<n> bash scripts/load_ui_accounts.sh` (where `n` is the batch size). The script:
   - prints `n` accounts in pool-file order, one `user:pass` per line, and exits 0; OR
   - exits 10 if the pool file is missing (deployment incomplete);
   - exits 11 if the pool is empty;
   - exits 12 if a pool line is malformed;
   - exits 13 if the pool is smaller than `BATCH_SIZE`.
3. **Pool-too-small is a tick-level failure.** If `load_ui_accounts.sh` exits 13, the dispatcher MUST abort the tick with a one-line summary (`"ui_account_pool_too_small: pool=<size> batch=<n>"`). It MUST NOT shrink the batch, retry with a smaller `max_concurrent_subagents`, or share an account between IIDs. The operator's options are: enlarge the pool in `<workspace>/config/ui_accounts.env`, or lower `max_concurrent_subagents` in the trigger.
4. **Allocation is per-batch and persisted into `pending_subagents` until callback drains.** The dispatcher binds one account to each IID in the batch, in iteration order (`account[k]` → `k`-th IID). The pair `(UI_ACCOUNT, UI_PASSWORD)` is passed to `scripts/build_prompt.sh` as env vars; the script appends the credentials to the Claude Code prompt's `# Working environment` section. The `ui_account_index` (k) is recorded in `pending_subagents[iid].ui_account_index` along with `runId` / `childSessionKey` at spawn time. The account is considered "in use" until the matching `RUN_CHILD_COMPLETION_CALLBACK` arrives and Phase 6 drains the pending entry, OR until stuck-pending eviction releases it. Because §Concurrency Policy's single-batch-in-flight invariant + stuck-pending eviction at the top of every scheduled wake-up together guarantee `pending_subagents` is empty when a new batch forms, the next batch's accounts are always drawn fresh from the pool head — no persistent allocation table needed across ticks.
5. **Forbidden workarounds.** The dispatcher MUST NOT:
   - default a missing account from the pool by reusing one already assigned to another IID in the same batch
   - read account credentials from `gitlab.env`, the trigger, the issue body, or any other source
   - skip the `load_ui_accounts.sh` call when `max_concurrent_subagents=1` (the script is cheap; the single-IID batch still gets a deterministic account from the pool head)
   - persist account-to-IID assignments across ticks (the next tick re-allocates from the head of the pool file)
   - inject the account into the rendered subagent prompt (the subagent does not need the credentials — they live in the Claude Code prompt only, where Claude Code reads them)

If `<workspace>/config/ui_accounts.env` is missing, malformed, or too small, the deployment is incomplete; abort the tick.

---

## GitLab Access (Workspace-Wide)

Universal rules (`glab`-only, forbidden libraries, `--hostname` rule, host pinning, exit-code mapping for `scripts/glab_auth.sh`): [`SOUL.md`](../../SOUL.md) §Shared Operational Policies → GitLab Access / GitLab Host Pinning. The allowed glab invocations across the workspace are listed in [`references/glab_commands.md`](references/glab_commands.md). This list applies to BOTH dispatcher prep scripts and subagent post-acpx scripts — the rules are workspace-wide, not role-specific, because both halves run from the same `scripts/` directory.

Failure mapping:

- If a per-IID prep call to glab fails (e.g. `build_prompt.sh` cannot read the issue, `set_issue_label.sh` cannot transition), mark that IID `blocked` with `block_reason="dispatcher prep failed: <verbatim error>"` and continue with other batch members.
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
   - `needs_continue` ⇔ the issue is opened and live GitLab labels contain literal `continue`. This is set by a human reviewer who has noticed that a previous `done` + `pr` result was incorrect and wants the agent to resume on the existing work branch. `continue` wins if it is present alongside `done` and/or `pr`, but only while the issue is opened.
   - `user_reopened` ⇔ the issue is opened, does not have the completed pair `done`+`pr`, and none of `failed`, `blocked`, or `continue` are present in live labels.
4. **Disk cache correction is mandatory** when they disagree:
   - If `is_closed_on_gitlab == true`: remove IID from `unfinished_iids`/`blocked_iids`/`failed_iids`/`active_issue_iids`; add to `completed_iids`; update per-issue state file only if needed (`status=done`, `mode="fresh"`); persist.
   - Else if `needs_continue == true`: remove from `completed_iids`/`failed_iids`; add to `unfinished_iids`; per-issue state `status=pending`, `mode="continue"` (leave `attempts_total` untouched); force `campaign_status=running`; persist.
   - Else if disk says finished but `user_reopened == true`: same as above but `mode="fresh"`.
   - If disk says unfinished but `is_done_on_gitlab == true` AND `needs_continue == false`, mark it finished on disk and skip.
5. An "already completed" reply is allowed only when the evidence file from this tick exists AND every IID in range has `is_done_on_gitlab == true` AND `needs_continue == false` in it.

In short: **trust the evidence file, not the JSON cache. If you didn't run `reconcile.sh` this tick, you have no right to say anything is done.**

---

## Inputs and Trigger Command

See `references/trigger_command.md` for the full trigger spec, required fields, expected fixed values, and the trigger-input override rule.

Key requirements:

- All scalar trigger inputs (`issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, `max_concurrent_subagents`) are authoritative for this tick. Overwrite the disk copy in `campaign_state.json` before running the algorithm.
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
4. **`active_issue_iids` + `pending_subagents` are updated atomically per batch and are the structural guarantee against same-IID parallelism.** Before issuing each `sessions_spawn` (Phase 5), append the IID to `active_issue_iids` and write a placeholder pending entry; after the launch ack returns, populate `pending_subagents[iid]` with `(attempt_number, run_id, child_session_key, ui_account_index, spawned_at)` and persist `campaign_state.json`. After Phase 6 (callback wake-up) has processed an IID, drain it from BOTH `active_issue_iids` and `pending_subagents`, classify into the appropriate completed/blocked/failed list, persist again. The combined size of `pending_subagents` MUST never exceed `max_concurrent_subagents`. **The dispatcher MUST NOT spawn a subagent for an IID that is already in `active_issue_iids` / `pending_subagents`** — this is the rule that replaces the old session-name dedup.
5. **No spawn while pending non-empty.** The dispatcher MUST NOT form a new batch on a scheduled wake-up while `pending_subagents` is non-empty (after stuck-pending eviction at the top of the wake-up). Return `waiting_for_callbacks` and exit; the next scheduled wake-up tries again.
6. **No spawn on the callback path.** Phase 6 (callback wake-up) drains pending entries and writes terminal state; it does NOT issue a replacement spawn even if quota / time budget remain.

---

## Per-Exec Env Contract (Dispatcher Minimum Vars)

Universal frame: [`SOUL.md`](../../SOUL.md) §Per-Exec Env Contract. Each Bash exec runs in a fresh shell; export the minimum on the same line.

Dispatcher's bash exec minimum (varies by script):

- Always: `PROJECT`, `GROUP`, `GITLAB_TOKEN`.
- `reconcile.sh`: also `MIN_IID`, `MAX_IID`.
- `allocate_attempt.sh`: also `IID`.
- `load_ui_accounts.sh`: optional `BATCH_SIZE`.
- `clone_or_pull.sh`: also `BRANCH`.
- `prepare_attempt.sh`, `build_prompt.sh`: also `ISSUE_IID`, `ATTEMPT_NUMBER`, `BRANCH`, `DEV_BRANCH`, `ISSUE_MODE` (and for `build_prompt.sh`: `UI_ACCOUNT`, `UI_PASSWORD`). `HULAT_DIR` is derived inside `env_paths.sh` and does not need to be passed.
- `set_issue_label.sh`, `ensure_labels.sh`: also `ISSUE_IID` (label.sh only).

Recommended pattern:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat GROUP=claw_gitlab GITLAB_TOKEN=<token> \
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
   - Acquire the flock above.
   - If the lock cannot be acquired, return a one-line `"lock_held"` summary and exit 0.
2. **Load + override campaign state.**
   - Read `${CAMPAIGN_STATE_FILE}`, or initialize using fresh-init values from `references/state_schema.md` if absent.
   - Apply schema migration if the on-disk file uses the legacy scalar `active_issue_iid` / `active_issue_session` — see `references/state_schema.md` "Schema migration" for the rule. Default `max_concurrent_subagents` to `1` if missing. If `pending_subagents` is missing (legacy file), initialize to `{}`.
   - Apply trigger-input override: overwrite `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, `max_concurrent_subagents`, and (optionally) `stuck_after_minutes` with the trigger values. When the trigger omits `max_concurrent_subagents`, default it to `1` for the tick AND persist that default. When the trigger omits `stuck_after_minutes`, default to `90` and persist.
   - Persist.
3. **Stuck-pending eviction.** Before Phase 2, scan `pending_subagents`. For each entry where `(now - spawned_at) >= stuck_after_minutes`, synthesize a Phase 6 blocked reply (`block_reason="no callback received within stuck_after_minutes (<X> min)"`) and process it inline (write terminal state files, classify into blocked_iids, drain the pending entry). After eviction, `pending_subagents` may be empty (allowing a new batch this tick) or still non-empty (waiting on younger callbacks).

### Phase 2 — Reconcile (mandatory, always runs)

1. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> MIN_IID=... MAX_IID=... bash scripts/reconcile.sh`.
2. Apply disk cache correction per the Source-of-Truth Policy above.
3. Record the evidence file path into `campaign_state.json.last_reconcile_evidence`.

If `reconcile.sh` fails or no evidence file is produced, abort the tick with `"reconcile_failed"`. Do NOT early-return as completed.

### Phase 3 — Eligibility + tick-level prep

1. **If `pending_subagents` is still non-empty after stuck-eviction**, return `"campaign_status":"waiting_for_callbacks"` immediately. Do NOT form a new batch. Do NOT touch labels. The next scheduled wake-up will re-evaluate.
2. **Tick-level prep — once per tick, only if pending is empty.**
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> bash scripts/ensure_labels.sh` — idempotent; creates the seven workflow labels if missing. Failure → tick-level `"ensure_labels_failed"` summary and stop.
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> BRANCH=<branch> bash scripts/clone_or_pull.sh` — keeps the main repo's refs current. Failure → tick-level `"clone_or_pull_failed"` summary and stop.
3. **Early-return only if allowed.** Permitted iff:
   - the evidence file from this tick exists
   - every IID in range has `is_done_on_gitlab == true` in it
   - every IID in range has `needs_continue == false` in it
   - `unfinished_iids` is empty and `campaign_status = completed`
4. `quota_launched_this_tick = 0`; record `tick_start_time`.

In the async-callback model **the scheduled wake-up forms exactly one batch** (no inner loop). Phase 4 runs once, Phase 5 fires the spawns, and the wake-up exits. Subsequent batches are formed by future scheduled wake-ups (after callbacks have drained the previous batch's `pending_subagents`).

### Phase 4 — Per-IID Prep

This phase runs ONCE per scheduled wake-up (no loop):

1. **Check time budget.** If `now - tick_start_time >= max_runtime_minutes`, return `"campaign_status":"running","reason":"time_budget"` and exit. (Time is checked once at the top of Phase 4. Once Phase 5 fires, the tick is over regardless of remaining budget — the budget governs *spawning*, not *waiting for callbacks*.)
2. **Form this tick's batch.** Compute `batch_size = min(max_concurrent_subagents - len(pending_subagents), hourly_issue_quota - quota_launched_this_tick, remaining_eligible_iids)`. Pick `batch_size` distinct IIDs in the standard order: lowest-IID eligible backlog items first, then fresh IIDs from `next_new_issue_iid` upward. If `batch_size == 0`, return `"campaign_status":"running","reason":"no_eligible_iids"` (or `"completed"` if every IID in range is terminal) and exit.
3. **Allocate attempt numbers SEQUENTIALLY.** For each IID in the batch, run `IID=<iid> bash scripts/allocate_attempt.sh` in its own Bash exec, capturing the printed number `N_iid`.
4. **Allocate UI accounts for the batch.** Run `BATCH_SIZE=<batch_size> bash scripts/load_ui_accounts.sh` in a single Bash exec, capturing exactly `batch_size` lines of `user:pass` form. Bind `account[k]` to the `k`-th IID of the batch (k=0..batch_size-1). Record `ui_account_index=k` for the IID — this is what goes into `pending_subagents[iid].ui_account_index`. On any non-zero exit code (10/11/12/13), abort the tick.
5. **Pre-spawn persist.** For every IID in the batch, write a placeholder pending entry: `pending_subagents[iid] = {attempt_number: N_iid, run_id: null, child_session_key: null, ui_account_index: k, spawned_at: null, placeholder: true}` and append `iid` to `active_issue_iids` (and a human-readable label `issue-<project>-<iid>` to `active_issue_sessions` for logging). Persist `campaign_state.json` BEFORE any glab mutation. **This persist is the structural guarantee that the orchestrator does not double-spawn the same IID across crashes / concurrent ticks** — see §Per-Issue Subagent Rules. Phase 5 replaces the placeholder with the real `run_id` / `child_session_key` / `spawned_at` after `sessions_spawn` returns its launch ack.
6. **Per-IID prep.** For each IID in the batch (sequentially or in parallel — preps are independent except for the shared `repo.lock` inside `prepare_attempt.sh`):
   1. Resolve `ISSUE_MODE` for this IID:
      - if reconciliation marked the IID `needs_continue == true`, OR per-issue state has `mode="continue"`, set `ISSUE_MODE=continue`
      - else `ISSUE_MODE=fresh`
   2. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> BRANCH=<branch> DEV_BRANCH=<dev_branch> ISSUE_MODE=<mode> bash scripts/prepare_attempt.sh`. Capture `mode_actual` (line 1) and `LOCAL_ATTEMPT_BRANCH` (line 2). If `mode_actual=fresh` while `ISSUE_MODE=continue` was requested, record `mode_downgraded_from="continue"` later in the attempt state.
   3. Read the live issue title, URL, and labels via `glab api projects/${PROJECT_URI}/issues/${ISSUE_IID}` so the dispatcher can substitute `{ISSUE_TITLE}` / `{ISSUE_TITLE_QUOTED}` / `{ISSUE_URL}` / `{ISSUE_LABELS}` / `{ISSUE_BODY}` (truncated to ≤ 4 KB) into the executor prompt.
   4. **Transition to `doing`.** Use `scripts/set_issue_label.sh`:
      - fresh: remove `todo`, `blocked`, `done`, `pr` (each in its own exec; removes are idempotent), then add `doing`.
      - continue: remove `continue`, `blocked`, `done`, `pr`, then add `doing`.
      The dispatcher MUST NOT use `-f labels=...` (full-set overwrite) — it would wipe manually-added labels.
   5. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> BRANCH=<branch> DEV_BRANCH=<dev_branch> ISSUE_MODE=<mode_actual> UI_ACCOUNT=<user> UI_PASSWORD=<pass> bash scripts/build_prompt.sh`. Writes `${LOG_DIR}/prompt.txt` with the issue body, working environment, and UI-account override block. Capture stderr (`CONTINUE_MODE_NO_REVIEWER_COMMENTS`, `CONTINUE_MODE_PRIOR_ATTEMPT_COUNT`) for the attempt state.
   6. **Initialize state files.** Write/refresh `${ATTEMPT_STATE_FILE}` with `{iid, attempt_number, attempt_started_at, mode_requested, mode_actual, mode_downgraded_from, no_reviewer_comments, prior_attempt_count, local_branch, log_dir, status:"in_progress", skill_version}`. Write/refresh `${ISSUE_STATE_FILE}` with `{iid, session, status:"in_progress", mode:<mode_actual>, attempts_total:<N_iid>, latest_attempt_number:<N_iid>, latest_attempt_dir, retry_count:<from prior>, skill_version, updated_at}`.
   7. **Render the executor prompt.** Substitute every `{...}` placeholder in `references/executor_prompt.md` with the per-IID values; verify no unsubstituted placeholders remain. If render fails (missing variable, unsubstituted token), mark the IID `blocked` with `block_reason="prompt template render incomplete: <name>"` and skip this IID for the batch.

   If any sub-step fails for an IID, mark that IID `blocked` with `block_reason="dispatcher prep failed: <verbatim error>"` and skip it for the batch — but DO continue prep for the OTHER batch members. The UI account allocated to a dropped IID returns to the pool (no persistence).

### Phase 5 — Async Spawn (fire-and-record)

**Spawn the surviving batch in a SINGLE tool-call block.** Issue one `sessions_spawn` per IID whose Phase 4 prep succeeded, all in the same parallel block. The entire payload is the rendered subagent prompt. With `max_concurrent_subagents=1` this block contains exactly one `sessions_spawn` call.

**Spawn shape (HARD):** anonymous, no name passed.
- Do NOT pass a session-name parameter (no `name=`, no `session_name=`, no `mode="session"`, no thread-bound flag). Earlier deployments hit `errorCode=thread_required` on channels that don't support thread bindings; passing no name avoids that path entirely.
- The runtime is free to pick `mode="run"` or any anonymous mode. It MUST return both `runId` and `childSessionKey` in the launch ack (the runtime's auto-generated identifiers like `agent:acpx_auto_tester:subagent:<uuid>` are fine — they're for runtime-side audit, not for matching).
- Set `runTimeoutSeconds=3600`, `cleanup="keep"`. If the trigger supplied `--model` (reserved), forward it.

**The dispatcher does NOT wait for the subagent to finish.** Each `sessions_spawn` returns a launch ack within seconds. For each ack:

1. Validate the ack contains both `runId` and `childSessionKey`. Missing → synthesize a Phase 6 blocked reply for THIS IID immediately (`block_reason="sessions_spawn returned no runId/childSessionKey: <raw response>"`), process it on the spot (write terminal state files, classify), and DO NOT add to `pending_subagents`. Continue with other batch members.
2. Populate `pending_subagents[iid]` with `{attempt_number, run_id, child_session_key, ui_account_index, spawned_at: <ISO-8601 UTC now>}`. The placeholder entry written before spawn (Phase 4 step 5) is replaced.
3. Persist `campaign_state.json`.

After all `sessions_spawn` calls in the block return their acks (this is fast — no actual subagent work happens here), the orchestrator:

4. Increments `quota_launched_this_tick` by the number of successful launches (NOT `quota_completed_this_tick` — that counts callbacks).
5. Returns the compact chat summary with `"campaign_status": "waiting_for_callbacks"` and the populated `pending_subagents`. **Phase 6 does NOT run on the scheduled wake-up.** Each callback delivers Phase 6 for one IID later.

If the runtime returns an error on `sessions_spawn` (e.g., `gateway timeout`, channel-rejects-spawn), the affected IID is treated as a launch failure per step 1 above — Phase 6 blocked is processed on the spot. Other IIDs in the batch whose acks succeeded still go to `pending_subagents`.

**Spawn-time concurrency note.** OpenClaw runtime gateways may serialize concurrent `sessions_spawn` calls; if the parallel tool-call block hits gateway timeouts on later IIDs, those IIDs become Phase 6 blocked while earlier IIDs proceed. The dispatcher MUST NOT retry the failed launches inside this tick — they are blocked-cooldown'd and the next scheduled wake-up reschedules them.

### Phase 6 — Follow-up (orchestrator owns ALL terminal bookkeeping)

Phase 6 runs in two contexts:

**(a) On the callback path (`RUN_CHILD_COMPLETION_CALLBACK`)** — process exactly one IID per wake-up. The callback payload contains the subagent's terminal compact JSON. See §Callback Wake-up Algorithm below for the full step list.

**(b) Inline on the scheduled wake-up** — for synthesized blocked replies (launch ack missing `runId`/`childSessionKey`, or stuck-pending eviction at the top of the tick). Same step list as (a), processed on the spot before Phase 5.

In both contexts:

1. **Validate the compact reply** per `references/state_schema.md` §Compact Subagent Reply → "Dispatcher-side validation". Validation failures (parse error, iid mismatch, attempt mismatch, skill_version mismatch, blocked-without-reason) produce a synthetic blocked classification with the appropriate `block_reason` — do not silently accept malformed replies.
2. **Match to a `pending_subagents` entry by `iid` + `attempt_number`.** If `pending_subagents[reply.iid]` does not exist, OR `pending_subagents[reply.iid].attempt_number != reply.attempt_number`, treat as stale / late callback: drop with chat summary `"callback_status":"stale_or_already_drained"` and return. Do NOT mutate state files.
3. **Write the terminal state files** per `references/state_schema.md` §Phase 6 Write Mapping. The dispatcher writes BOTH `${ATTEMPT_STATE_FILE}` and `${ISSUE_STATE_FILE}` from the compact reply. The subagent does not touch them.
4. **Promote `blocked → failed` if retry budget exhausted.** Increment `retry_count` first if `status in {blocked, failed}`. If `retry_count > blocked_retry_limit`, set `status=failed` in both state files and add to `failed_iids`.
5. **Classify into `campaign_state.json` lists.**
   - `done` / `no_changes`: add to `completed_iids`; remove from `unfinished_iids`/`blocked_iids`/`failed_iids`. Increment `quota_completed_this_tick` (counted on the callback path).
   - `blocked` (not promoted): add to `blocked_iids` with the cooldown-tracking semantics per Blocked Skip-and-Retry; remove from `completed_iids`/`failed_iids`; keep in `unfinished_iids`.
   - `failed` (terminal or promoted): add to `failed_iids`; remove from `unfinished_iids`/`blocked_iids`/`completed_iids`.
6. **Drain the pending entry.** Remove `iid` from `active_issue_iids`, `active_issue_sessions`, and `pending_subagents`. Persist `campaign_state.json`.
7. **Optional notify.** If a notification channel is configured (reserved trigger field; currently not part of the trigger), post a one-line per-IID summary built from the compact reply: `"#<iid> <status> mr=<merge_request_url> wiki=<wiki_url> mr_action=<mr_action>"`. Skip silently if no channel.

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

1. **Bootstrap.** `cd ${SKILL_DIR}`, source `env_paths.sh` with the callback's `project` / `group` / `gitlab_token`, acquire flock. If the lock is held, return `"lock_held"` and exit 0 — the callback is idempotent at the runtime level (it will be retried, OR the holder of the lock is a still-running scheduled tick that will replay state on its next wake-up). Do NOT spin.
2. **Load campaign state.** Read `${CAMPAIGN_STATE_FILE}`. The callback path does NOT apply trigger overrides — the scalar inputs (`hourly_issue_quota`, `max_runtime_minutes`, etc.) come from disk.
3. **Reconcile narrowly.** Run `MIN_IID=<iid> MAX_IID=<iid> bash scripts/reconcile.sh` (single-IID reconciliation when feasible; full-range fallback if the script does not support narrow ranges). GitLab is still ground truth — if the live label state contradicts the callback's compact JSON (e.g., reviewer flipped to `continue` while the callback was in flight), the source-of-truth policy still wins.
4. **Run Phase 6 inline** for this one IID (validate compact JSON → match pending entry → write state files → classify → drain). See Phase 6 step list above.
5. **Persist + return.** Persist `campaign_state.json`. Return the compact chat summary with `"callback_status":"handled"` (or `"stale_or_already_drained"` if step 2 of Phase 6 found no matching pending entry).

The callback path **never spawns a new subagent.** Even if the IID just drained leaves `pending_subagents` smaller than `max_concurrent_subagents`, the next scheduled wake-up is responsible for forming the next batch. This preserves the simple "one batch per scheduled wake-up" semantics and avoids re-entrant spawn logic on the callback path.

---

## Blocked Skip-and-Retry

1. Blocked issues record `block_reason` in their per-issue state file.
2. A blocked issue is retryable only after `blocked_cooldown_ticks` ticks have elapsed since the last attempt.
3. If `retry_count > blocked_retry_limit` (after Phase 6 increment), the issue is promoted to `failed`.
4. A blocked issue must not permanently block later issues from using remaining quota.

---

## Terminal Completion Policy

Successful MR creation plus both workflow labels (`done` and `pr`) being present is the terminal completion condition for a normal attempt. Separately, GitLab `state=closed` is a hard terminal skip condition: the dispatcher MUST NOT schedule a closed issue, even if `continue` is present or `done`/`pr` are absent.

The subagent (per `references/executor_prompt.md` `<instructions>`) changes `doing` to `done` after Wiki evidence is published, then adds `pr` after MR creation / rotation succeeds. The dispatcher's Phase 6 — not the subagent — writes the terminal `status=done` to disk based on the subagent's compact reply.

For opened issues, the dispatcher MUST NOT schedule that issue again unless reconciliation finds `needs_continue == true` or `user_reopened == true` on GitLab. `continue` wins over cached `done` state and over an existing MR only while the issue is opened.

---

## Chat Output Policy

Return a single compact JSON summary. The shape depends on the wake-up path.

**Scheduled wake-up — typical (just spawned a batch, waiting for callbacks):**

```json
{
  "skill_version": "2026-05-07.0",
  "campaign_status": "waiting_for_callbacks",
  "active_issue_iids": [14, 15],
  "active_issue_sessions": ["issue-px_ifp_hulat-14", "issue-px_ifp_hulat-15"],
  "pending_subagents": {
    "14": {"attempt_number": 3, "run_id": "9710b359-...", "child_session_key": "agent:acpx_auto_tester:subagent:b6719233-...", "ui_account_index": 0, "spawned_at": "2026-05-07T13:42:01Z"},
    "15": {"attempt_number": 1, "run_id": "...", "child_session_key": "...", "ui_account_index": 1, "spawned_at": "2026-05-07T13:42:01Z"}
  },
  "max_concurrent_subagents": 2,
  "ui_account_pool_size": 4,
  "unfinished_iids": [9, 10, 14, 15],
  "next_new_issue_iid": 19,
  "quota_launched_this_tick": 2,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/<project>/ifp_result/_dispatcher/log/reconcile-<ts>.json"
}
```

**Callback wake-up — typical (one IID drained):**

```json
{
  "skill_version": "2026-05-07.0",
  "callback_status": "handled",
  "iid": 14,
  "attempt_number": 3,
  "terminal_status": "done",
  "merge_request_url": "https://gitlab.example.com/.../merge_requests/123",
  "remaining_pending_iids": [15],
  "campaign_status": "running"
}
```

**Stale / late callback:** `"callback_status": "stale_or_already_drained"` plus `"iid"`, `"attempt_number"`. No state file mutation.

**Other variants:**

```json
{
  "skill_version": "2026-05-07.0",
  "campaign_status": "running",
  "active_issue_iids": [],
  "active_issue_sessions": [],
  "pending_subagents": {},
  "max_concurrent_subagents": 2,
  "ui_account_pool_size": 4,
  "unfinished_iids": [9, 10, 14],
  "next_new_issue_iid": 19,
  "quota_launched_this_tick": 0,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/<project>/ifp_result/_dispatcher/log/reconcile-<ts>.json",
  "tick_outcome_per_iid": {
    "14": "done",
    "15": "blocked: subagent reply skill_version mismatch"
  }
}
```

Between batches, while a batch is in flight (Phase 5), `active_issue_iids` reflects the IIDs currently in flight. After Phase 6 drains the batch, the list is empty before the next Phase 4 iteration.

`tick_outcome_per_iid` is optional but recommended — it gives the operator a per-IID summary of this tick at a glance. Pull the values from the validated compact replies.

Never paste full logs, full diffs, or long issue bodies into chat.
