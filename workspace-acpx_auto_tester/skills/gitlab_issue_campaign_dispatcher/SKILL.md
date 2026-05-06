---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-05-06.1] Run a recurring scheduled GitLab issue campaign as a single thick dispatcher: clone/pull, ensure labels, allocate attempt numbers and UI accounts, prepare each issue's worktree, build each issue's Claude Code prompt, transition labels to `doing`, then spawn one dedicated session per issue with a fully-rendered self-contained prompt. The subagent does NOT load this SKILL — it runs acpx + commit/push/wiki/MR/labels/summarize from the rendered prompt and returns a compact JSON. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, synchronous bounded batches, per-batch UI-account allocation from a deployment-pinned pool, persistent disk state, and compact dispatcher chat output."
allowed-tools: Bash, Read, Write, Edit, sessions_history, sessions_spawn
---

# GitLab Issue Campaign Dispatcher Skill

**SKILL_VERSION: 2026-05-06.1**

On every wake-up, the dispatcher MUST echo the literal string `SKILL_VERSION=2026-05-06.1` in its compact chat summary (add a `"skill_version"` field to the returned JSON). This lets the operator verify which version of the skill is actually loaded.

## Single-skill model (read first)

This workspace has exactly **one SKILL** (this file). The dispatcher is responsible for ALL preparation up to the moment of spawn. The dedicated per-issue session ("subagent") receives a fully-rendered self-contained prompt as the entire `sessions_spawn` payload and runs the post-acpx workflow (acpx → stage/guard → commit/push → post-push verify → upload Wiki → label transitions → MR → summarize). The subagent NEVER loads this SKILL, NEVER reads SOUL.md / AGENTS.md, and NEVER fetches additional rules from disk.

The rendered subagent prompt is built from [`references/executor_prompt.md`](references/executor_prompt.md). All scripts the subagent invokes live in this skill's `scripts/` directory and are called by absolute path.

## Companion files

This SKILL is intentionally short. Detailed bash and fixed reference data live in sibling folders:

- `scripts/env_paths.sh` — single bootstrap for every script (dispatcher AND subagent paths). SOURCE it.
- `scripts/glab_auth.sh` — bootstraps `glab` CLI; prints `GITLAB_HOST`. Reads the deployment pin at `<workspace>/config/gitlab.env`.
- `scripts/reconcile.sh` — queries GitLab for the IID range and writes the evidence file.
- `scripts/allocate_attempt.sh` — atomically allocates the next attempt number for an IID; the dispatcher MUST call this once per IID per spawn.
- `scripts/load_ui_accounts.sh` — read the deployment-pinned UI test account pool (`<workspace>/config/ui_accounts.env`); used at the top of every batch to allocate one distinct account per IID.
- `scripts/clone_or_pull.sh` — keep the main repo's refs current. Run once per tick before the batch loop.
- `scripts/ensure_labels.sh` — make sure the seven workflow labels (`todo doing pr done blocked failed continue`) exist. Run once per tick after auth.
- `scripts/prepare_attempt.sh` — replace the issue's worktree, set up the `hulat` symlink and `.claude` runtime config, write `.git/info/exclude`, return `mode_actual` and `LOCAL_ATTEMPT_BRANCH`.
- `scripts/build_prompt.sh` — build the Claude Code prompt at `${LOG_DIR}/prompt.txt` (UI account injected; continue-mode summaries + reviewer comments included).
- `scripts/set_issue_label.sh` — add or remove a single label on the issue (used by both dispatcher and subagent — preserves manually-added labels).
- `scripts/stage_and_guard.sh`, `scripts/commit_and_push.sh`, `scripts/post_push_verify.sh`, `scripts/upload_attempt_artifacts.sh`, `scripts/create_mr.sh`, `scripts/summarize_attempt.sh` — invoked by the subagent (by absolute path) per `references/executor_prompt.md`.
- `references/executor_prompt.md` — the rendered template the dispatcher ships to each subagent.
- `references/paths.md` — full path layout (dispatcher and per-issue) and rules.
- `references/trigger_command.md` — the trigger spec and override rules.
- `references/state_schema.md` — `campaign_state.json`, `issue-<iid>/state.json`, and `issue-<iid>/attempt_state.json` schemas.
- `references/glab_commands.md` — exhaustive list of allowed `glab` invocations across the workspace.
- `references/label_lifecycle.md` — workflow label transitions and how to perform them.
- `references/continue_mode.md` — reviewer contract for the `continue` label and the prompt template injected in continue mode.

