# State File Schemas

Disk state is a **cache**, not source of truth. GitLab is the source of truth (see Source-of-Truth Policy in `SKILL.md`). These files exist for progress tracking and resumption only.

There are three state files in this workspace:

| File                                       | Owner                          | Lifecycle                                     |
| ------------------------------------------ | ------------------------------ | --------------------------------------------- |
| `campaign_state.json`                      | dispatcher (campaign-level)    | persisted across ticks; mutated each tick     |
| `issues/issue-<iid>/state.json`            | dispatcher prep + subagent     | persisted across attempts; one per IID        |
| `issues/issue-<iid>/attempt_state.json`    | dispatcher prep + subagent     | overwritten on each new attempt               |

The subagent receives the per-issue and attempt-state file paths through the rendered prompt and updates them via `jq` rewrites at the terminal step. The dispatcher's prep also writes initial values into both files before spawn.

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
  "skill_version": "2026-05-06.1",
  "last_reconcile_evidence": "/data/openclaw_work/.../openclaw_log/dispatcher/reconcile-20260506T100501Z.json",
  "updated_at": "2026-05-06T10:05:30Z"
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

`completed` may only be set when reconciliation has just run AND every IID in range has `is_done_on_gitlab == true` (live state is `closed` OR live labels contain both `done` and `pr`) AND `needs_continue == false` in the evidence file.

## issue-<iid>/state.json — cross-attempt issue state

Path: `${ISSUE_STATE_FILE}` = `${ISSUE_ROOT}/state.json`

Initialized by `scripts/allocate_attempt.sh` (which the dispatcher runs before each spawn). Then the dispatcher's prep refreshes `status` / `mode` / `attempts_total` / `latest_attempt_*` / `skill_version` before spawn. The subagent updates the terminal `status`, `commit_sha`, `merge_request_url`, `block_reason` at the end of its run.

```json
{
  "iid": 14,
  "session": "issue-px_ifp_hulat_test-14",
  "status": "in_progress",
  "mode": "continue",
  "attempts_total": 2,
  "latest_attempt_number": 2,
  "latest_attempt_dir": "/data/openclaw_work/.../issues/issue-14",
  "retry_count": 1,
  "block_reason": null,
  "commit_sha": "abc1234...",
  "merge_request_url": "http://gitlab.example.com/.../merge_requests/15",
  "skill_version": "2026-05-06.1",
  "updated_at": "2026-05-06T10:00:00Z"
}
```

| Field                   | Type            | Notes                                                                  |
| ----------------------- | --------------- | ---------------------------------------------------------------------- |
| `iid`                   | int             | GitLab issue IID this session is bound to.                             |
| `session`               | string          | Dedicated session name `issue-<project>-<iid>`.                        |
| `status`                | string (enum)   | See "Possible status values" below. This is the latest attempt's terminal status (or `in_progress` mid-flight). |
| `mode`                  | string (enum)   | `"fresh"` or `"continue"` for the latest attempt.                      |
| `attempts_total`        | int             | Number of attempts ever launched for this IID.                         |
| `latest_attempt_number` | int             | Same number as `${ATTEMPT_NUMBER}` of the most recent attempt.         |
| `latest_attempt_dir`    | string          | Convenience absolute path; matches `${ATTEMPT_DIR}`. In the current layout this is `${ISSUE_ROOT}`. |
| `retry_count`           | int             | How many times this issue has entered `blocked` (across attempts).     |
| `block_reason`          | string \| null  | Required when `status=blocked` or `failed`.                            |
| `commit_sha`            | string \| null  | Latest pushed commit SHA when applicable.                              |
| `merge_request_url`     | string \| null  | Strategy A: single MR per issue in fresh mode; rotated in continue mode. |
| `skill_version`         | string          | Must equal the `SKILL_VERSION` in `SKILL.md`.                          |
| `updated_at`            | ISO-8601 UTC    | Update at every major step.                                            |

### Possible `status` values

