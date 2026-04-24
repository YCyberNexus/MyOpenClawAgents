---
name: gitlab_issue_campaign_dispatcher
description: Run a recurring scheduled GitLab issue campaign using one lightweight dispatcher session plus one dedicated session per issue. Supports quota carryover, backlog-first scheduling, blocked skip-and-retry, persistent disk state, and compact dispatcher chat output.
allowed-tools: Bash, Read, Write, Edit
---

# GitLab Issue Campaign Dispatcher Skill

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
3. If `campaign_status = completed`, return immediately.
4. Set `quota_completed_this_tick = 0`.
5. Set tick start time.
6. Repeatedly choose the next eligible issue while quota and time budget remain:
   - first choose the lowest-IID unfinished backlog item eligible for processing
   - if none exists, choose the next fresh IID beginning at `next_new_issue_iid`
7. For the chosen IID:
   - create or resume its dedicated issue session
   - send `RUN_SINGLE_ISSUE_SESSION`
   - read its per-issue state file afterward
8. If the per-issue state becomes terminal for the campaign step (`done`, `no_changes`, `failed`):
   - add the IID to terminal state collections
   - remove it from unfinished backlog
   - increment `quota_completed_this_tick`
9. If the issue remains `blocked`:
   - keep it in backlog
   - do not increment completed quota
   - continue with later eligible issues if policy permits
10. If the issue remains `in_progress` and the current tick ends, keep it as active backlog for the next wake-up.
11. Update `next_new_issue_iid` whenever fresh issues are introduced.
12. If all issues from `issue_min_iid` through `issue_max_iid` are terminal, set `campaign_status = completed`.
13. Persist `campaign_state.json`.
14. Return only a compact dispatcher summary.

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