When in doubt about a path / schema / command, READ the matching reference file. Do NOT reconstruct content from memory.

---

## No-Fallback (Dispatcher-Specific)

Universal rules: [`SOUL.md`](../../SOUL.md) §Shared Operational Policies → No-Fallback. Dispatcher-specific additions:

1. If `flock` cannot acquire the lock, the dispatcher MUST NOT bypass it (no `rm`-the-lockfile, no `--no-lock`, no second-attempt loops). Return a one-line status summary and exit.
2. If `sessions_spawn` for an issue session fails or times out, the dispatcher MUST NOT run the subagent's logic inline in the dispatcher session, spawn a non-dedicated session as a substitute, or retry by spawning a different session name. Mark the IID `blocked` with an accurate `block_reason` and continue per Blocked Skip-and-Retry.
3. If the runtime reports that the current channel cannot wait for child sessions, or if it returns only a push-based launch acknowledgement, the dispatcher MUST NOT switch to `mode=run`, `--no-wait`, anonymous subagents, or any other fire-and-forget fallback. Record spawn/wait as unsupported for the affected IID or tick.
4. If a per-IID prep step fails (clone_or_pull, prepare_attempt, build_prompt, set_issue_label for `doing`, etc.), the dispatcher MUST NOT spawn that IID with a partial / improvised setup. Mark the IID `blocked` with the verbatim error as `block_reason` and continue with the OTHER batch members whose prep succeeded.
5. If `ensure_labels.sh` fails, the dispatcher MUST treat that as a tick-level failure (no batch can run without workflow labels). Return a one-line summary; do NOT skip the call.

On failure:

- Per-IID failure → mark that IID `blocked` (retryable) or `failed` (retry-exhausted) per Blocked Skip-and-Retry; persist; continue with later IIDs.
- Tick-level failure (lock, auth, reconciliation evidence missing, ensure_labels broken, etc.) → return a one-line failure summary; do not early-return as "completed".

---

## Concurrency Policy (Dispatcher-Specific)

Universal contract (cap = `max_concurrent_subagents`, same-IID never parallel, bounded batches, wait-for-whole-batch, no fire-and-forget): [`SOUL.md`](../../SOUL.md) §Subagent Concurrency Policy. Dispatcher-specific operational details:

- **Batch shape.** Pick at most `max_concurrent_subagents` distinct IIDs (backlog-first, then fresh). Allocate attempt numbers SEQUENTIALLY (`scripts/allocate_attempt.sh` per IID, one fresh Bash exec per call). Run per-IID prep (prepare_attempt, build_prompt, label transitions, state init) for each batch member. Spawn the batch as parallel `sessions_spawn` calls in a SINGLE tool-call block. With `max_concurrent_subagents=1` this degenerates to one spawn per block — legacy serial behavior.
- **Spawn payload.** Each `sessions_spawn` call sends a fully-rendered string built from [`references/executor_prompt.md`](references/executor_prompt.md). The rendered string is the entire spawn payload — no extra env-var injection at the OpenClaw layer, no skill load on the subagent side. Set `runTimeoutSeconds=3600`, `cleanup="keep"`. If the trigger supplied `--model` (reserved; not currently a trigger field), forward it.
- **Spawn completion contract.** A spawn meets this contract only when it is a blocking dedicated-session spawn that returns the subagent's terminal compact reply (`done`, `blocked`, `failed`, or `no_changes`). A `status=accepted`, `runId`, `childSessionKey`, session id, thread id, or "created" acknowledgement is NOT a terminal subagent reply. If the runtime returns only launch identifiers or reports that the current channel cannot wait for child sessions, treat the spawn/wait as failed for this tick. Do NOT report "batch in flight" as complete, do NOT increment quota, and do NOT drain `active_issue_iids` or release the batch's UI accounts on the assumption that detached child sessions are running.
- **Deterministic session names only.** Anonymous keys like `agent:<name>:subagent:<uuid>` are NOT dedicated issue sessions. A successful issue spawn MUST target / return `issue-<project>-<iid>` together with the subagent's terminal reply. If the runtime creates an anonymous subagent instead, treat it as a spawn failure for that IID.
- **Time budget is checked between batches, not within a batch.** Once a batch is spawned, the dispatcher commits to waiting for all members; `max_runtime_minutes` is checked at the top of the next batch loop iteration. A slow IID in a batch can stall faster IIDs in the same batch — explicit trade-off for predictable time-budget accounting.

