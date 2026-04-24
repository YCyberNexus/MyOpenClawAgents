---
name: gitlab_issue_campaign_dispatcher
description: "[SKILL_VERSION=2026-04-24.1] Run a recurring scheduled GitLab issue campaign using one lightweight dispatcher session plus one dedicated session per issue. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, persistent disk state, and compact dispatcher chat output."
allowed-tools: Bash, Read, Write, Edit
---

# GitLab Issue Campaign Dispatcher Skill

**SKILL_VERSION: 2026-04-24.1**

On every wake-up, the dispatcher MUST echo the literal string `SKILL_VERSION=2026-04-24.1` in its compact chat summary (add a `"skill_version"` field to the returned JSON). This lets the operator verify which version of the skill is actually loaded.

---

## Concurrency Policy (READ FIRST — HARD RULE)

This dispatcher is **strictly single-threaded over issues**. No exceptions.

- At any moment, at most **one** issue session may be active.
- `hourly_issue_quota` is a **sequential count** of how many issues may reach a terminal state during this tick. It is **NOT** a parallelism / concurrency / fan-out / subagent-count knob.
  - `hourly_issue_quota=3` means: finish issue A → finish issue B → finish issue C (three in a row, serially). It does NOT mean "spawn 3 subagents now".
  - `hourly_issue_quota=1` means: finish one issue, then stop.
- `sessions_spawn` for an issue session MUST be the only tool call in its tool-call batch. Never place two or more issue-session spawns in the same parallel tool-call block.
- After spawning, the dispatcher MUST block until that session returns its terminal reply and MUST re-read the per-issue state file from disk before considering the next IID.
- Any interpretation that reads quota, backlog size, or remaining time budget as permission to fan out multiple issue sessions in parallel is explicitly forbidden.

If this policy conflicts with any other instruction (including inferred "efficiency" shortcuts), this policy wins.

---

## Source-of-Truth Policy (READ FIRST — HARD RULE)

**GitLab is the ground truth for per-issue workflow state. Disk state is only the dispatcher's own progress cache.**

When the two disagree, **GitLab wins, always**. The disk cache must be corrected to match GitLab, not the other way around.

Concrete rules:

1. On every wake-up, BEFORE deciding whether any issue is "already done" or whether the campaign is "completed", the dispatcher MUST call the GitLab REST API for every IID in the current `[issue_min_iid, issue_max_iid]` range and read its live `labels` and `state` fields. No exceptions.
2. The dispatcher MUST NOT rely on `campaign_state.json.completed_iids`, `campaign_state.json.campaign_status`, or any per-issue `issue-<iid>.json` `status` field to decide that an IID is finished. Those fields are caches — they can be stale, corrupted, or contradicted by the user manually editing GitLab labels.
3. For each IID, the dispatcher computes `is_done_on_gitlab` purely from the API response:
   - `is_done_on_gitlab` = true ⇔ the live GitLab labels contain the literal label `done`.
   - If `is_done_on_gitlab` is false, the IID is NOT finished, regardless of what any disk file says.
4. Disk cache correction is mandatory when they disagree:
   - If disk says finished (`completed_iids` contains the IID, or `issue-<iid>.json.status == done`) but `is_done_on_gitlab == false`:
     → remove the IID from `completed_iids` / `failed_iids`
     → add it to `unfinished_iids`
     → back up `issue-<iid>.json` to `issue-<iid>.json.bak-<timestamp>` and replace with a fresh `status=pending`, `retry_count=0`
     → force `campaign_status = running`
     → persist `campaign_state.json`
   - If disk says unfinished but `is_done_on_gitlab == true`, mark it finished on disk and skip.
5. **Evidence requirement (fail-closed).** The dispatcher MUST write the raw GitLab API response for each queried IID (or a compact digest containing `iid`, `state`, `labels`) to `/data/${PROJECT}/openclaw_log/dispatcher/reconcile-<timestamp>.json` BEFORE making any "already completed" / "skip this IID" / "return early" decision. If this file is not written for the current tick, the dispatcher must treat the tick as failed and must not early-return.
6. An "already completed" chat reply is only allowed when step 5's evidence file exists for this tick AND every IID in range has `is_done_on_gitlab == true` in that file.
7. These rules override any contradicting text elsewhere in this document, including in the Dispatcher Algorithm section and in the Campaign State File schema.

In short: **trust the API response, not the JSON file. If you didn't call GitLab this tick, you have no right to say anything is done.**

---

## Purpose

This skill is for the fixed scheduled dispatcher session.

