---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-05-06.6] Run a recurring scheduled GitLab issue campaign as a single thick orchestrator with 6 phases: Parse, Reconcile, Eligibility, Per-IID Prep, Concurrent Spawn, Follow-up. The orchestrator does ALL preparation up front, spawns up to max_concurrent_subagents synchronous subagents in a single parallel sessions_spawn block, then in Phase 6 takes the subagents' compact JSON replies and owns ALL terminal bookkeeping (state files, campaign_state, label classification, optional notify). Subagents receive a fully-rendered self-contained fixed-format prompt and run only the technical workflow (acpx → commit/push/wiki/MR/labels/summarize) — they do NOT load this SKILL and do NOT write state files. Subagent runtime session names MAY be anonymous on channels that do not support thread-bound named sessions (e.g., webchat); the orchestrator matches replies back to dispatched IIDs by the iid field of the compact JSON, and the active_issue_iids bookkeeping provides the structural same-IID-no-parallel guarantee. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, synchronous bounded batches, per-batch UI-account allocation from a deployment-pinned pool, persistent disk state, and compact orchestrator chat output."
allowed-tools: Bash, Read, Write, Edit, sessions_history, sessions_spawn
---

# GitLab Issue Campaign Dispatcher Skill

**SKILL_VERSION: 2026-05-06.6**

On every wake-up, the dispatcher MUST echo the literal string `SKILL_VERSION=2026-05-06.6` in its compact chat summary (add a `"skill_version"` field to the returned JSON). This lets the operator verify which version of the skill is actually loaded. The dispatcher MUST also reject subagent compact replies whose `skill_version` does not equal this literal — see [`references/state_schema.md`](references/state_schema.md) §Compact Subagent Reply.

## Single-skill, six-phase model (read first)

This workspace has exactly **one SKILL** (this file). The dispatcher runs in 6 phases per scheduled tick:

| Phase | Name              | Owner       | What happens |
| ----- | ----------------- | ----------- | ------------ |
| 1     | Parse             | dispatcher  | bootstrap, flock, load + override `campaign_state.json` |
| 2     | Reconcile         | dispatcher  | mandatory `reconcile.sh` against GitLab; correct disk cache |
| 3     | Eligibility       | dispatcher  | tick-level prep (clone/pull, ensure_labels), form bounded batch under `max_concurrent_subagents` / quota / time budget |
| 4     | Per-IID Prep      | dispatcher  | for each batch member: allocate_attempt → load_ui_accounts → prepare_attempt → build_prompt → label `doing` → init state files → render fixed-format prompt |
| 5     | Concurrent Spawn  | dispatcher  | single parallel `sessions_spawn` tool-call block; ONE subagent per IID; synchronous wait for all terminal compact JSON replies |
| 6     | Follow-up         | dispatcher  | parse + validate each compact reply → write terminal `${ISSUE_STATE_FILE}` and `${ATTEMPT_STATE_FILE}` → drain `active_issue_iids` → classify into `completed_iids`/`blocked_iids`/`failed_iids` → optional notify_channel summary → loop to Phase 3 if quota and time budget remain |

**The subagent does NOT load this SKILL, NOT read SOUL.md / AGENTS.md, NOT write any state file.** Its entire job: receive the rendered fixed-format prompt as the spawn payload, run acpx + post-acpx workflow per the prompt's `<instructions>` block, and return a single compact JSON line per [`references/state_schema.md`](references/state_schema.md) §Compact Subagent Reply.

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
- `scripts/prepare_attempt.sh` — Phase 4: replace the issue's worktree, set up the `hulat` symlink and `.claude` runtime config, write `.git/info/exclude`, return `mode_actual` and `LOCAL_ATTEMPT_BRANCH`.
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
3. If the runtime reports that the current channel cannot wait for child sessions, or if it returns only a push-based launch acknowledgement (no terminal compact JSON), the dispatcher MUST NOT switch to `--no-wait` or any other fire-and-forget fallback. Record spawn/wait as unsupported for the affected IID or tick. (Anonymous synchronous subagents that DO return a terminal compact JSON are allowed — see Concurrency Policy "Subagent identity" below.)
4. If a per-IID prep step fails (clone_or_pull, prepare_attempt, build_prompt, set_issue_label for `doing`, render), the dispatcher MUST NOT spawn that IID with a partial / improvised setup. Mark the IID `blocked` with the verbatim error as `block_reason` and continue with the OTHER batch members whose prep succeeded.
5. If `ensure_labels.sh` fails, the dispatcher MUST treat that as a tick-level failure. Return a one-line summary; do NOT skip the call.
6. **Phase 6 reply validation failures.** If a subagent's compact reply fails any validation rule in [`references/state_schema.md`](references/state_schema.md) §Compact Subagent Reply (parse error, IID/attempt mismatch, skill_version mismatch, blocked/failed without block_reason), the dispatcher MUST mark the IID `blocked` with the corresponding `block_reason` and write that to the state files. Do NOT fabricate a "successful" reply on the subagent's behalf.