---

## UI Account Allocation Policy (READ FIRST — HARD RULE)

The system under test is a UI / web app. When the same UI account logs in twice, the older session is logged out. Two concurrent subagents that share an account therefore continuously kick each other out — the work product is unreliable, and the issue cannot complete.

The dispatcher MUST therefore allocate a **distinct UI account per IID** for every concurrent batch:

1. The pool of available accounts is pinned at deployment time in `<workspace>/config/ui_accounts.env`. The trigger does NOT carry account credentials.
2. Before spawning each batch, the dispatcher runs `BATCH_SIZE=<n> bash scripts/load_ui_accounts.sh` (where `n` is the just-computed batch size). The script:
   - prints `n` accounts in pool-file order, one `user:pass` per line, and exits 0; OR
   - exits 10 if the pool file is missing (deployment incomplete);
   - exits 11 if the pool is empty;
   - exits 12 if a pool line is malformed;
   - exits 13 if the pool is smaller than `BATCH_SIZE`.
3. **Pool-too-small is a tick-level failure.** If `load_ui_accounts.sh` exits 13, the dispatcher MUST abort the tick with a one-line summary (`"ui_account_pool_too_small: pool=<size> batch=<n>"`). It MUST NOT shrink the batch, retry with a smaller `max_concurrent_subagents`, or share an account between IIDs. The operator's options are: enlarge the pool in `<workspace>/config/ui_accounts.env`, or lower `max_concurrent_subagents` in the trigger.
4. **Allocation is per-batch and ephemeral.** The dispatcher binds one account to each IID in the batch, in iteration order (`account[k]` to the `k`-th IID). The pair `(UI_ACCOUNT, UI_PASSWORD)` is then passed to `scripts/build_prompt.sh` for that IID as env vars; the script appends the credentials to the Claude Code prompt's `# Working environment` section with an explicit override note. After the whole batch returns terminal subagent replies, the accounts implicitly return to the pool. There is no persisted allocation table — the synchronous per-batch wait contract guarantees that no two batches are in flight at once. If the runtime only returns `accepted` / `runId`, the account is still occupied and the spawn/wait contract has failed.
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

