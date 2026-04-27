# State File Schemas (Dispatcher)

Disk state is a **cache**, not the source of truth. GitLab is the source of truth (see Source-of-Truth Policy in `SKILL.md`). These files exist for progress tracking and resumption only.

## campaign_state.json

Path: `${CAMPAIGN_STATE_FILE}` (i.e. `/data/openclaw_work/${PROJECT}/openclaw_state/campaign_state.json`)

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
  "next_new_issue_iid": 4,
  "active_issue_iid": null,
  "active_issue_session": null,
  "unfinished_iids": [],
  "completed_iids": [1, 2, 3],
  "blocked_iids": [],
  "failed_iids": [],
  "campaign_status": "running",
  "skill_version": "2026-04-24.4",
  "last_reconcile_evidence": "/data/openclaw_work/.../openclaw_log/dispatcher/reconcile-20260424T100501Z.json",
  "updated_at": "2026-04-24T10:05:30Z"
}
```

### Fresh-init values (when the file does not exist)

```text
next_new_issue_iid    = issue_min_iid
active_issue_iid      = null
active_issue_session  = null
unfinished_iids       = []
completed_iids        = []
blocked_iids          = []
failed_iids           = []
campaign_status       = running
```

### Possible `campaign_status` values

- `running`
- `completed`

`completed` may only be set when reconciliation has just run AND every IID in range has `is_done_on_gitlab == true` in the evidence file.

## issue-<iid>.json

Path: `${ISSUE_STATE_DIR}/issue-<iid>.json`

```json
{
  "iid": 9,
  "session": "issue-px_ifp_hulat_test-9",
  "status": "blocked",
  "mode": "continue",
  "retry_count": 2,
  "last_attempt_tick": 12,
  "next_retry_tick": 13,
  "block_reason": "Claude Code runtime requires GLIBC 2.29+",
  "work_branch": null,
  "commit_sha": null,
  "merge_request_url": null,
  "skill_version": "2026-04-24.9",
  "updated_at": "2026-04-24T10:00:00Z"
}
```

`mode` is set to `"continue"` when reconciliation observed the `continue` label on this IID; the dispatcher then includes `issue_mode=continue` in the trigger sent to the executor session. Default is `"fresh"`.

### Possible `status` values

- `pending`     — not yet attempted this campaign
- `in_progress` — executor session is currently running
- `blocked`     — retryable failure; will be retried after `blocked_cooldown_ticks`
- `failed`      — non-recoverable or retry-exhausted
- `done`        — MR successfully created (terminal)
- `no_changes`  — Claude produced no diff (terminal)