On failure:

- Per-IID failure → mark that IID `blocked` (retryable) or `failed` (retry-exhausted) per Blocked Skip-and-Retry; persist; continue with later IIDs.
- Tick-level failure (lock, auth, reconciliation evidence missing, ensure_labels broken, etc.) → return a one-line failure summary; do not early-return as "completed".

---

## Concurrency Policy (Dispatcher-Specific)

Universal contract (cap = `max_concurrent_subagents`, same-IID never parallel, bounded batches, wait-for-whole-batch, no fire-and-forget): [`SOUL.md`](../../SOUL.md) §Subagent Concurrency Policy. Dispatcher-specific operational details:

- **Batch shape.** Pick at most `max_concurrent_subagents` distinct IIDs (backlog-first, then fresh). Allocate attempt numbers SEQUENTIALLY (`scripts/allocate_attempt.sh` per IID, one fresh Bash exec per call). Run per-IID prep (Phase 4) for each batch member. Phase 5 spawns the surviving batch as parallel `sessions_spawn` calls in a SINGLE tool-call block. With `max_concurrent_subagents=1` this degenerates to one spawn per block — legacy serial behavior.
- **Spawn payload.** Each `sessions_spawn` call sends a fully-rendered fixed-format string built from [`references/executor_prompt.md`](references/executor_prompt.md). The rendered string is the entire spawn payload — no extra env-var injection at the OpenClaw layer, no skill load on the subagent side. Set `runTimeoutSeconds=3600`, `cleanup="keep"`. If the trigger supplied `--model` (reserved; not currently a trigger field), forward it.
- **Spawn completion contract.** A spawn meets this contract only when it is a blocking spawn that returns the subagent's terminal compact JSON reply (see `references/state_schema.md` §Compact Subagent Reply). A `status=accepted`, `runId`, `childSessionKey`, session id, thread id, or "created" acknowledgement WITHOUT the terminal compact JSON is NOT a terminal subagent reply. If the runtime returns only launch identifiers or reports that the current channel cannot wait for child sessions, treat the spawn/wait as failed for this tick. Do NOT report "batch in flight" as complete, do NOT increment quota, and do NOT drain `active_issue_iids` or release the batch's UI accounts on the assumption that detached child sessions are running.
- **Subagent identity is the `iid` field of the compact JSON, not the runtime session name.** The dispatcher SHOULD request the deterministic session name `issue-<project>-<iid>` when the runtime supports it (it makes session-name dedup a free structural guarantee). When the channel does not support thread-bound named sessions (e.g., webchat returns `errorCode=thread_required`), the dispatcher MAY fall back to anonymous subagents (`mode="run"` or equivalent) AS LONG AS each anonymous spawn still synchronously returns a terminal compact JSON reply. The "same IID never runs twice in parallel" guarantee then comes from `active_issue_iids` bookkeeping (Phase 4 step 5 persists the IID before spawn, Phase 6 drains it after the reply); the "match reply to dispatched IID" guarantee comes from Phase 6 validation rule 2 (`reply.iid == dispatched.iid AND reply.attempt_number == dispatched.attempt_number`). A reply whose `iid` does not match any dispatched IID in this batch is rejected by Phase 6 (synthetic blocked classification). Anonymous spawns that return only launch acknowledgements (no terminal compact JSON) are still spawn failures.
- **Time budget is checked between batches, not within a batch.** Once a batch is spawned, the dispatcher commits to waiting for all members; `max_runtime_minutes` is checked at the top of the next batch loop iteration. A slow IID in a batch can stall faster IIDs in the same batch — explicit trade-off for predictable time-budget accounting.
- **No mid-batch top-up.** The dispatcher MUST NOT spawn a replacement subagent when a single IID in the batch returns early. Wait for the whole batch, complete Phase 6 for all members, then form a fresh one. UI account safety relies on this rule.

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
4. **Allocation is per-batch and ephemeral.** The dispatcher binds one account to each IID in the batch, in iteration order (`account[k]` to the `k`-th IID). The pair `(UI_ACCOUNT, UI_PASSWORD)` is then passed to `scripts/build_prompt.sh` for that IID as env vars; the script appends the credentials to the Claude Code prompt's `# Working environment` section with an explicit override note. After the whole batch returns terminal subagent replies (Phase 6), the accounts implicitly return to the pool. There is no persisted allocation table — the synchronous per-batch wait contract guarantees that no two batches are in flight at once. If the runtime only returns `accepted` / `runId`, the account is still occupied and the spawn/wait contract has failed.
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

