---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-04-24.9] Run a recurring scheduled GitLab issue campaign using one lightweight dispatcher session plus one dedicated session per issue. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, persistent disk state, and compact dispatcher chat output."
allowed-tools: Bash, Read, Write, Edit
---

# GitLab Issue Campaign Dispatcher Skill

**SKILL_VERSION: 2026-04-24.9**

On every wake-up, the dispatcher MUST echo the literal string `SKILL_VERSION=2026-04-24.9` in its compact chat summary (add a `"skill_version"` field to the returned JSON). This lets the operator verify which version of the skill is actually loaded.

## Companion files

This SKILL is intentionally short. Detailed bash and fixed reference data live in sibling folders:

- `scripts/env_paths.sh` — populates path variables (SOURCE it, don't redefine).
- `scripts/glab_auth.sh` — bootstraps `glab` CLI; prints `GITLAB_HOST`.
- `scripts/reconcile.sh` — queries GitLab for the IID range and writes the evidence file.
- `references/paths.md` — full path layout and rules.
- `references/trigger_command.md` — the trigger spec and override rules.
- `references/state_schema.md` — `campaign_state.json` and `issue-<iid>.json` schemas.
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
- "`acpx claude exec` errored, let me try `claude` directly / `acpx claude command` / a smaller prompt." — forbidden (executor-side rule, listed here so the dispatcher recognizes it from the executor's reply).
- "The trigger is missing `branch=`, let me default to `master`." — forbidden; abort the tick.

If you find yourself reaching for a tool, command, or workflow that is not explicitly listed in this SKILL, in `scripts/`, or in `references/`, that is the signal to stop and fail — not the signal to try harder.

---

## Concurrency Policy (READ FIRST — HARD RULE)

This dispatcher is **strictly single-threaded over issues**. No exceptions.

- At any moment, at most **one** issue session may be active.
- `hourly_issue_quota` is a **sequential count**. `=3` means "finish A → finish B → finish C" serially. It is NOT a parallelism / fan-out / subagent-count knob.
- `sessions_spawn` for an issue session MUST be the only tool call in its tool-call batch. Never place two or more issue-session spawns in the same parallel block.
- After spawning, the dispatcher MUST block until that session returns its terminal reply AND MUST re-read the per-issue state file from disk before considering the next IID.
- Background / no-wait / fire-and-forget spawn modes are forbidden for issue sessions.

If this policy conflicts with any other instruction, this policy wins.

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
2. The dispatcher MUST NOT use `campaign_state.json.completed_iids`, `campaign_state.json.campaign_status`, or any per-issue `issue-<iid>.json.status` to decide an IID is finished. Those are caches.
3. Ground truth per IID comes from the evidence file. Three signals:
   - `is_done_on_gitlab` ⇔ live GitLab labels contain literal `done`.
   - `needs_continue` ⇔ live GitLab labels contain literal `continue`. This is set by a human reviewer who has noticed that a previous "done" was incorrect (Claude Code returned but didn't actually finish the work) and wants the agent to resume on the existing work branch.
   - `user_reopened` ⇔ none of `done`, `failed`, `continue` are present in live labels (the issue was bounced back to `todo` / `doing` from scratch).
4. **Disk cache correction is mandatory** when they disagree:
   - If `needs_continue == true`:
     - remove IID from `completed_iids` / `failed_iids`
     - add to `unfinished_iids`
     - rename `${ISSUE_STATE_DIR}/issue-<iid>.json` to `issue-<iid>.json.bak-<ts>`
     - write a fresh per-issue file with `status=pending`, `retry_count=0`, `mode="continue"`
     - clear any `active_issue_iid` referencing this IID
     - force `campaign_status = running`
     - persist `campaign_state.json`
   - Else if disk says finished but `is_done_on_gitlab == false` (i.e. `user_reopened == true`):
     - same as above, but the per-issue file gets `mode="fresh"` (default)
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
3. The dispatcher sends the executor a single `RUN_SINGLE_ISSUE_SESSION` message (see executor SKILL for the full payload).
4. **Strict serial.** Spawn one session, block on its terminal reply, re-read the per-issue state file, only then consider the next IID. This rule overrides any quota-driven reading.
5. **Single-spawn batches.** `sessions_spawn` for an issue is the only tool call in its tool-call batch.
6. **`active_issue_iid` is set before spawning and persisted; cleared / replaced only after the spawned session reports a terminal status.** Never holds more than one IID at a time.

---

## Dispatcher Algorithm

Run on every scheduled wake-up.

1. **Bootstrap.**
   - `PROJECT=<project> source scripts/env_paths.sh`
   - Acquire the flock above.
   - `GITLAB_HOST="$(bash scripts/glab_auth.sh)"`. If this fails, abort the tick.
2. **Load + override campaign state.**
   - Read `${CAMPAIGN_STATE_FILE}`, or initialize using fresh-init values from `references/state_schema.md` if absent.
   - Apply trigger-input override: overwrite `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks` with the trigger values.
   - Persist.
3. **Reconcile against GitLab — MANDATORY, ALWAYS RUNS.**
   - `MIN_IID=...; MAX_IID=...; PROJECT_FULL="${GROUP}/${PROJECT}"; bash scripts/reconcile.sh` (env-driven; see Source-of-Truth Policy).
   - Apply disk cache correction per the policy above.
   - Record the evidence file path into `campaign_state.json.last_reconcile_evidence`.
4. **Early-return only if allowed.** Permitted iff:
   - the evidence file from this tick exists
   - every IID in range has `is_done_on_gitlab == true` in it
   - `unfinished_iids` is empty and `campaign_status = completed`
   Otherwise continue.
5. `quota_completed_this_tick = 0`; record tick start time.
6. **Strictly serial loop.** While quota and time budget remain:
   1. Pick the lowest-IID eligible backlog item, else the next fresh IID from `next_new_issue_iid`.
   2. Set `active_issue_iid` and persist.
   3. Spawn (or resume) the dedicated session and send `RUN_SINGLE_ISSUE_SESSION` in a SINGLE blocking spawn call. If the per-issue state file has `mode="continue"` (set by reconciliation in Step 3 above), include `issue_mode=continue` in the trigger payload so the executor knows to reuse the existing work branch. Default is `issue_mode=fresh`.
   4. After the session returns, re-read `${ISSUE_STATE_DIR}/issue-<iid>.json` from disk.
   5. If terminal (`done` / `no_changes` / `failed`): update the corresponding list, increment `quota_completed_this_tick`.
   6. If `blocked`: keep in backlog; skip and continue.
   7. If `in_progress` and tick budget exhausted: keep as backlog for next tick.
   8. Clear / update `active_issue_iid` and persist before the next loop iteration.
7. Update `next_new_issue_iid` if fresh issues were introduced.
8. If every IID in `[issue_min_iid, issue_max_iid]` is terminal, set `campaign_status = completed`.
9. Persist `campaign_state.json` and return the compact chat summary.

Stop conditions: `quota_completed_this_tick == hourly_issue_quota`, time budget exhausted, or no eligible IID remains.

---

## Blocked Skip-and-Retry

1. Blocked issues record `block_reason` in their per-issue state file.
2. A blocked issue is retryable only after `blocked_cooldown_ticks` ticks have elapsed since the last attempt.
3. If `retry_count > blocked_retry_limit`, the issue may be marked `failed`.
4. A blocked issue must not permanently block later issues from using remaining quota.

---

## Terminal Completion Policy

Successful MR creation is the terminal completion condition. The executor labels the issue `done` and writes `status=done` immediately after MR creation. The dispatcher MUST NOT schedule that issue again unless reconciliation finds it user-reopened on GitLab.

---

## Chat Output Policy

Return a single compact JSON summary, e.g.:

```json
{
  "skill_version": "2026-04-24.9",
  "campaign_status": "running",
  "active_issue_iid": null,
  "active_issue_session": null,
  "unfinished_iids": [9, 10, 14],
  "next_new_issue_iid": 19,
  "quota_completed_this_tick": 3,
  "quota_target": 10,
  "last_reconcile_evidence": "/data/openclaw_work/<project>/openclaw_log/dispatcher/reconcile-<ts>.json"
}
```

Never paste full logs, full diffs, or long issue bodies into chat.