1. On every wake-up, BEFORE any "already done" / "already completed" / "skip this IID" / "early return" decision, run `scripts/reconcile.sh` for the full `[issue_min_iid, issue_max_iid]` range. The script writes `${DISPATCHER_LOG_DIR}/reconcile-<ts>.json`. **No evidence file = reconciliation didn't happen = the tick is failed; do not early-return.**
2. The dispatcher MUST NOT use `campaign_state.json.completed_iids`, `campaign_state.json.campaign_status`, or any per-issue `issue-<iid>/state.json.status` to decide an IID is finished. Those are caches.
3. Ground truth per IID comes from the evidence file. Key signals:
   - `is_closed_on_gitlab` ⇔ live GitLab state is literal `closed`. Closed issues are hard terminal and MUST NEVER be scheduled, even if they have `continue` or lack `done`+`pr`.
   - `has_done_pr` ⇔ live GitLab labels contain both literal `done` and literal `pr`.
   - `is_done_on_gitlab` ⇔ `is_closed_on_gitlab == true` OR `has_done_pr == true`. This backward-compatible terminal-skip field is what the dispatcher uses for "do not schedule".
   - `needs_continue` ⇔ the issue is opened and live GitLab labels contain literal `continue`. This is set by a human reviewer who has noticed that a previous `done` + `pr` result was incorrect (Claude Code returned but didn't actually finish the work) and wants the agent to resume on the existing work branch. `continue` wins if it is present alongside `done` and/or `pr`, but only while the issue is opened.
   - `user_reopened` ⇔ the issue is opened, does not have the completed pair `done`+`pr`, and none of `failed`, `blocked`, or `continue` are present in live labels (the issue was bounced back to `todo` / `doing` from scratch, or was left in the pre-MR `done`-only intermediate state).
4. **Disk cache correction is mandatory** when they disagree:
   - If `is_closed_on_gitlab == true`:
     - remove IID from `unfinished_iids`, `blocked_iids`, `failed_iids`, and `active_issue_iids` (and the corresponding session from `active_issue_sessions`) if present
     - add to `completed_iids` as a terminal skip cache entry
     - update the per-issue state file (`$(issue_state_file_for <iid>)` -> `${ISSUES_ROOT}/issue-<iid>/state.json`) only if needed to prevent retry: write `status=done`, `mode="fresh"`, and leave `attempts_total` untouched
     - do NOT honor `continue` on a closed issue
     - persist `campaign_state.json`
   - Else if `needs_continue == true`:
     - remove IID from `completed_iids` / `failed_iids`
     - add to `unfinished_iids`
     - update the per-issue state file: write `status=pending`, `mode="continue"`, leave `attempts_total` untouched (the dispatcher increments it before the next spawn). Do NOT delete the issue subtree; the dispatcher's `prepare_attempt.sh` replaces `${WORKTREE_DIR}` and writes the next attempt's logs under a new `${LOG_DIR}`.
     - remove this IID from `active_issue_iids` (and the corresponding session from `active_issue_sessions`) if present
     - force `campaign_status = running`
     - persist `campaign_state.json`
   - Else if disk says finished but `user_reopened == true`:
     - same as above, but the per-issue state gets `mode="fresh"` (default)
   - If disk says unfinished but `is_done_on_gitlab == true` (and `needs_continue == false`), mark it finished on disk and skip. This includes closed issues.
5. An "already completed" reply is allowed only when the evidence file from this tick exists AND every IID in range has `is_done_on_gitlab == true` AND `needs_continue == false` in it.

In short: **trust the evidence file, not the JSON cache. If you didn't run `reconcile.sh` this tick, you have no right to say anything is done.**

---

## Inputs and Trigger Command

See `references/trigger_command.md` for the full trigger spec, required fields, expected fixed values, and the trigger-input override rule.

Key requirements:

- All scalar trigger inputs (`issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`) are authoritative for this tick. Overwrite the disk copy in `campaign_state.json` before running the algorithm.
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

## Per-Issue Session Rules

Each issue uses its own dedicated session named `issue-<project>-<iid>`.

1. Never reuse an issue session for a different issue.
2. The dispatcher creates the session if it doesn't exist; otherwise resumes it.
3. The dispatcher sends each subagent the rendered `references/executor_prompt.md` string as the entire `sessions_spawn` payload. There is no separate "RUN_SINGLE_ISSUE_SESSION" trigger envelope — the rendered prompt IS the work order.
4. **`active_issue_iids` is updated atomically per batch.** Before spawning a batch, append every IID in the batch to `active_issue_iids` and persist `campaign_state.json`. Only after the whole batch returns terminal subagent replies and per-issue states are re-read, remove every batch member (terminal IIDs go to the appropriate completed/blocked/failed list; `in_progress`/budget-exhausted IIDs go back to `unfinished_iids`) and persist again. The list MUST never exceed `max_concurrent_subagents` entries. Launch acknowledgements such as `accepted`, `runId`, or `childSessionKey` are not a reason to drain this list.
5. **No mid-batch top-up.** The dispatcher MUST NOT spawn a replacement subagent when a single IID in the batch returns early. Wait for the whole batch, then form a fresh one.

Batch sizing, spawn semantics (parallel `sessions_spawn` in one tool-call block, what counts as a successful spawn), deterministic session names, and same-IID guarantees are in §Concurrency Policy above.

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

## Dispatcher Algorithm

Run on every scheduled wake-up.

When a step below says `bash scripts/X.sh`, that is shorthand for the script action. In an actual OpenClaw Bash tool call, prefix the command with the minimum env vars from the Per-Exec Env Contract plus any script-specific vars in the same exec. Never rely on exports from a previous Bash tool call.

1. **Bootstrap.**
   - `cd ${SKILL_DIR}` — see "Working Directory" above; mandatory before any relative `scripts/...` invocation.
   - If doing an explicit bootstrap check in the current shell, use the dispatcher minimum env contract:
     `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> source scripts/env_paths.sh`
     This authenticates glab and computes `PROJECT_FULL` / `PROJECT_URI`.
   - Acquire the flock above.
   - Do NOT call `scripts/glab_auth.sh` separately after `env_paths.sh`, and do NOT manually export `PROJECT_FULL` or `PROJECT_URI`. Every later `bash scripts/...` command is a fresh shell and must receive the minimum env vars; the target script will source `env_paths.sh` itself. If `env_paths.sh` / glab auth fails, abort the tick.
2. **Load + override campaign state.**
   - Read `${CAMPAIGN_STATE_FILE}`, or initialize using fresh-init values from `references/state_schema.md` if absent.
   - Apply schema migration if the on-disk file uses the legacy scalar `active_issue_iid` / `active_issue_session` — see `references/state_schema.md` "Schema migration" for the rule. Default `max_concurrent_subagents` to `1` if missing.
   - Apply trigger-input override: overwrite `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, and `max_concurrent_subagents` with the trigger values. When the trigger omits `max_concurrent_subagents`, default it to `1` for the tick AND persist that default.
   - Persist.
3. **Reconcile against GitLab — MANDATORY, ALWAYS RUNS.**
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> MIN_IID=... MAX_IID=... bash scripts/reconcile.sh`.
   - Apply disk cache correction per the policy above.
   - Record the evidence file path into `campaign_state.json.last_reconcile_evidence`.
4. **Tick-level prep — once per tick, BEFORE the batch loop.**
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> bash scripts/ensure_labels.sh` — idempotent; creates the seven workflow labels if missing. Failure → tick-level failure summary and stop.
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> BRANCH=<branch> bash scripts/clone_or_pull.sh` — keeps the main repo's refs current. Failure → tick-level failure summary and stop. (`prepare_attempt.sh` re-fetches defensively but the bulk fetch is cheaper here, once per tick.)
5. **Early-return only if allowed.** Permitted iff:
   - the evidence file from this tick exists
   - every IID in range has `is_done_on_gitlab == true` in it
   - every IID in range has `needs_continue == false` in it
   - `unfinished_iids` is empty and `campaign_status = completed`
   Otherwise continue.
6. `quota_completed_this_tick = 0`; record tick start time.
7. **Bounded-batch loop.** While quota AND time budget remain:
   1. **Check time budget at the TOP of the loop iteration**, before forming a new batch. If `now - tick_start_time >= max_runtime_minutes`, break out of the loop.
   2. **Form the next batch.** Compute `batch_size = min(max_concurrent_subagents, remaining_quota, remaining_eligible_iids)`. Pick `batch_size` distinct IIDs in the standard order: lowest-IID eligible backlog items first, then fresh IIDs from `next_new_issue_iid` upward. If `batch_size == 0`, break out of the loop.
   3. **Allocate attempt numbers SEQUENTIALLY.** For each IID in the batch, run `IID=<iid> bash scripts/allocate_attempt.sh` in its own Bash exec, capturing the printed number `N_iid`.
   4. **Allocate UI accounts for the batch.** Run `BATCH_SIZE=<batch_size> bash scripts/load_ui_accounts.sh` in a single Bash exec, capturing exactly `batch_size` lines of `user:pass` form. Bind `account[k]` to the `k`-th IID of the batch (k=0..batch_size-1). On any non-zero exit code, abort the tick.
   5. **Update `active_issue_iids` + persist.** Append every IID in the batch (and corresponding session names) to `campaign_state.json`. Persist before any glab mutation so a crash mid-prep leaves an accurate cache.
   6. **Per-IID prep.** For each IID in the batch (sequentially or in parallel — preps are independent; parallel runs may serialize on the workspace `repo.lock` inside `prepare_attempt.sh`):
      a. Resolve `ISSUE_MODE` for this IID:
         - if reconciliation marked the IID `needs_continue == true`, OR per-issue state has `mode="continue"`, set `ISSUE_MODE=continue`
         - else `ISSUE_MODE=fresh`
      b. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> BRANCH=<branch> DEV_BRANCH=<dev_branch> HULAT_DIR=<hulat_dir> ISSUE_MODE=<mode> bash scripts/prepare_attempt.sh`. Capture `mode_actual` (line 1) and `LOCAL_ATTEMPT_BRANCH` (line 2). If `mode_actual=fresh` while `ISSUE_MODE=continue` was requested, record `mode_downgraded_from="continue"` later in the attempt state.
      c. Read the live issue title via `glab api projects/${PROJECT_URI}/issues/${ISSUE_IID}` so the dispatcher can substitute `{ISSUE_TITLE}` / `{ISSUE_TITLE_QUOTED}` into the executor prompt and pass `ISSUE_TITLE=...` to scripts that need it. (`build_prompt.sh` re-fetches the same body internally; the small redundancy keeps the dispatcher's render path explicit.)
      d. **Transition to `doing`.** Use `scripts/set_issue_label.sh`:
         - fresh: remove `todo`, `blocked`, `done`, `pr` (each in its own exec; removes are idempotent), then add `doing`.
         - continue: remove `continue`, `blocked`, `done`, `pr`, then add `doing`.
         The dispatcher MUST NOT use `-f labels=...` (full-set overwrite) — it would wipe manually-added labels.
      e. `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> BRANCH=<branch> DEV_BRANCH=<dev_branch> HULAT_DIR=<hulat_dir> ISSUE_MODE=<mode_actual> UI_ACCOUNT=<user> UI_PASSWORD=<pass> bash scripts/build_prompt.sh`. This writes `${LOG_DIR}/prompt.txt` with the issue body, working environment, and UI-account override block. Capture stderr (`CONTINUE_MODE_NO_REVIEWER_COMMENTS`, `CONTINUE_MODE_PRIOR_ATTEMPT_COUNT`) for the attempt state.
      f. **Initialize state files.** Write/refresh `${ATTEMPT_STATE_FILE}` with `{iid, attempt_number, attempt_started_at, mode_requested, mode_actual, mode_downgraded_from, no_reviewer_comments, prior_attempt_count, local_branch, log_dir, status:"in_progress", skill_version}`. Write/refresh `${ISSUE_STATE_FILE}` with `{iid, session, status:"in_progress", mode:<mode_actual>, attempts_total:<N_iid>, latest_attempt_number:<N_iid>, latest_attempt_dir, retry_count (incremented from prior if this was a retry), skill_version, updated_at}`.
      g. **Render the executor prompt.** Substitute every `{...}` placeholder in `references/executor_prompt.md` with the per-IID values; verify no unsubstituted placeholders remain. If render fails (missing variable, unsubstituted token), mark the IID `blocked` with `block_reason="prompt template render incomplete: <name>"` and skip this IID for the batch.
      
      If any sub-step a–g fails for an IID, mark that IID `blocked` with `block_reason="dispatcher prep failed: <verbatim error>"` and skip it for the batch — but DO continue prep for the OTHER batch members. The UI account allocated to a dropped IID returns to the pool (no persistence).
   7. **Spawn the surviving batch in a SINGLE tool-call block.** Issue one `sessions_spawn` per IID whose prep succeeded, all in the same parallel block. Each spawn MUST target the exact dedicated session name `issue-<project>-<iid>`; the entire payload is the rendered subagent prompt. With `max_concurrent_subagents=1` this block contains exactly one `sessions_spawn` call. The dispatcher waits for ALL spawns in the block to return terminal subagent replies. A push-based `accepted` / `runId` response is a spawn/wait failure.
   8. **After the WHOLE batch returns terminal subagent replies**, for each IID in the batch:
      - Re-read `$(issue_state_file_for <iid>)` from disk.
      - If terminal (`done` / `no_changes` / `failed`): update the corresponding list (`completed_iids` / `failed_iids` etc.), increment `quota_completed_this_tick`.
      - If `blocked`: keep in backlog; will retry after cooldown per Blocked Skip-and-Retry.
      - If `in_progress` (the subagent returned but its work is not yet terminal — rare): keep as backlog for the next tick.
   9. **Drain `active_issue_iids` + persist.** Remove every IID in the just-finished batch from `active_issue_iids` and `active_issue_sessions`, then persist `campaign_state.json` before the next loop iteration.
8. Update `next_new_issue_iid` if fresh issues were introduced.
9. If every IID in `[issue_min_iid, issue_max_iid]` is terminal, set `campaign_status = completed`.
10. Persist `campaign_state.json` and return the compact chat summary.

Stop conditions (checked at the top of each batch iteration): `quota_completed_this_tick >= hourly_issue_quota`, time budget exhausted (`now - tick_start_time >= max_runtime_minutes`), or no eligible IID remains for the next batch.

---

## Blocked Skip-and-Retry

1. Blocked issues record `block_reason` in their per-issue state file.
2. A blocked issue is retryable only after `blocked_cooldown_ticks` ticks have elapsed since the last attempt.
3. If `retry_count > blocked_retry_limit`, the issue may be marked `failed`.
4. A blocked issue must not permanently block later issues from using remaining quota.

---

## Terminal Completion Policy

Successful MR creation plus both workflow labels (`done` and `pr`) being present is the terminal completion condition for a normal attempt. Separately, GitLab `state=closed` is a hard terminal skip condition: the dispatcher MUST NOT schedule a closed issue, even if `continue` is present or `done`/`pr` are absent. The subagent (per `references/executor_prompt.md`) changes `doing` to `done` after Wiki evidence is published, then adds `pr` after MR creation / rotation succeeds, and only then writes terminal `status=done`. For opened issues, the dispatcher MUST NOT schedule that issue again unless reconciliation finds `needs_continue == true` or `user_reopened == true` on GitLab. `continue` wins over cached `done` state and over an existing MR only while the issue is opened.

---

## Chat Output Policy

Return a single compact JSON summary, e.g.:

```json
{
  "skill_version": "2026-05-06.1",
  "campaign_status": "running",
  "active_issue_iids": [],
  "active_issue_sessions": [],
  "max_concurrent_subagents": 1,
  "ui_account_pool_size": 4,
  "unfinished_iids": [9, 10, 14],
  "next_new_issue_iid": 19,
  "quota_completed_this_tick": 3,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/openclaw_work/<project>/openclaw_log/dispatcher/reconcile-<ts>.json"
}
```

Between batches, while a batch is in flight, `active_issue_iids` reflects the IIDs currently in flight (e.g. `[14, 15]` when `max_concurrent_subagents=2`). After the batch returns and per-issue states are re-read, the list is drained back toward `[]` before the next batch is formed.

Never paste full logs, full diffs, or long issue bodies into chat.
