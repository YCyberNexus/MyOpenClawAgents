---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-04-30.1] Run a recurring scheduled GitLab issue campaign using one lightweight dispatcher session plus one dedicated session per issue. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, per-batch UI-account allocation from a deployment-pinned pool, persistent disk state, and compact dispatcher chat output."
allowed-tools: Bash, Read, Write, Edit, sessions_history, sessions_spawn
---

# GitLab Issue Campaign Dispatcher Skill

**SKILL_VERSION: 2026-04-30.1**

On every wake-up, the dispatcher MUST echo the literal string `SKILL_VERSION=2026-04-30.1` in its compact chat summary (add a `"skill_version"` field to the returned JSON). This lets the operator verify which version of the skill is actually loaded.

## Companion files

This SKILL is intentionally short. Detailed bash and fixed reference data live in sibling folders:

- `scripts/env_paths.sh` — populates path variables (SOURCE it, don't redefine).
- `scripts/glab_auth.sh` — bootstraps `glab` CLI; prints `GITLAB_HOST`.
- `scripts/reconcile.sh` — queries GitLab for the IID range and writes the evidence file.
- `scripts/allocate_attempt.sh` — atomically allocates the next attempt number for an IID; the dispatcher MUST call this before every executor spawn and pass the result via `attempt_number=` in the trigger.
- `scripts/load_ui_accounts.sh` — read the deployment-pinned UI test account pool (`<workspace>/config/ui_accounts.env`); used at the top of every batch to allocate one distinct account per IID.
- `references/paths.md` — full path layout and rules.
- `references/trigger_command.md` — the trigger spec and override rules.
- `references/state_schema.md` — `campaign_state.json` and `issue-<iid>/state.json` schemas.
- `references/glab_commands.md` — exhaustive list of allowed `glab` invocations.

When in doubt about a path / schema / command, READ the matching reference file. Do NOT reconstruct content from memory.

---

## No-Fallback Policy (READ FIRST — HARD RULE)

**The dispatcher MUST follow the prescribed method exactly. When the prescribed method fails, the dispatcher fails the affected unit of work and stops — it does NOT improvise an alternative approach.**

This rule overrides any default model behavior that says "try another way", "be helpful", "complete the task one way or another", or "the user wants this to succeed". For this skill, **a clean controlled failure is strictly better than an unsupervised alternative attempt**.

### Concrete prohibitions

1. If a script in `scripts/` exits non-zero, the dispatcher MUST NOT:
   - rewrite the script's logic inline in bash
   - skip the script and "do the same thing manually"
   - try a "simpler" or "different" command that "should work"
2. If `glab` cannot do something, the dispatcher MUST NOT fall back to `curl` / `wget` / Python HTTP / `python-gitlab` / any HTTP library. (Also covered by GitLab Access Policy below — listed here for emphasis.)
3. If `flock` cannot acquire the lock, the dispatcher MUST NOT bypass the lock (no `rm`-the-lockfile, no `--no-lock`, no second-attempt loops).
4. If `sessions_spawn` for an issue session fails or times out, the dispatcher MUST NOT:
   - run executor logic inline in the dispatcher session
   - spawn a non-dedicated session as a substitute
   - retry by spawning a different session name
   The IID is marked `blocked` with an accurate `block_reason`, the dispatcher continues to the next IID per Blocked Skip-and-Retry rules.
5. If a required input is missing or malformed, the dispatcher MUST abort the tick with a short summary. It MUST NOT guess defaults beyond those explicitly listed in `references/trigger_command.md`.
6. If a step listed in the Dispatcher Algorithm produces an unexpected result, the dispatcher MUST stop the affected IID (or the tick), record the failure on disk, and return. It MUST NOT invent a recovery path that is not in this SKILL.

### What the dispatcher does on failure

- Per-IID failure → mark that IID `blocked` (retryable) or `failed` (non-recoverable / retry-exhausted) per Blocked Skip-and-Retry rules; persist; continue with later IIDs.
- Tick-level failure (lock, auth, reconciliation evidence missing, etc.) → return a one-line failure summary; do not early-return as "completed".

### What "improvising" looks like (forbidden examples)

- "`scripts/reconcile.sh` failed, let me write a quick Python loop instead." — forbidden.
- "`glab mr create` returned an error, let me try `git push` with the `merge_request.create` push option." — forbidden.
- "`acpx --auth-policy skip claude exec -f ...` errored, let me try `claude` directly / `acpx claude -s ...` / `acpx claude command` / drop `--auth-policy skip` / a smaller prompt." — forbidden (executor-side rule, listed here so the dispatcher recognizes it from the executor's reply).
- "The trigger is missing `branch=`, let me default to `master`." — forbidden; abort the tick.

If you find yourself reaching for a tool, command, or workflow that is not explicitly listed in this SKILL, in `scripts/`, or in `references/`, that is the signal to stop and fail — not the signal to try harder.

---

## Concurrency Policy (READ FIRST — HARD RULE)

This dispatcher operates over issues in **bounded batches of size `max_concurrent_subagents`** (trigger input, integer ≥ 1, default 1).

- At any moment, at most `max_concurrent_subagents` issue sessions may be active.
- The two dials are **independent**:
  - `max_concurrent_subagents` = how many subagents may be in flight at the same time (parallelism width).
  - `hourly_issue_quota` = how many issues must reach a terminal state in this tick (per-tick completion count). It is NOT a parallelism knob.
- **Same IID never runs twice in parallel.** Per-IID work is always serial across attempts. The session name `issue-<project>-<iid>` is the structural guarantee. Cross-IID parallelism is bounded by `max_concurrent_subagents`.
- **Batch shape.** When picking the next batch:
  - Pick at most `max_concurrent_subagents` distinct IIDs (backlog-first, then fresh).
  - Allocate attempt numbers SEQUENTIALLY (`scripts/allocate_attempt.sh` per IID, one fresh Bash exec per call). Concurrent allocation would race on `attempts_total` even though each IID has its own state file — a single Bash batch makes the order observable in logs.
  - Spawn the batch as parallel `sessions_spawn` calls in a SINGLE tool-call block (one tool call per IID, all in the same block). Each spawn MUST use `mode="session"` and `thread=true` so OpenClaw can bind the ACP session to a thread and wait for the terminal executor reply. When `max_concurrent_subagents=1` this degenerates to "exactly one spawn per block" — the legacy serial behavior.
- **Wait for the WHOLE batch before forming the next.** No fire-and-forget, no rolling pool. Every spawn must return its terminal reply before the dispatcher re-reads per-issue state and considers the next batch. This means a slow IID inside a batch can stall faster IIDs in the same batch — that is the explicit trade-off for simplicity and predictable time-budget accounting.
- A `childSessionKey`, session id, thread id, or "created" acknowledgement is NOT a terminal executor reply. If the runtime returns only child-session identifiers or reports that the current channel cannot wait for child sessions, treat the spawn/wait operation as failed or unsupported for this tick. Do NOT report "batch in flight" as success, and do NOT leave `active_issue_iids` populated on the assumption that detached child sessions are running.
- If `sessions_spawn` returns `thread_required`, the dispatcher call was malformed: rerun the spawn in the same tick only if no executor session actually started, using the required `mode="session"` + `thread=true` arguments. If it returns `thread_binding_invalid`, `spawn_failed`, or `ACP runtime backend is currently unavailable`, treat that as a runtime/backend capability failure and do not try a different spawn mode.
- Anonymous child keys such as `agent:<name>:subagent:<uuid>` are NOT dedicated issue sessions. A successful issue spawn MUST target or return the deterministic session name `issue-<project>-<iid>`. If the runtime creates an anonymous subagent instead, treat it as a spawn failure for that IID.
- **Time budget is checked between batches, not within a batch.** Once a batch is spawned, the dispatcher commits to waiting for all members; the `max_runtime_minutes` check happens at the top of the next batch loop iteration.
- Background / no-wait / fire-and-forget spawn modes are forbidden for issue sessions.

If this policy conflicts with any other instruction, this policy wins.

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
4. **Allocation is per-batch and ephemeral.** The dispatcher binds one account to each IID in the batch, in iteration order (`account[k]` to the `k`-th IID). The mapping is held in memory for the duration of the batch and passed to each executor via the trigger fields `ui_account=<user>` and `ui_password=<pass>`. After the batch returns, the accounts implicitly return to the pool — there is no persisted allocation table, because the existing per-batch wait contract (form a batch, spawn it in one tool-call block, wait for ALL members, then form the next batch) guarantees that no two batches are in flight at once.
5. **Forbidden workarounds.** The dispatcher MUST NOT:
   - default a missing account from the pool by reusing one already assigned to another IID in the same batch
   - read account credentials from `gitlab.env`, the trigger, the issue body, or any other source
   - skip the `load_ui_accounts.sh` call when `max_concurrent_subagents=1` (the script is cheap; the single-IID batch still gets a deterministic account from the pool head)
   - persist account-to-IID assignments across ticks (the next tick re-allocates from the head of the pool file)

If `<workspace>/config/ui_accounts.env` is missing, malformed, or too small, the deployment is incomplete; abort the tick.

---

## GitLab Access Policy (READ FIRST — HARD RULE)

The dispatcher MUST access GitLab exclusively through the `glab` CLI, via the scripts in `scripts/` and the commands documented in `references/glab_commands.md`.

Forbidden — never used to talk to GitLab:

- `curl`, `wget`, `http`, `httpie`
- Any HTTP library in any language (`requests`, `urllib`, `python-gitlab`, `@gitbeaker/*`, etc.)
- Any custom shell function that wraps an HTTP call to a `*/api/v4/*` URL
- Any `glab` subcommand not listed in `references/glab_commands.md`

If the dispatcher cannot accomplish something with the listed glab commands, mark the affected IID `blocked` with `block_reason="dispatcher needs unsupported glab op: <description>"` and stop. Do NOT fall back to curl.

If `glab auth status` fails after `scripts/glab_auth.sh`, abort the tick — do NOT silently switch to curl.

**Do NOT pass `--hostname` to `glab api` calls.** `scripts/glab_auth.sh` exports `GITLAB_HOST` as an env var; glab natively reads that env var and routes API calls correctly. Passing `--hostname` with a `host:port` value confuses glab's URL resolution for some subcommands and historically caused the agent to spin trying alternative invocations (env var, `-R` flag, different config keys, etc.). The single allowed convention is: rely on the exported `GITLAB_HOST` env var, drop the `--hostname` flag everywhere.

### GitLab host is pinned at deployment time

The GitLab host (and protocol) the dispatcher talks to is **pinned in `<workspace>/config/gitlab.env`**, NOT derived from the trigger's `gitlab_address` on every tick. See `<workspace>/config/README.md` for the rationale.

Implications:

- The dispatcher MUST read the host from `scripts/glab_auth.sh`, never re-derive it inline from `${GITLAB_ADDRESS}`. Calling `sed` on `${GITLAB_ADDRESS}` outside that script is forbidden.
- The trigger's `gitlab_address` is a **verification value**. `scripts/glab_auth.sh` will refuse to run if the trigger's host does not match `config/gitlab.env`, and exits non-zero. The dispatcher MUST treat that as a tick-level failure and abort.
- `gitlab_token` from the trigger is used to refresh `glab auth login` against the pinned host every tick (token rotation works), but the host itself never changes from a trigger input.

If `config/gitlab.env` is missing or malformed (`scripts/glab_auth.sh` exits 10/11/12), the deployment is incomplete: abort the tick with a one-line summary and surface the operator-facing error.

---

## Source-of-Truth Policy (READ FIRST — HARD RULE)

**GitLab is the ground truth for per-issue workflow state. Disk state is only the dispatcher's progress cache.** When the two disagree, GitLab wins. Disk is corrected to match.

Concrete rules:

1. On every wake-up, BEFORE any "already done" / "already completed" / "skip this IID" / "early return" decision, run `scripts/reconcile.sh` for the full `[issue_min_iid, issue_max_iid]` range. The script writes `${DISPATCHER_LOG_DIR}/reconcile-<ts>.json`. **No evidence file = reconciliation didn't happen = the tick is failed; do not early-return.**
2. The dispatcher MUST NOT use `campaign_state.json.completed_iids`, `campaign_state.json.campaign_status`, or any per-issue `issue-<iid>/state.json.status` to decide an IID is finished. Those are caches.
3. Ground truth per IID comes from the evidence file. Three signals:
   - `is_done_on_gitlab` ⇔ live GitLab labels contain both literal `done` and literal `pr`.
   - `needs_continue` ⇔ live GitLab labels contain literal `continue`. This is set by a human reviewer who has noticed that a previous `done` + `pr` result was incorrect (Claude Code returned but didn't actually finish the work) and wants the agent to resume on the existing work branch. `continue` wins if it is present alongside `done` and/or `pr`.
   - `user_reopened` ⇔ the issue does not have the completed pair `done`+`pr`, and none of `failed`, `blocked`, or `continue` are present in live labels (the issue was bounced back to `todo` / `doing` from scratch, or was left in the pre-MR `done`-only intermediate state).
4. **Disk cache correction is mandatory** when they disagree:
   - If `needs_continue == true`:
     - remove IID from `completed_iids` / `failed_iids`
     - add to `unfinished_iids`
     - update the per-issue state file (`$(issue_state_file_for <iid>)` → `${ISSUES_ROOT}/issue-<iid>/state.json`): write `status=pending`, `mode="continue"`, leave `attempts_total` untouched (the dispatcher increments it before the next executor spawn). Do NOT delete the issue subtree; the executor replaces `${WORKTREE_DIR}` and writes the next attempt's logs under a new `${LOG_DIR}`.
     - remove this IID from `active_issue_iids` (and the corresponding session from `active_issue_sessions`) if present
     - force `campaign_status = running`
     - persist `campaign_state.json`
   - Else if disk says finished but `user_reopened == true`:
     - same as above, but the per-issue state gets `mode="fresh"` (default)
   - If disk says unfinished but `is_done_on_gitlab == true` (and `needs_continue == false`), mark it finished on disk and skip.
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
3. The dispatcher sends each executor a single `RUN_SINGLE_ISSUE_SESSION` message (see executor SKILL for the full payload).
4. **Bounded batch.** A batch contains at most `max_concurrent_subagents` distinct IIDs. The dispatcher spawns the whole batch in one tool-call block (parallel `sessions_spawn`), blocks on every spawn's terminal reply, re-reads each per-issue state file, only then considers the next batch. Runtime responses that only contain `childSessionKey` / session ids / "created" acknowledgements do not satisfy this rule.
5. **Thread-bound session mode only.** Each `sessions_spawn` call MUST use `mode="session"` and `thread=true`. `mode="session"` without `thread=true` fails with `thread_required`; any fallback that avoids thread binding is forbidden because the dispatcher must wait for a terminal executor reply.
6. **Deterministic session names only.** Each `sessions_spawn` call MUST target the exact session name `issue-<project>-<iid>`. Do NOT accept anonymous runtime-generated keys like `agent:<name>:subagent:<uuid>` as a substitute.
7. **Distinct IIDs only.** Two `sessions_spawn` calls in the same batch MUST target different IIDs. Same-IID parallelism is forbidden (see Concurrency Policy above). The session-name derivation `issue-<project>-<iid>` is the structural guarantee.
8. **`active_issue_iids` is updated atomically per batch.** Before spawning a batch, append every IID in the batch to `active_issue_iids` and persist `campaign_state.json`. After the batch returns and per-issue states are re-read, remove every batch member from `active_issue_iids` (terminal IIDs go to the appropriate completed/blocked/failed list; `in_progress`/budget-exhausted IIDs go back to `unfinished_iids`) and persist again. The list MUST never exceed `max_concurrent_subagents` entries.
9. **No mid-batch top-up.** The dispatcher MUST NOT spawn a replacement subagent when a single IID in the batch returns early. Wait for the whole batch, form a fresh batch.

---

## Per-Exec Env Contract (READ BEFORE Step 1 — HARD RULE)

OpenClaw runs each `Bash` tool call in a **fresh shell**. Exports made in one exec do NOT survive to the next. As of SKILL_VERSION 2026-04-29.5, every `scripts/*.sh` in this skill self-bootstraps by sourcing `env_paths.sh` at its top — but that script needs the minimum trigger inputs to be in env at every call.

**Every Bash exec MUST start with these 3 env vars exported:**

```
PROJECT          # project slug
GROUP            # GitLab group slug
GITLAB_TOKEN     # GitLab access token
```

Reconcile / allocate also need `MIN_IID` / `MAX_IID` / `IID` per their script docs.

Recommended pattern for every exec:

```bash
cd "${SKILL_DIR}" && \
PROJECT=px_ifp_hulat GROUP=claw_gitlab GITLAB_TOKEN=<token> \
bash scripts/<script>.sh ...
```

The script self-bootstraps from there: derives paths, runs glab auth, computes `PROJECT_FULL` / `PROJECT_URI`. The dispatcher does NOT need to manage these derived vars across execs.

---

## Working Directory (READ BEFORE Step 1 — HARD RULE)

All `scripts/...` and `references/...` paths in this SKILL are **relative to this skill's own directory** (the directory containing this SKILL.md, e.g. `<workspace>/skills/gitlab_issue_campaign_dispatcher/`).

Before issuing ANY `bash scripts/...` command, the dispatcher MUST `cd` into the skill directory in the same shell session. Otherwise relative paths like `scripts/env_paths.sh` resolve against whatever cwd OpenClaw started the session in (often the user home, NOT the skill dir), and the very first invocation fails with "no such file or directory".

The skill directory's absolute path is known to the agent at load time (the same path SKILL.md was read from). Bootstrap snippet, run ONCE per session before anything else:

```bash
SKILL_DIR="<absolute path of this SKILL.md's parent>"   # e.g. /home/claw/.openclaw/workspace-UiAutoTester/skills/gitlab_issue_campaign_dispatcher
cd "${SKILL_DIR}"
```

After this, every subsequent `bash scripts/X.sh` and `source scripts/X.sh` invocation in the algorithm below resolves correctly. Do NOT attempt to invoke scripts from any other cwd; do NOT prepend `./` or `../`; do NOT try to find scripts via `find` or `ls`. The single allowed convention is: `cd ${SKILL_DIR}` once, then invoke scripts by relative path.

---

## Dispatcher Algorithm

Run on every scheduled wake-up.

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
   - Apply trigger-input override: overwrite `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`, and `max_concurrent_subagents` with the trigger values. When the trigger omits `max_concurrent_subagents`, default it to `1` for the tick AND persist that default.
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
5. `quota_completed_this_tick = 0`; record tick start time.
6. **Bounded-batch loop.** While quota AND time budget remain:
   1. **Check time budget at the TOP of the loop iteration**, before forming a new batch. If `now - tick_start_time >= max_runtime_minutes`, break out of the loop. (Time is NOT checked mid-batch — once a batch is spawned, the dispatcher commits to waiting for all members.)
   2. **Form the next batch.** Compute `batch_size = min(max_concurrent_subagents, remaining_quota, remaining_eligible_iids)`. Pick `batch_size` distinct IIDs in the standard order: lowest-IID eligible backlog items first, then fresh IIDs from `next_new_issue_iid` upward. If `batch_size == 0`, break out of the loop.
   3. **Allocate attempt numbers SEQUENTIALLY.** For each IID in the batch, run `IID=<iid> bash scripts/allocate_attempt.sh` in its own Bash exec, capturing the printed number `N_iid`. Do all allocations BEFORE any `sessions_spawn`. Sequential allocation is mandatory — concurrent allocation would race even though each IID has its own state file (the order needs to be observable in dispatcher logs, and the script is cheap so serializing costs nothing).
   4. **Allocate UI accounts for the batch.** Run `BATCH_SIZE=<batch_size> bash scripts/load_ui_accounts.sh` in a single Bash exec, capturing exactly `batch_size` lines of `user:pass` form. Bind `account[k]` to the `k`-th IID of the batch (k=0..batch_size-1). On any non-zero exit code (10/11/12/13 — see UI Account Allocation Policy above), abort the tick with a one-line failure summary; do not spawn the batch.
   5. **Update `active_issue_iids` + persist.** Append every IID in the batch (and corresponding session names in `active_issue_sessions`) to `campaign_state.json`. Persist before spawning so a crash mid-spawn leaves an accurate cache for reconciliation.
   6. **Spawn the batch in a SINGLE tool-call block.** Issue one `sessions_spawn` per IID, all in the same parallel block. Each spawn MUST use `mode="session"` and `thread=true`, and MUST target the exact dedicated session name `issue-<project>-<iid>`; anonymous `agent:<name>:subagent:<uuid>` keys are not acceptable. Each spawn sends `RUN_SINGLE_ISSUE_SESSION` with payload:
      - `branch=` (target / integration branch, typically `master`)
      - `dev_branch=` (clean baseline branch from which fresh-mode worktrees are checked out)
      - `attempt_number=N_iid` (the value allocated in sub-step 3 above for THIS IID)
      - `ui_account=<user>` and `ui_password=<pass>` (the credentials allocated in sub-step 4 above for THIS IID — distinct from every other IID in the batch; never omit these fields)
      - `issue_mode=continue` if the per-issue state has `mode="continue"`; otherwise `issue_mode=fresh` (default)

      When `max_concurrent_subagents=1` this block contains exactly one `sessions_spawn` call — identical to the legacy serial behavior, except the UI account is now drawn from the pool head rather than from the issue body. When `> 1`, the calls run in parallel and the dispatcher waits for all of them to return.

      Why allocate-first-then-spawn: `env_paths.sh` used to auto-increment on every source. If the executor session was cold-restarted (OpenClaw retry, transient error in the executor's Step 1, etc.), each source could double-count a logical attempt. Allocating once in the dispatcher and passing the number through the trigger makes attempt allocation a single deterministic event per logical resolution. The same rule applies per IID inside a batch. UI accounts use the same allocate-first-then-spawn pattern for the same reason — and additionally to make the per-IID account assignment observable in dispatcher logs.
   7. **After the WHOLE batch returns terminal executor replies**, for each IID in the batch:
      - Re-read `$(issue_state_file_for <iid>)` (`${ISSUES_ROOT}/issue-<iid>/state.json`) from disk.
      - If terminal (`done` / `no_changes` / `failed`): update the corresponding list (`completed_iids` / `failed_iids` etc.), increment `quota_completed_this_tick`.
      - If `blocked`: keep in backlog; will retry after cooldown per Blocked Skip-and-Retry.
      - If `in_progress` (the executor returned but its work is not yet terminal — rare): keep as backlog for the next tick.
   8. **Drain `active_issue_iids` + persist.** Remove every IID in the just-finished batch from `active_issue_iids` and `active_issue_sessions`, then persist `campaign_state.json` before the next loop iteration. The list MUST be empty (or contain only IIDs from a future batch — i.e. never carry stragglers from a prior batch) before forming a new batch.
7. Update `next_new_issue_iid` if fresh issues were introduced.
8. If every IID in `[issue_min_iid, issue_max_iid]` is terminal, set `campaign_status = completed`.
9. Persist `campaign_state.json` and return the compact chat summary.

Stop conditions (checked at the top of each batch iteration): `quota_completed_this_tick >= hourly_issue_quota`, time budget exhausted (`now - tick_start_time >= max_runtime_minutes`), or no eligible IID remains for the next batch.

---

## Blocked Skip-and-Retry

1. Blocked issues record `block_reason` in their per-issue state file.
2. A blocked issue is retryable only after `blocked_cooldown_ticks` ticks have elapsed since the last attempt.
3. If `retry_count > blocked_retry_limit`, the issue may be marked `failed`.
4. A blocked issue must not permanently block later issues from using remaining quota.

---

## Terminal Completion Policy

Successful MR creation plus both workflow labels (`done` and `pr`) being present is the terminal completion condition for a normal attempt. The executor changes `doing` to `done` after Wiki evidence is published, then adds `pr` after MR creation / rotation succeeds, and only then writes `status=done`. The dispatcher MUST NOT schedule that issue again unless reconciliation finds `needs_continue == true` or `user_reopened == true` on GitLab. `continue` wins over cached `done` state and over an existing MR, even if `done` and/or `pr` are still present.

---

## Chat Output Policy

Return a single compact JSON summary, e.g.:

```json
{
  "skill_version": "2026-04-30.1",
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
