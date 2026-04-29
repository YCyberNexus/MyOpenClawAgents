# State File Schemas (Dispatcher)

Disk state is a **cache**, not source of truth. GitLab is the source of truth (see Source-of-Truth Policy in `SKILL.md`). These files exist for progress tracking and resumption only.

## campaign_state.json

Path: `${CAMPAIGN_STATE_FILE}` (i.e. `${WORK_ROOT}/openclaw_state/campaign_state.json`)

```json
{
  "project": "px_ifp_hulat_test",
  "branch": "master",
  "issue_min_iid": 1,
  "issue_max_iid": 12,
  "hourly_issue_quota": 3,
  "max_runtime_minutes": 55,
  "blocked_retry_limit": 3,
  "blocked_cooldown_ticks": 1,
  "max_concurrent_subagents": 1,
  "next_new_issue_iid": 4,
  "active_issue_iids": [],
  "active_issue_sessions": [],
  "unfinished_iids": [],
  "completed_iids": [1, 2, 3],
  "blocked_iids": [],
  "failed_iids": [],
  "campaign_status": "running",
  "skill_version": "2026-04-29.1",
  "last_reconcile_evidence": "/data/openclaw_work/.../openclaw_log/dispatcher/reconcile-20260425T100501Z.json",
  "updated_at": "2026-04-25T10:05:30Z"
}
```

### Fresh-init values (when the file does not exist)

```text
next_new_issue_iid        = issue_min_iid
max_concurrent_subagents  = 1
active_issue_iids         = []
active_issue_sessions     = []
unfinished_iids           = []
completed_iids            = []
blocked_iids              = []
failed_iids               = []
campaign_status           = running
```

### Schema migration: `active_issue_iid` → `active_issue_iids`

As of SKILL_VERSION 2026-04-29.1, the dispatcher tracks in-flight subagents as a list, not a scalar, to support `max_concurrent_subagents > 1`. On read:

- If the on-disk file has the legacy scalar `active_issue_iid` and no `active_issue_iids`, treat it as `active_issue_iids = [active_issue_iid]` (or `[]` if the scalar was `null`) for the in-memory state, and persist the new array form on the next write.
- Same applies to `active_issue_session` → `active_issue_sessions`.
- If `max_concurrent_subagents` is missing on read, default it to `1` and persist on the next write.

The dispatcher MUST NOT keep both the scalar and the array fields in the persisted file — pick one shape per write (the new array shape) and drop the legacy scalar from the JSON it writes.

### Possible `campaign_status` values

- `running`
- `completed`

`completed` may only be set when reconciliation has just run AND every IID in range has `is_done_on_gitlab == true` AND `needs_continue == false` in the evidence file.

## issue-<iid>/state.json (per-issue, owned by executor)

Path: `${ISSUES_ROOT}/issue-<iid>/state.json` (use `issue_state_file_for` helper)

This file is written and updated by the executor; the dispatcher only **reads** it (after a spawned executor session returns) and only **mutates** it during reconciliation when re-enqueuing an IID.

The full schema lives in the executor SKILL's `references/state_schema.md`. From the dispatcher's perspective the relevant fields are:

| Field             | Read by dispatcher? | Notes                                               |
| ----------------- | ------------------- | --------------------------------------------------- |
| `iid`             | yes                 | sanity                                              |
| `status`          | yes                 | `pending` / `in_progress` / `blocked` / `failed` / `done` / `no_changes` |
| `mode`            | dispatcher writes   | `fresh` (default) or `continue`                     |
| `attempts_total`  | dispatcher writes   | incremented atomically by `scripts/allocate_attempt.sh` before every executor spawn. Executor never modifies this. |
| `block_reason`    | yes (for chat)      | only when `status=blocked` / `failed`               |

Note: per-issue state previously lived at `${STATE_DIR}/issues/issue-<iid>.json`. That path is **gone** as of SKILL_VERSION 2026-04-25.1. The new path is `${ISSUES_ROOT}/issue-<iid>/state.json`. Old files, if any, should be migrated by the operator (the agent does not auto-migrate).