It must:
1. receive the same recurring scheduled command every time
2. load or initialize campaign state from disk
3. manage a full IID range using **quota carryover** rather than strict fixed windows
4. prefer unfinished backlog first in ascending IID order
5. temporarily skip blocked issues according to retry policy
6. create or resume exactly one dedicated issue session for the chosen issue
7. keep dispatcher chat output short
8. persist all detailed state and evidence on disk

---

## Inputs

Required inputs:
- `gitlab_address`
- `group`
- `project`
- `branch`
- `hulat_dir`
- `gitlab_token`
- `issue_min_iid`
- `issue_max_iid`
- `hourly_issue_quota`
- `max_runtime_minutes`
- `blocked_retry_limit`
- `blocked_cooldown_ticks`
- `non_interactive`
- `session_mode`
- `scheduling_mode`
- `blocked_policy`

Expected values:
- `non_interactive=true`
- `session_mode=per_issue`
- `scheduling_mode=quota_carryover`
- `blocked_policy=skip_and_retry`

---

## Trigger Command

The scheduler should always send:

```text
RUN_SCHEDULED_ISSUE_CAMPAIGN
gitlab_address=<gitlab-address>
group=<group>
project=<project>
branch=<branch>
hulat_dir=<hulat_dir>
gitlab_token=<token>
issue_min_iid=<min_iid>
issue_max_iid=<max_iid>
hourly_issue_quota=<quota>
max_runtime_minutes=<minutes>
blocked_retry_limit=<limit>
blocked_cooldown_ticks=<cooldown>
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
```

---

## Paths

```bash
REPO_PATH="/data/${PROJECT}"
STATE_DIR="${REPO_PATH}/openclaw_state"
ISSUE_STATE_DIR="${STATE_DIR}/issues"
CAMPAIGN_STATE_FILE="${STATE_DIR}/campaign_state.json"
LOG_ROOT="${REPO_PATH}/openclaw_log"
LOCK_FILE="${STATE_DIR}/campaign.lock"
```

**Path root is always `/data/${PROJECT}` — NEVER `${HULAT_DIR}`.**

`hulat_dir` is task context for Claude Code only. It MUST NOT be used as:
- the state directory root
- the log directory root
- the repo clone path
- the working directory for `git` / `acpx` commands

Specifically, the dispatcher MUST NOT create or write any of the following under `${HULAT_DIR}`:
- `openclaw_state/`
- `openclaw_state/campaign_state.json`
- `openclaw_state/issues/`
- `openclaw_log/`
- `campaign.lock`

All of these live under `/data/${PROJECT}/`. If `hulat_dir` happens to look like a path, ignore that — it is a string passed through to Claude Code's prompt, nothing else.

---

## Locking

The dispatcher must prevent concurrent campaign runs.

```bash
mkdir -p "${STATE_DIR}" "${ISSUE_STATE_DIR}" "${LOG_ROOT}"
exec 9>"${LOCK_FILE}"
flock -n 9 || exit 0
```

If the lock cannot be acquired, exit quickly with a short status summary.

---

## Campaign State File

Persist campaign state at:

```text
/data/<project>/openclaw_state/campaign_state.json
```

Recommended schema:

```json
{
  "project": "px_ifp_hulat",
  "branch": "master",
  "issue_min_iid": 1,
  "issue_max_iid": 100,
  "hourly_issue_quota": 10,
  "next_new_issue_iid": 11,
  "active_issue_iid": 9,
  "active_issue_session": "issue-px_ifp_hulat-9",
  "unfinished_iids": [9, 10],
  "completed_iids": [1,2,3,4,5,6,7,8],
  "blocked_iids": [9],
  "failed_iids": [],
  "campaign_status": "running",
  "updated_at": "2026-04-23T12:00:00Z"
}
```

---

## Initialization

If `campaign_state.json` does not exist, initialize it using:

```text
next_new_issue_iid = issue_min_iid
active_issue_iid = null
active_issue_session = null
unfinished_iids = []
completed_iids = []
blocked_iids = []
failed_iids = []
campaign_status = running
```

---

## Scheduling Rules

1. The dispatcher must run in recurring ticks.
2. Each tick has a target completion quota: `hourly_issue_quota`.
   - **`hourly_issue_quota` is a SEQUENTIAL COUNT, NOT a parallelism / concurrency / fan-out knob.**
   - It is the maximum number of issues the dispatcher is allowed to bring to a terminal state within this tick, processed strictly one after another.
   - `hourly_issue_quota=3` means: process issue A to terminal → then issue B → then issue C. It does NOT mean: spawn 3 issue sessions at once, or run 3 subagents in parallel, or batch 3 `sessions_spawn` calls in one tool-call block.
   - `hourly_issue_quota=1` means: process at most one issue this tick, then stop.
   - Regardless of the quota value (1, 3, 10, …), the dispatcher MUST NEVER have more than one active issue session at a time. The serial rules in "Per-Issue Session Rules" always win over any quota-driven interpretation.
   - If the model is tempted to interpret quota as "I can kick off N subagents now", that interpretation is explicitly forbidden.