| Status        | When written                                                                 | Terminal? |
| ------------- | ---------------------------------------------------------------------------- | --------- |
| `pending`     | After dispatcher reconciliation re-enqueues; before dispatcher prep starts.  | no        |
| `in_progress` | After dispatcher prep finishes (worktree + prompt ready); during Claude execution and post-acpx subagent flow. | no |
| `blocked`     | Retryable failure (auth, runtime mismatch, leak guard tripped, dispatcher prep failed for this IID, etc.). | no |
| `failed`      | Non-recoverable, or `retry_count > blocked_retry_limit`.                     | yes       |
| `done`        | After post-push verification, Wiki evidence publication, `doing → done`, MR creation / rotation, and `pr` label addition succeeded. | yes |
| `no_changes`  | Claude produced no diff (`stage_and_guard.sh` printed `NO_CHANGES`).         | yes       |

## issue-<iid>/attempt_state.json — current-attempt state

Path: `${ATTEMPT_STATE_FILE}` = `${ATTEMPT_DIR}/attempt_state.json`

Each attempt overwrites this file with the current attempt's details. Older local attempt-state files are not preserved on disk; durable history is kept in GitLab attempt-summary notes and in the monotonically increasing attempt counters.

```json
{
  "iid": 14,
  "attempt_number": 2,
  "attempt_started_at": "2026-05-06T09:55:00Z",
  "attempt_finished_at": "2026-05-06T09:59:42Z",
  "mode_requested": "continue",
  "mode_actual": "continue",
  "mode_downgraded_from": null,
  "no_reviewer_comments": false,
  "prior_attempt_count": 1,
  "local_branch": "issue/14-auto-fix-att002",
  "log_dir": "/data/openclaw_work/.../issues/issue-14/log/attempt-002",
  "commit_sha": "abc1234...",
  "wiki_artifacts_file": "/data/openclaw_work/.../issues/issue-14/log/attempt-002/wiki_artifacts.md",
  "attempt_artifacts_posted_to_wiki": true,
  "status": "done",
  "block_reason": null,
  "summary_file": "/data/openclaw_work/.../issues/issue-14/summary.md",
  "summary_posted_to_issue": true,
  "skill_version": "2026-05-06.1"
}
```

| Field                     | Notes                                                                                    |
| ------------------------- | ---------------------------------------------------------------------------------------- |
| `attempt_number`          | matches `${ATTEMPT_NUMBER}` for this attempt                                              |
| `mode_requested`          | what reconciliation / per-issue state asked for (`fresh` or `continue`)                   |
| `mode_actual`             | what `prepare_attempt.sh` ended up running (continue can downgrade to fresh)              |
| `mode_downgraded_from`    | non-null only when `mode_actual=fresh` but `mode_requested=continue` and the remote branch was missing |
| `no_reviewer_comments`    | continue mode only — true if `build_prompt.sh` reported `CONTINUE_MODE_NO_REVIEWER_COMMENTS=true` |
| `prior_attempt_count`     | continue mode only — number of past `acpx_auto_tester:attempt-summary` notes (plus legacy pre-rename attempt-summary notes) the prompt included |
| `local_branch`            | per-attempt local branch (`${LOCAL_ATTEMPT_BRANCH}`)                                      |
| `log_dir`                 | `${LOG_DIR}` for this attempt                                                             |
| `wiki_artifacts_file`     | `${LOG_DIR}/wiki_artifacts.md` once `upload_attempt_artifacts.sh` has posted Wiki links to GitLab |
| `attempt_artifacts_posted_to_wiki` | true after `prompt.txt`, `claude_result.txt`, and optional `report.html` were published to the project Wiki and linked from the issue |
| `summary_file`            | `${SUMMARY_FILE}` once `summarize_attempt.sh` has run                                     |
| `summary_posted_to_issue` | true after the summary was successfully posted as a GitLab issue note                     |

The dispatcher initializes `attempt_started_at`, `mode_*`, `no_reviewer_comments`, `prior_attempt_count`, `local_branch`, `log_dir`, `status="in_progress"`, `skill_version` before spawn. The subagent updates everything else and the terminal `status` / `attempt_finished_at` at the end of its run.