Each issue uses its own subagent. The **logical** dedicated name is `issue-<project>-<iid>`. The **runtime** session name may be that exact string (when the runtime / channel supports thread-bound named sessions) or an anonymous key like `agent:<name>:subagent:<uuid>` (when the channel does not). Either is acceptable as long as the synchronous compact JSON reply contract holds — see Concurrency Policy "Subagent identity" above.

1. Never reuse a subagent run for a different issue. (The rendered prompt embeds the IID; reuse is structurally impossible because the work order is per-IID.)
2. The dispatcher creates a fresh subagent for each spawn. Resume of a prior subagent is not part of this contract.
3. The dispatcher sends each subagent the rendered `references/executor_prompt.md` string as the entire `sessions_spawn` payload. There is no separate trigger envelope — the rendered prompt IS the work order.
4. **`active_issue_iids` is updated atomically per batch and is the structural guarantee against same-IID parallelism.** Before spawning a batch (start of Phase 5), append every IID in the batch to `active_issue_iids` and persist `campaign_state.json`. After Phase 6 has fully processed every batch member, drain the IIDs (terminal IIDs go to the appropriate completed/blocked/failed list; `in_progress` returns to backlog) and persist again. The list MUST never exceed `max_concurrent_subagents` entries. Launch acknowledgements such as `accepted`, `runId`, or `childSessionKey` (without compact JSON) are not a reason to drain this list. **The dispatcher MUST NOT spawn a subagent for an IID that is already in `active_issue_iids`** — this is the rule that replaces the old session-name dedup.
5. **No mid-batch top-up.** The dispatcher MUST NOT spawn a replacement subagent when a single IID in the batch returns early. Wait for the whole batch (Phase 5 → Phase 6 for all members), then form a fresh one.

---

## Per-Exec Env Contract (Dispatcher Minimum Vars)

Universal frame: [`SOUL.md`](../../SOUL.md) §Per-Exec Env Contract. Each Bash exec runs in a fresh shell; export the minimum on the same line.

Dispatcher's bash exec minimum (varies by script):

- Always: `PROJECT`, `GROUP`, `GITLAB_TOKEN`.
- `reconcile.sh`: also `MIN_IID`, `MAX_IID`.
- `allocate_attempt.sh`: also `IID`.
- `load_ui_accounts.sh`: optional `BATCH_SIZE`.
- `clone_or_pull.sh`: also `BRANCH`.
- `prepare_attempt.sh`, `build_prompt.sh`: also `ISSUE_IID`, `ATTEMPT_NUMBER`, `BRANCH`, `DEV_BRANCH`, `HULAT_DIR`, `ISSUE_MODE` (and for `build_prompt.sh`: `UI_ACCOUNT`, `UI_PASSWORD`).
- `set_issue_label.sh`, `ensure_labels.sh`: also `ISSUE_IID` (label.sh only).