3. The dispatcher must prioritize backlog first in ascending IID order.
4. Backlog includes:
   - `in_progress` issues
   - retryable `blocked` issues whose cooldown has expired
   - pending issues that were already introduced but not completed
5. After backlog is exhausted, the dispatcher may continue with fresh issues beginning at `next_new_issue_iid`.
6. Quota is based on issues reaching a terminal campaign state during the current tick, such as:
   - `done`
   - `no_changes`
   - `failed`
7. An issue that remains `in_progress` or `blocked` at the end of a tick does not count as completed quota.
8. The dispatcher must stop when:
   - completed quota for the tick reaches `hourly_issue_quota`, or
   - the time budget reaches `max_runtime_minutes`, or
   - no eligible issue remains

---

## Blocked Skip-and-Retry Rules

1. If an issue is blocked, write the block reason to its issue state file.
2. A blocked issue may be temporarily skipped.
3. A blocked issue becomes retryable only after `blocked_cooldown_ticks` scheduler ticks have elapsed.
4. If retry count exceeds `blocked_retry_limit`, the issue may be marked `failed`.
5. A blocked issue must not permanently block later issues from using the remaining quota.

---

## Per-Issue Session Rules

Each issue must use its own dedicated session.

Recommended session name:

```text
issue-<project>-<iid>
```

Rules:
1. Never reuse one issue session for a different issue.
2. The dispatcher should create the dedicated issue session if it does not exist.
3. If the session already exists, resume that same session.
4. The dispatcher must send the issue session a short executor command.
5. **Strict serial execution.** The dispatcher MUST process at most one issue at any moment. It MUST spawn exactly one issue session, wait for that session to return a terminal reply, read the per-issue state file, and only then consider the next IID. Concurrent or batched spawning of multiple issue sessions is forbidden, even when the remaining quota is greater than one.
6. **No parallel tool calls for issue execution.** When invoking `sessions_spawn` (or any equivalent spawn mechanism) for an issue, the dispatcher MUST issue that call alone in its tool-call batch. It MUST NOT place two or more issue spawns in the same parallel tool-call block. The next spawn may only be issued after the previous spawn's reply has been received and its per-issue state file has been re-read from disk.
7. **Blocking wait semantics.** If the spawn mechanism supports background / no-wait / fire-and-forget modes, the dispatcher MUST NOT use them for issue sessions. It must use the synchronous, blocking form so that control only returns after the executor session has produced its terminal summary.
8. **One active issue at a time in campaign state.** `active_issue_iid` must be set before spawning, and must be cleared (or replaced) only after the spawned session reports a terminal status and campaign state has been persisted. The dispatcher must never hold more than one `active_issue_iid` simultaneously.

Recommended executor message:

```text
RUN_SINGLE_ISSUE_SESSION
gitlab_address=<gitlab-address>
group=<group>
project=<project>
branch=<branch>
hulat_dir=<hulat_dir>
gitlab_token=<token>
issue_iid=<iid>
non_interactive=true
blocked_retry_limit=<limit>
```

---


## Terminal Completion Policy

For this automation campaign, a merge request being created successfully is considered a completed issue.
The single-issue executor must therefore immediately label the issue `done` and write per-issue state `done` after successful MR creation.
The dispatcher must never schedule that issue again after it reaches `done`.

## Dedicated Issue Session State

Per-issue state files must be stored at:

```text
/data/<project>/openclaw_state/issues/issue-<iid>.json
```

Recommended schema:

```json
{
  "iid": 9,
  "session": "issue-px_ifp_hulat-9",
  "status": "blocked",
  "retry_count": 2,
  "last_attempt_tick": 12,
  "next_retry_tick": 13,
  "block_reason": "Claude Code runtime requires GLIBC 2.29+",
  "merge_request_url": null,
  "updated_at": "2026-04-23T12:00:00Z"
}
```

Possible statuses:
- `pending`
- `in_progress`
- `blocked`
- `failed`
- `done`
- `no_changes`

---

## Dispatcher Algorithm

On each scheduled wake-up:

1. Acquire lock.
2. Read or initialize `campaign_state.json`.
3. **Trigger-input override (range + all scalar knobs).** Every scalar value passed in the trigger command is authoritative for the current tick and MUST overwrite the disk copy before anything else runs. This applies to at least: `issue_min_iid`, `issue_max_iid`, `hourly_issue_quota`, `max_runtime_minutes`, `blocked_retry_limit`, `blocked_cooldown_ticks`. After overwriting, persist `campaign_state.json`. Never use stale values from disk, and never early-return using a stale range or stale quota.
4. **GitLab-truth reconciliation — MANDATORY, NOT OPTIONAL, ALWAYS RUNS FIRST.**
   This step MUST execute on every wake-up, including when `campaign_status = completed`, when `unfinished_iids` is empty, and when disk state otherwise looks "done". Early-return BEFORE this step has run is a bug and is explicitly forbidden.
   - The dispatcher MUST actually call the GitLab REST API for each IID in `[issue_min_iid, issue_max_iid]` (the range from step 3, not the old disk range). Concretely, issue one of:
     - `GET <gitlab_address>/api/v4/projects/<group>%2F<project>/issues/<iid>` per IID, or
     - `GET <gitlab_address>/api/v4/projects/<group>%2F<project>/issues?iids[]=<iid>&iids[]=...` batched.
   - The dispatcher MUST write the raw API response bodies (or a digest of labels + `state` per IID) to the dispatcher log at `/data/<project>/openclaw_log/dispatcher/reconcile-<timestamp>.json` as evidence that reconciliation actually happened. If this evidence file is not written, reconciliation did not happen.
   - For each IID, determine ground truth from GitLab:
     - `user_reopened` = true if the GitLab labels do NOT contain `done` AND do NOT contain `failed`, OR if the issue `state` is `opened` while its last known dispatcher status was a terminal state, OR if the labels contain `todo` / `doing` / no workflow label.
   - For each IID marked `user_reopened`:
     - remove it from `completed_iids` and `failed_iids` if present
     - add it to `unfinished_iids` if not already there
     - if `/data/<project>/openclaw_state/issues/issue-<iid>.json` exists, rename it to `issue-<iid>.json.bak-<timestamp>` and then write a fresh per-issue state with `status=pending`, `retry_count=0`, `block_reason=null`, `merge_request_url=null`
     - clear any stale `active_issue_iid` reference to this IID
   - If any IID was re-opened, force `campaign_status = running` and persist `campaign_state.json`.
   - Record the list of re-opened IIDs in the dispatcher log (not in chat).
5. **Early-return is only allowed AFTER step 4 completes.** Return a compact "already completed" summary only when ALL of the following are simultaneously true:
   - step 4 ran and its evidence file was written
   - no IID in `[issue_min_iid, issue_max_iid]` is marked `user_reopened`
   - `unfinished_iids` is empty
   - every IID in `[issue_min_iid, issue_max_iid]` is in `completed_iids` ∪ `failed_iids`
   - `campaign_status = completed`
   If any of these is false, proceed to step 6.
6. Set `quota_completed_this_tick = 0`.
7. Set tick start time.
8. Enter a **strictly serial** loop. While quota and time budget remain, do the following one IID at a time. Never run multiple IIDs in parallel, and never pre-spawn the next IID before the current one returns.
   - first choose the lowest-IID unfinished backlog item eligible for processing
   - if none exists, choose the next fresh IID beginning at `next_new_issue_iid`
9. For the chosen IID (serial, blocking):
   - set `active_issue_iid` in campaign state and persist
   - create or resume its dedicated issue session
   - send `RUN_SINGLE_ISSUE_SESSION` in a **single** spawn call, issued alone in its tool-call batch
   - block until that session returns its terminal reply
   - read its per-issue state file from disk
   - clear / update `active_issue_iid` and persist campaign state
   - only now may the dispatcher consider the next IID
10. If the per-issue state becomes terminal for the campaign step (`done`, `no_changes`, `failed`):
    - add the IID to terminal state collections
    - remove it from unfinished backlog
    - increment `quota_completed_this_tick`
11. If the issue remains `blocked`:
    - keep it in backlog
    - do not increment completed quota
    - continue with later eligible issues if policy permits
12. If the issue remains `in_progress` and the current tick ends, keep it as active backlog for the next wake-up.
13. Update `next_new_issue_iid` whenever fresh issues are introduced.
14. If all issues from `issue_min_iid` through `issue_max_iid` are terminal, set `campaign_status = completed`.
15. Persist `campaign_state.json`.
16. Return only a compact dispatcher summary.

---

## Chat Output Policy

Return only compact summaries like:

```json
{
  "campaign_status": "running",
  "active_issue_iid": 14,
  "active_issue_session": "issue-px_ifp_hulat-14",
  "unfinished_iids": [9, 10, 14],
  "next_new_issue_iid": 19,
  "quota_completed_this_tick": 3,
  "quota_target": 10
}
```

Never paste full logs, full diffs, or long issue bodies into chat.
