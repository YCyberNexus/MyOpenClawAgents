---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-05-06.3] Run a recurring scheduled GitLab issue campaign using a dispatcher/main session that prepares each issue environment before launching one prepared worker child per issue. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, gitlab-issues-style preflight/claim checks, async runtime completion callbacks, per-batch UI-account allocation from a deployment-pinned pool, persistent disk state, and compact dispatcher chat output."
allowed-tools: Bash, Read, Write, Edit, sessions_history, sessions_spawn
---

# GitLab Issue Campaign Dispatcher Skill

**SKILL_VERSION: 2026-05-06.3**

On every wake-up, the dispatcher MUST echo the literal string `SKILL_VERSION=2026-05-06.3` in its compact chat summary (add a `"skill_version"` field to the returned JSON). This lets the operator verify which version of the skill is actually loaded.

## Companion files

This SKILL is intentionally short. Detailed bash and fixed reference data live in sibling folders:

- `scripts/env_paths.sh` — populates path variables (SOURCE it, don't redefine).
- `scripts/glab_auth.sh` — bootstraps `glab` CLI; prints `GITLAB_HOST`.
- `scripts/reconcile.sh` — queries GitLab for the IID range and writes the evidence file.
- `scripts/clone_or_pull.sh` — dispatcher-owned repo clone/fetch/prune.
- `scripts/preflight_issue.sh` — gitlab-issues-style repo/auth/open-MR/remote-branch/claim check for one IID.
- `scripts/allocate_attempt.sh` — atomically allocates the next attempt number for an IID; the dispatcher MUST call this before every prepared-worker spawn and pass the result via `attempt_number=` in the trigger.
- `scripts/load_ui_accounts.sh` — read the deployment-pinned UI test account pool (`<workspace>/config/ui_accounts.env`); used at the top of every batch to allocate one distinct account per IID.
- `scripts/prepare_attempt.sh` — dispatcher-owned worktree preparation; replaces `${WORKTREE_DIR}`, links `hulat`, copies `.claude`, and writes git excludes.
- `scripts/build_prompt.sh` — dispatcher-owned prompt generation from the live issue, continue-mode notes, and UI account.
- `scripts/prepare_issue_environment.sh` — one-shot dispatcher preparation entrypoint; syncs repo, prepares worktree, builds prompt, initializes state, writes `${ISSUE_ROOT}/handoff.json`, and writes `${LOG_DIR}/subagent_task.md`.
- `references/paths.md` — full path layout and rules.
- `references/trigger_command.md` — the trigger spec and override rules.
- `references/state_schema.md` — `campaign_state.json` and `issue-<iid>/state.json` schemas.
- `references/glab_commands.md` — exhaustive list of allowed `glab` invocations.

When in doubt about a path / schema / command, READ the matching reference file. Do NOT reconstruct content from memory.

---

## No-Fallback (Dispatcher-Specific)

Universal rules: [`SOUL.md`](../../SOUL.md) §Shared Operational Policies → No-Fallback. Dispatcher-specific additions:

1. If `flock` cannot acquire the lock, the dispatcher MUST NOT bypass it (no `rm`-the-lockfile, no `--no-lock`, no second-attempt loops). Return a one-line status summary and exit.
2. If `sessions_spawn` for an issue child fails or times out before returning a launch acknowledgement, the dispatcher MUST NOT run prepared-worker logic inline in the dispatcher session or retry by launching a second child for the same IID. Mark the IID `blocked` with an accurate `block_reason` and continue per Blocked Skip-and-Retry.
3. A launch acknowledgement (`accepted`, `runId`, `childSessionKey`, anonymous `agent:<name>:subagent:<uuid>`, or similar) is valid ONLY if the runtime is configured to later wake the dispatcher with `RUN_CHILD_COMPLETION_CALLBACK`. If callback delivery is unavailable, record callback support as a tick-level deployment failure.
4. If `sessions_spawn` returns `thread_required`, the dispatcher requested a callback/thread flag that this runtime does not support. Do not loop. Treat it as a deployment mismatch for the affected IID or tick unless the tool schema documents a different async-callback flag and no child was created.
5. If `sessions_spawn` returns `spawn_failed`, gateway timeout text, backend-unavailable text, or an acknowledgement with no child key/run id, treat that response as the failed launch result for this tick. Record it as blocked/unsupported; do not retry repeatedly.

On failure:

- Per-IID failure → mark that IID `blocked` (retryable) or `failed` (retry-exhausted) per Blocked Skip-and-Retry; persist; continue with later IIDs.
- Tick-level failure (lock, auth, reconciliation evidence missing, etc.) → return a one-line failure summary; do not early-return as "completed".

---

## Concurrency Policy (Dispatcher-Specific)

Universal contract (cap = `max_concurrent_subagents`, same-IID never parallel, bounded async batches, runtime completion callback, no fire-and-forget): [`SOUL.md`](../../SOUL.md) §Subagent Concurrency Policy. Dispatcher-specific operational details:

- **Batch shape.** If `active_issue_iids` is non-empty, do not start a new batch; wait for runtime callbacks or GitLab reconciliation to drain it. If no prior batch is active, pick at most `max_concurrent_subagents` distinct IIDs (backlog-first, then fresh). For each candidate, run `scripts/preflight_issue.sh` first; skipped candidates do not consume a worker slot. Allocate attempt numbers SEQUENTIALLY (`scripts/allocate_attempt.sh` per IID), allocate UI accounts, run `scripts/prepare_issue_environment.sh` for each selected IID, then launch the prepared batch as parallel `sessions_spawn` calls in a SINGLE tool-call block. With `max_concurrent_subagents=1` this degenerates to one active worker at a time.
- **Spawn call shape.** Every issue spawn MUST send exactly one `RUN_PREPARED_ISSUE_WORKER` payload and MUST request parent completion callback delivery to `agent:acpx_auto_tester:main` using whatever OpenClaw fields the deployment exposes (for example `mode="run"`, `notify_parent=true`, `callback=true`, `parent=agent:acpx_auto_tester:main`, or an equivalent). Anonymous child keys are allowed. A deterministic `issue-<project>-<iid>` runtime session name is NOT required.
- **Launch contract.** A `status=accepted`, `runId`, `childSessionKey`, session id, thread id, or "created" acknowledgement is a successful launch acknowledgement if it contains a child key or run id. Record the key in `active_issue_sessions` at the same index as the IID in `active_issue_iids`, then return a compact summary with status `waiting_for_callbacks`. Do NOT increment completion counters, do NOT drain active state, and do NOT release the batch's UI accounts on launch acknowledgement.
- **Completion contract.** A child meets the completion contract only when the runtime wakes the dispatcher with `RUN_CHILD_COMPLETION_CALLBACK` carrying the child key/run id, `issue_iid`, `attempt_number`, and the prepared worker's terminal compact reply (`done`, `blocked`, `failed`, or `no_changes`). The dispatcher then reconciles GitLab, re-reads the issue state file, updates campaign lists, and drains that active slot.
- **Time budget is checked before launching a new async batch.** Once a batch is launched, the dispatcher returns; callbacks may arrive after the scheduled tick's wall-clock budget. Callback wake-ups should process completion and state cleanup even if no launch budget remains.

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
4. **Allocation is per-batch and ephemeral.** The dispatcher binds one account to each IID in the batch, in iteration order (`account[k]` to the `k`-th IID). The mapping is held in memory for preparation and passed into `scripts/prepare_issue_environment.sh`, which injects it into the prepared prompt. The worker does not receive or choose UI credentials. The accounts remain occupied until every IID in the launched batch has been drained from `active_issue_iids` by callback/reconciliation. There is no persisted allocation table, because the dispatcher MUST NOT start a new batch while any previous batch member is still active.
5. **Forbidden workarounds.** The dispatcher MUST NOT:
   - default a missing account from the pool by reusing one already assigned to another IID in the same batch
   - read account credentials from `gitlab.env`, the trigger, the issue body, or any other source
   - skip the `load_ui_accounts.sh` call when `max_concurrent_subagents=1` (the script is cheap; the single-IID batch still gets a deterministic account from the pool head)
   - persist account-to-IID assignments across ticks (the next tick re-allocates from the head of the pool file)

If `<workspace>/config/ui_accounts.env` is missing, malformed, or too small, the deployment is incomplete; abort the tick.

---

## GitLab Access (Dispatcher-Specific)

Universal rules (`glab`-only, forbidden libraries, `--hostname` rule, host pinning, exit-code mapping for `scripts/glab_auth.sh`): [`SOUL.md`](../../SOUL.md) §Shared Operational Policies → GitLab Access / GitLab Host Pinning. The allowed glab invocations for the dispatcher are listed in [`references/glab_commands.md`](references/glab_commands.md).

Dispatcher-specific failure mapping:

- If the dispatcher cannot accomplish something with the listed glab commands, mark the affected IID `blocked` with `block_reason="dispatcher needs unsupported glab op: <description>"` and stop.
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
     - update the per-issue state file (`$(issue_state_file_for <iid>)` → `${ISSUES_ROOT}/issue-<iid>/state.json`): write `status=pending`, `mode="continue"`, leave `attempts_total` untouched (the dispatcher increments it before the next worker spawn). Do NOT delete the issue subtree; dispatcher preparation replaces `${WORKTREE_DIR}` and writes the next attempt's logs under a new `${LOG_DIR}`.
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

- All scalar trigger inputs (`issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`) are authoritative for this wake-up. In async-callback mode, `hourly_issue_quota` limits launches on scheduled wake-ups; callback wake-ups record completions and do not create an unlimited launch loop. Overwrite the disk copy in `campaign_state.json` before running the algorithm when the value is present in the wake-up payload.
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

## Per-Issue Child Rules

Each issue attempt uses its own runtime child. The child may be anonymous.

1. Never launch two children for the same IID at the same time.
2. The dispatcher records a logical issue key `issue-<project>-<iid>` in state/logs, but it does not require the runtime child key to use that name.
3. Before spawning, the dispatcher MUST have written `${ISSUES_ROOT}/issue-<iid>/handoff.json` and `${LOG_DIR}/subagent_task.md`.
4. The dispatcher sends each worker a single `RUN_PREPARED_ISSUE_WORKER` message with the handoff path and minimum trigger values needed by `scripts/run_prepared_worker.sh`.
5. **`active_issue_iids` is updated atomically per batch.** Before spawning a prepared batch, append every IID in the batch to `active_issue_iids` and persist `campaign_state.json` with placeholder child keys in `active_issue_sessions` if needed. After each successful launch acknowledgement, replace the corresponding placeholder with the returned `childSessionKey` / `runId` and persist. Only after `RUN_CHILD_COMPLETION_CALLBACK` or GitLab reconciliation proves that IID has left active execution, remove that IID and child key from the active arrays and persist again. The list MUST never exceed `max_concurrent_subagents` entries.
6. **No mid-batch top-up.** The dispatcher MUST NOT spawn a replacement subagent when a single IID in the batch completes early. Wait until the whole batch has drained (`active_issue_iids=[]`) before forming a fresh batch. This preserves UI account safety without a persisted account allocation table.

Batch sizing, spawn semantics (parallel `sessions_spawn` in one tool-call block, what counts as a successful launch), callback completion, and same-IID guarantees are in §Concurrency Policy above.

---

## Per-Exec Env Contract (Dispatcher Minimum Vars)

Universal frame: [`SOUL.md`](../../SOUL.md) §Per-Exec Env Contract. Dispatcher's minimum env per Bash exec:

```
PROJECT          # project slug
GROUP            # GitLab group slug
GITLAB_TOKEN     # GitLab access token
```

Reconcile / allocate also need `MIN_IID` / `MAX_IID` / `IID` per their script docs.
Preflight / preparation also need `ISSUE_IID`, `ATTEMPT_NUMBER` after allocation, `BRANCH`, `DEV_BRANCH`, `HULAT_DIR`, `ISSUE_MODE`, `UI_ACCOUNT`, and `UI_PASSWORD` as listed in each script header.

Recommended pattern:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat GROUP=claw_gitlab GITLAB_TOKEN=<token> \
bash scripts/<script>.sh ...
```

The script self-bootstraps: derives paths, runs glab auth, computes `PROJECT_FULL` / `PROJECT_URI`.

---

## Working Directory

See [`SOUL.md`](../../SOUL.md) §Working Directory. The skill directory for THIS skill is the directory containing this SKILL.md (e.g. `<workspace>/skills/gitlab_issue_campaign_dispatcher/`). Run `cd "${SKILL_DIR}"` ONCE per session before any `bash scripts/...` invocation.

---

## Dispatcher Algorithm

Run on every scheduled wake-up and every runtime child-completion callback wake-up.

When a step below says `bash scripts/X.sh`, that is shorthand for the script action. In an actual OpenClaw Bash tool call, prefix the command with the minimum env vars from the Per-Exec Env Contract plus any script-specific vars in the same exec. Never rely on exports from a previous Bash tool call.

1. **Bootstrap.**
   - `cd ${SKILL_DIR}` — see "Working Directory" above; this is mandatory before any relative `scripts/...` invocation.
   - If doing an explicit bootstrap check in the current shell, use the full minimum env contract:
     `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> source scripts/env_paths.sh`
     This authenticates glab and computes `PROJECT_FULL` / `PROJECT_URI`.
   - Acquire the flock above.
   - Do NOT call `scripts/glab_auth.sh` separately after `env_paths.sh`, and do NOT manually export `PROJECT_FULL` or `PROJECT_URI`. Every later `bash scripts/...` command is a fresh shell and must receive the minimum env vars from the Per-Exec Env Contract; the target script will source `env_paths.sh` itself. If `env_paths.sh` / glab auth fails, abort the tick.
2. **Load + override campaign state.**
   - Read `${CAMPAIGN_STATE_FILE}`, or initialize using fresh-init values from `references/state_schema.md` if absent.
   - Apply schema migration if the on-disk file uses the legacy scalar `active_issue_iid` / `active_issue_session` — see `references/state_schema.md` "Schema migration" for the rule. Default `max_concurrent_subagents` to `1` if missing.
   - On `RUN_SCHEDULED_ISSUE_CAMPAIGN`, apply trigger-input override: overwrite `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, and `max_concurrent_subagents` with the trigger values. When the scheduled trigger omits `max_concurrent_subagents`, default it to `1` for the tick AND persist that default.
   - On `RUN_CHILD_COMPLETION_CALLBACK`, use payload values when present; otherwise preserve the on-disk scalar scheduling values. `project`, `group`, and `gitlab_token` are still required to run `glab` and scripts.
   - Persist.
3. **Reconcile against GitLab — MANDATORY, ALWAYS RUNS.**
   - `PROJECT=<project> GROUP=<group> GITLAB_TOKEN=<token> MIN_IID=... MAX_IID=... bash scripts/reconcile.sh` (self-bootstrapping; see Source-of-Truth Policy).
   - Apply disk cache correction per the policy above.
   - Record the evidence file path into `campaign_state.json.last_reconcile_evidence`.
4. **Early-return only if allowed.** Permitted iff:
   - the evidence file from this tick exists
   - every IID in range has `is_done_on_gitlab == true` in it
   - every IID in range has `needs_continue == false` in it
   - `unfinished_iids` is empty and `campaign_status = completed`
   Otherwise continue.
5. **If this is `RUN_CHILD_COMPLETION_CALLBACK`, process exactly that callback.**
   - Validate that the callback includes `issue_iid`, `attempt_number`, a child key/run id, and a terminal worker result (`done`, `blocked`, `failed`, or `no_changes`). If the payload is malformed, return a tick-level callback failure summary; do not spawn anything.
   - If `issue_iid` is present in `active_issue_iids`, re-read `$(issue_state_file_for <iid>)` (`${ISSUES_ROOT}/issue-<iid>/state.json`) and classify the IID using the worker result, the issue state file, and the reconciliation evidence. Terminal states update `completed_iids` / `failed_iids`; `blocked` remains retryable per Blocked Skip-and-Retry; unexpected `in_progress` remains active unless GitLab reconciliation proves terminal completion.
   - Drain only the matching IID/child key from `active_issue_iids` and `active_issue_sessions` when the callback is terminal or reconciliation proves the IID is no longer active. Preserve other active batch members.
   - If the callback child key differs from the stored `active_issue_sessions` entry but the stored entry is only the placeholder logical key `issue-<project>-<iid>`, accept the callback for the matching IID/attempt. This handles crashes between launch acknowledgement and persistence.
   - If the callback is stale (IID not active, attempt number older than `latest_attempt_number`, or child key mismatch against a persisted non-placeholder child key), treat it as idempotent: keep the reconciled disk truth, do not launch anything, and return a compact `"callback_status":"stale_or_already_drained"` summary.
   - Persist `campaign_state.json` and return. Callback wake-ups do not start replacement children; the next scheduled wake-up launches the next batch once the active list is empty.
6. **Scheduled wake-up launch budget.**
   - Set `quota_launched_this_tick = 0`; record tick start time.
   - If `active_issue_iids` is non-empty, return `"campaign_status":"waiting_for_callbacks"` and do not form a new batch. This preserves per-batch UI-account safety.
   - Check time budget before forming a new batch. If `now - tick_start_time >= max_runtime_minutes`, return a compact time-budget summary.
7. **Form one prepared async batch.**
   - Walk eligible IIDs in the standard order (lowest-IID backlog first, then fresh IIDs). For each candidate, run `ISSUE_IID=<iid> ISSUE_MODE=<fresh|continue> BRANCH=<branch> bash scripts/preflight_issue.sh`. Skip candidates whose preflight JSON returns `eligible=false` (`open_mr_exists`, `remote_branch_exists`, or `claimed`) and continue scanning until the prepared batch has `min(max_concurrent_subagents, hourly_issue_quota)` IIDs or no eligible candidate remains. If the prepared batch is empty, skip to final persistence.
   - Allocate attempt numbers SEQUENTIALLY. For each IID in the prepared batch, run `IID=<iid> bash scripts/allocate_attempt.sh` in its own Bash exec, capturing the printed number `N_iid`. Do all allocations BEFORE any `sessions_spawn`.
   - Allocate UI accounts for the prepared batch. Run `BATCH_SIZE=<batch_size> bash scripts/load_ui_accounts.sh` in a single Bash exec, capturing exactly `batch_size` lines of `user:pass` form. Bind `account[k]` to the `k`-th IID of the prepared batch. On any non-zero exit code (10/11/12/13 — see UI Account Allocation Policy above), abort the tick with a one-line failure summary; do not spawn the batch.
   - Prepare every issue environment before spawn. For each IID in the prepared batch, run `ISSUE_IID=<iid> ATTEMPT_NUMBER=<N_iid> ISSUE_MODE=<fresh|continue> UI_ACCOUNT=<user> UI_PASSWORD=<pass> BRANCH=<branch> DEV_BRANCH=<dev_branch> HULAT_DIR=<hulat_dir> bash scripts/prepare_issue_environment.sh`. This script writes `${ISSUE_ROOT}/handoff.json` and `${LOG_DIR}/subagent_task.md`, initializes attempt state, and returns compact handoff JSON. If preparation fails, mark that IID `blocked` and do not spawn it.
   - Update `active_issue_iids` + persist. Append every successfully prepared IID in the batch to `active_issue_iids` and append matching placeholder logical keys (`issue-<project>-<iid>`) to `active_issue_sessions`. Persist before spawning so a crash mid-spawn leaves an accurate cache for reconciliation.
8. **Launch the prepared batch in a SINGLE tool-call block.**
   - Issue one `sessions_spawn` per prepared IID, all in the same parallel block.
   - Each spawn may be anonymous (for example `mode="run"`) but MUST request runtime parent callback delivery to `agent:acpx_auto_tester:main`.
   - Each spawn sends `RUN_PREPARED_ISSUE_WORKER` with payload:
     - first line: `RUN_PREPARED_ISSUE_WORKER`
     - role guard: `You are the prepared worker for this IID. Do not call sessions_spawn or sessions_history. Do not run dispatcher logic.`
     - `handoff_file=${ISSUES_ROOT}/issue-<iid>/handoff.json`
     - `project=`, `group=`, `issue_iid=`, `attempt_number=`
     - `branch=`, `dev_branch=`, `hulat_dir=`
     - `gitlab_token=` and optional `blocked_retry_limit=`
     - instruction to run `${LOG_DIR}/subagent_task.md` / `scripts/run_prepared_worker.sh`
   - The worker MUST NOT read SKILL.md or references and MUST NOT call `sessions_spawn`; the handoff and subagent task are self-contained.
   - For each successful launch acknowledgement, record the returned `childSessionKey` / `runId` into `active_issue_sessions` at the matching IID index and increment `quota_launched_this_tick`.
   - For each failed launch, mark that IID `blocked`, remove it from `active_issue_iids` / `active_issue_sessions`, and persist the raw spawn error. Do not retry in a loop.
9. Update `next_new_issue_iid` if fresh issues were introduced.
10. If every IID in `[issue_min_iid, issue_max_iid]` is terminal, set `campaign_status = completed`.
11. Persist `campaign_state.json` and return the compact chat summary.

Stop conditions for scheduled launch wake-ups: `quota_launched_this_tick >= hourly_issue_quota`, time budget exhausted (`now - tick_start_time >= max_runtime_minutes`), an existing active batch is waiting for callbacks, or no eligible IID remains for the next batch.

---

## Blocked Skip-and-Retry

1. Blocked issues record `block_reason` in their per-issue state file.
2. A blocked issue is retryable only after `blocked_cooldown_ticks` ticks have elapsed since the last attempt.
3. If `retry_count > blocked_retry_limit`, the issue may be marked `failed`.
4. A blocked issue must not permanently block later issues from using remaining quota.

---

## Terminal Completion Policy

Successful MR creation plus both workflow labels (`done` and `pr`) being present is the terminal completion condition for a normal attempt. Separately, GitLab `state=closed` is a hard terminal skip condition: the dispatcher MUST NOT schedule a closed issue, even if `continue` is present or `done`/`pr` are absent. The prepared worker changes `doing` to `done` after Wiki evidence is published, then adds `pr` after MR creation / rotation succeeds, and only then writes `status=done`. For opened issues, the dispatcher MUST NOT schedule that issue again unless reconciliation finds `needs_continue == true` or `user_reopened == true` on GitLab. `continue` wins over cached `done` state and over an existing MR only while the issue is opened.

---

## Chat Output Policy

Return a single compact JSON summary, e.g.:

```json
{
  "skill_version": "2026-05-06.3",
  "campaign_status": "waiting_for_callbacks",
  "active_issue_iids": [14, 15],
  "active_issue_sessions": ["agent:acpx_auto_tester:subagent:uuid-a", "agent:acpx_auto_tester:subagent:uuid-b"],
  "max_concurrent_subagents": 1,
  "ui_account_pool_size": 4,
  "unfinished_iids": [9, 10, 14],
  "next_new_issue_iid": 19,
  "quota_launched_this_tick": 2,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/openclaw_work/<project>/openclaw_log/dispatcher/reconcile-<ts>.json"
}
```

Between launch and callbacks, `active_issue_iids` reflects the IIDs currently in flight (e.g. `[14, 15]` when `max_concurrent_subagents=2`). Each `RUN_CHILD_COMPLETION_CALLBACK` drains one matching active entry after reconciliation/state re-read. A fresh batch is formed only when the active arrays are empty.

Never paste full logs, full diffs, or long issue bodies into chat.