Recommended pattern:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat GROUP=claw_gitlab GITLAB_TOKEN=<token> \
ISSUE_IID=14 ATTEMPT_NUMBER=3 BRANCH=master DEV_BRANCH=dev HULAT_DIR=/data/openclaw/bu_data/px_hulat \
ISSUE_MODE=fresh \
bash scripts/<script>.sh
```

The script self-bootstraps via `env_paths.sh`: derives paths (dispatcher and per-issue layers when `ISSUE_IID` is set), runs glab auth, computes `PROJECT_FULL` / `PROJECT_URI`.

---

## Working Directory

See [`SOUL.md`](../../SOUL.md) §Working Directory. The skill directory for THIS skill is the directory containing this SKILL.md (e.g. `<workspace>/skills/gitlab_issue_campaign_dispatcher/`). Run `cd "${SKILL_DIR}"` ONCE per session before any `bash scripts/...` invocation.

---

## Dispatcher Algorithm (Phase 1 → Phase 6)

Run on every scheduled wake-up. When a step below says `bash scripts/X.sh`, that is shorthand for the script action — in an actual OpenClaw Bash tool call, prefix the command with the minimum env vars from the Per-Exec Env Contract plus any script-specific vars in the same exec. Never rely on exports from a previous Bash tool call.

### Phase 1 — Parse

1. **Bootstrap.**
   - `cd ${SKILL_DIR}` — see "Working Directory" above; mandatory before any relative `scripts/...` invocation.
   - Acquire the flock above.
   - If the lock cannot be acquired, return a one-line `"lock_held"` summary and exit 0.
2. **Load + override campaign state.**
   - Read `${CAMPAIGN_STATE_FILE}`, or initialize using fresh-init values from `references/state_schema.md` if absent.
   - Apply schema migration if the on-disk file uses the legacy scalar `active_issue_iid` / `active_issue_session` — see `references/state_schema.md` "Schema migration" for the rule. Default `max_concurrent_subagents` to `1` if missing.
   - Apply trigger-input override: overwrite `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, and `max_concurrent_subagents` with the trigger values. When the trigger omits `max_concurrent_subagents`, default it to `1` for the tick AND persist that default.
   - Persist.

### Phase 2 — Reconcile (mandatory, always runs)

1. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> MIN_IID=... MAX_IID=... bash scripts/reconcile.sh`.
2. Apply disk cache correction per the Source-of-Truth Policy above.
3. Record the evidence file path into `campaign_state.json.last_reconcile_evidence`.

If `reconcile.sh` fails or no evidence file is produced, abort the tick with `"reconcile_failed"`. Do NOT early-return as completed.

### Phase 3 — Eligibility + tick-level prep

1. **Tick-level prep — once per tick, BEFORE the batch loop.**
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> bash scripts/ensure_labels.sh` — idempotent; creates the seven workflow labels if missing. Failure → tick-level `"ensure_labels_failed"` summary and stop.
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> BRANCH=<branch> bash scripts/clone_or_pull.sh` — keeps the main repo's refs current. Failure → tick-level `"clone_or_pull_failed"` summary and stop.
2. **Early-return only if allowed.** Permitted iff:
   - the evidence file from this tick exists
   - every IID in range has `is_done_on_gitlab == true` in it
   - every IID in range has `needs_continue == false` in it
   - `unfinished_iids` is empty and `campaign_status = completed`
3. `quota_completed_this_tick = 0`; record `tick_start_time`.

The Phase 3 → Phase 6 loop runs while quota and time budget remain. Each iteration produces one batch.

### Phase 4 — Per-IID Prep

For each batch iteration:

1. **Check time budget at the TOP of the iteration**, before forming a new batch. If `now - tick_start_time >= max_runtime_minutes`, break out of the loop (jump to the post-loop cleanup at the end).
2. **Form the next batch.** Compute `batch_size = min(max_concurrent_subagents, remaining_quota, remaining_eligible_iids)`. Pick `batch_size` distinct IIDs in the standard order: lowest-IID eligible backlog items first, then fresh IIDs from `next_new_issue_iid` upward. If `batch_size == 0`, break out of the loop.
3. **Allocate attempt numbers SEQUENTIALLY.** For each IID in the batch, run `IID=<iid> bash scripts/allocate_attempt.sh` in its own Bash exec, capturing the printed number `N_iid`.
4. **Allocate UI accounts for the batch.** Run `BATCH_SIZE=<batch_size> bash scripts/load_ui_accounts.sh` in a single Bash exec, capturing exactly `batch_size` lines of `user:pass` form. Bind `account[k]` to the `k`-th IID of the batch (k=0..batch_size-1). On any non-zero exit code (10/11/12/13), abort the tick.
5. **Update `active_issue_iids` + persist.** Append every IID in the batch to `campaign_state.json.active_issue_iids` (and the logical names `issue-<project>-<iid>` to `active_issue_sessions` for human readability). Persist before any glab mutation so a crash mid-prep leaves an accurate cache. **This persist is the structural guarantee that another tick / another orchestrator instance does not double-spawn the same IID** — see §Per-Issue Subagent Rules.
6. **Per-IID prep.** For each IID in the batch (sequentially or in parallel — preps are independent except for the shared `repo.lock` inside `prepare_attempt.sh`):
   1. Resolve `ISSUE_MODE` for this IID:
      - if reconciliation marked the IID `needs_continue == true`, OR per-issue state has `mode="continue"`, set `ISSUE_MODE=continue`
      - else `ISSUE_MODE=fresh`
   2. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> BRANCH=<branch> DEV_BRANCH=<dev_branch> HULAT_DIR=<hulat_dir> ISSUE_MODE=<mode> bash scripts/prepare_attempt.sh`. Capture `mode_actual` (line 1) and `LOCAL_ATTEMPT_BRANCH` (line 2). If `mode_actual=fresh` while `ISSUE_MODE=continue` was requested, record `mode_downgraded_from="continue"` later in the attempt state.
   3. Read the live issue title, URL, and labels via `glab api projects/${PROJECT_URI}/issues/${ISSUE_IID}` so the dispatcher can substitute `{ISSUE_TITLE}` / `{ISSUE_TITLE_QUOTED}` / `{ISSUE_URL}` / `{ISSUE_LABELS}` / `{ISSUE_BODY}` (truncated to ≤ 4 KB) into the executor prompt.
   4. **Transition to `doing`.** Use `scripts/set_issue_label.sh`:
      - fresh: remove `todo`, `blocked`, `done`, `pr` (each in its own exec; removes are idempotent), then add `doing`.
      - continue: remove `continue`, `blocked`, `done`, `pr`, then add `doing`.
      The dispatcher MUST NOT use `-f labels=...` (full-set overwrite) — it would wipe manually-added labels.
   5. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> BRANCH=<branch> DEV_BRANCH=<dev_branch> HULAT_DIR=<hulat_dir> ISSUE_MODE=<mode_actual> UI_ACCOUNT=<user> UI_PASSWORD=<pass> bash scripts/build_prompt.sh`. Writes `${LOG_DIR}/prompt.txt` with the issue body, working environment, and UI-account override block. Capture stderr (`CONTINUE_MODE_NO_REVIEWER_COMMENTS`, `CONTINUE_MODE_PRIOR_ATTEMPT_COUNT`) for the attempt state.
   6. **Initialize state files.** Write/refresh `${ATTEMPT_STATE_FILE}` with `{iid, attempt_number, attempt_started_at, mode_requested, mode_actual, mode_downgraded_from, no_reviewer_comments, prior_attempt_count, local_branch, log_dir, status:"in_progress", skill_version}`. Write/refresh `${ISSUE_STATE_FILE}` with `{iid, session, status:"in_progress", mode:<mode_actual>, attempts_total:<N_iid>, latest_attempt_number:<N_iid>, latest_attempt_dir, retry_count:<from prior>, skill_version, updated_at}`.
   7. **Render the executor prompt.** Substitute every `{...}` placeholder in `references/executor_prompt.md` with the per-IID values; verify no unsubstituted placeholders remain. If render fails (missing variable, unsubstituted token), mark the IID `blocked` with `block_reason="prompt template render incomplete: <name>"` and skip this IID for the batch.

   If any sub-step fails for an IID, mark that IID `blocked` with `block_reason="dispatcher prep failed: <verbatim error>"` and skip it for the batch — but DO continue prep for the OTHER batch members. The UI account allocated to a dropped IID returns to the pool (no persistence).

### Phase 5 — Concurrent Spawn

**Spawn the surviving batch in a SINGLE tool-call block.** Issue one `sessions_spawn` per IID whose Phase 4 prep succeeded, all in the same parallel block. The entire payload is the rendered subagent prompt. With `max_concurrent_subagents=1` this block contains exactly one `sessions_spawn` call.

**Spawn shape:**
- **Preferred:** target the deterministic session name `issue-<project>-<iid>` (`mode="session"` or runtime equivalent). This gives free session-name dedup AND preserves attempt logs across resumes.
- **Fallback (channel-driven):** if the runtime rejects deterministic names on the current channel (e.g., webchat `errorCode=thread_required`), the dispatcher MAY use anonymous spawns (`mode="run"` or runtime equivalent). The "same IID never runs twice" guarantee then comes from `active_issue_iids` bookkeeping (Phase 4 step 5) and Phase 6 reply matching by `iid`. Anonymous spawns MUST still synchronously return a terminal compact JSON reply — push-only / fire-and-forget remains forbidden.

The dispatcher waits for ALL spawns in the block to return terminal subagent compact JSON replies. A push-based `accepted` / `runId` response WITHOUT compact JSON is a spawn/wait failure — see Concurrency Policy above.

If `sessions_spawn` for an individual IID fails to return a terminal compact reply (timeout, runtime error, push-only ack, channel-rejects-named-and-anonymous-also-fails), record that IID's outcome as a synthetic blocked reply: `{"iid":<iid>, "attempt_number":<N>, "status":"blocked", "block_reason":"sessions_spawn did not return terminal reply: <reason>", "skill_version":"<this version>"}`. Phase 6 then processes it the same way as a real reply.

**Reply-to-IID matching (when using anonymous spawns):** the parallel `sessions_spawn` block returns N replies; the dispatcher matches each reply to its dispatched IID by parsing the `iid` field of the compact JSON (Phase 6 validation rule 2). The runtime's order or session-key labels are not load-bearing — `iid` is. A reply whose `iid` does not match any dispatched IID in this batch is a Phase 6 validation failure (synthetic blocked classification: `block_reason="reply iid <x> does not match any dispatched IID in batch"`).

### Phase 6 — Follow-up (main agent owns ALL terminal bookkeeping)

For each IID in the batch, in any order:

1. **Validate the compact reply** per `references/state_schema.md` §Compact Subagent Reply → "Dispatcher-side validation". Validation failures produce a synthetic blocked classification (with the appropriate `block_reason`) — do not silently accept malformed replies.
2. **Write the terminal state files** per `references/state_schema.md` §Phase 6 Write Mapping. The dispatcher writes BOTH `${ATTEMPT_STATE_FILE}` and `${ISSUE_STATE_FILE}` from the compact reply. The subagent does not touch them.
3. **Promote `blocked → failed` if retry budget exhausted.** Increment `retry_count` first if `status in {blocked, failed}`. If `retry_count > blocked_retry_limit`, set `status=failed` in both state files and add to `failed_iids`.
4. **Classify into `campaign_state.json` lists.**
   - `done` / `no_changes`: add to `completed_iids`; remove from `unfinished_iids`/`blocked_iids`/`failed_iids`. Increment `quota_completed_this_tick`.
   - `blocked` (not promoted): add to `blocked_iids` with the cooldown-tracking semantics per Blocked Skip-and-Retry; remove from `completed_iids`/`failed_iids`; keep in `unfinished_iids`.
   - `failed` (terminal or promoted): add to `failed_iids`; remove from `unfinished_iids`/`blocked_iids`/`completed_iids`.
5. **Drain `active_issue_iids` for the just-finished batch.** Remove every IID in this batch from `active_issue_iids` and `active_issue_sessions`. Persist `campaign_state.json` before the next batch iteration.
6. **Optional notify.** If a notification channel is configured (see future trigger field; currently not part of the trigger), post a one-line per-IID summary built from the compact reply: `"#<iid> <status> mr=<merge_request_url> wiki=<wiki_url> mr_action=<mr_action>"`. Skip silently if no channel.

After Phase 6 for the batch is complete, loop back to Phase 4 to form the next batch. Stop conditions:
- `quota_completed_this_tick >= hourly_issue_quota` → break.
- Time budget exhausted (`now - tick_start_time >= max_runtime_minutes`) → break (checked at top of the next Phase 4 iteration).
- `batch_size == 0` (no eligible IID for the next batch) → break.

### Post-loop cleanup

1. Update `next_new_issue_iid` if fresh issues were introduced.
2. If every IID in `[issue_min_iid, issue_max_iid]` is terminal (per the latest Phase 2 evidence), set `campaign_status = completed`.
3. Persist `campaign_state.json`.
4. Return the compact chat summary (see Chat Output Policy below).

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

Return a single compact JSON summary, e.g.:

```json
{
  "skill_version": "2026-05-06.6",
  "campaign_status": "running",
  "active_issue_iids": [],
  "active_issue_sessions": [],
  "max_concurrent_subagents": 2,
  "ui_account_pool_size": 4,
  "unfinished_iids": [9, 10, 14],
  "next_new_issue_iid": 19,
  "quota_completed_this_tick": 3,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/openclaw_work/<project>/openclaw_log/dispatcher/reconcile-<ts>.json",
  "tick_outcome_per_iid": {
    "14": "done",
    "15": "blocked: subagent reply skill_version mismatch"
  }
}
```

Between batches, while a batch is in flight (Phase 5), `active_issue_iids` reflects the IIDs currently in flight. After Phase 6 drains the batch, the list is empty before the next Phase 4 iteration.

`tick_outcome_per_iid` is optional but recommended — it gives the operator a per-IID summary of this tick at a glance. Pull the values from the validated compact replies.

Never paste full logs, full diffs, or long issue bodies into chat.
