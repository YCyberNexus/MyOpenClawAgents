# Per-Issue and Per-Attempt State Schemas (Executor)

As of SKILL_VERSION 2026-04-25.1 the executor maintains state at TWO levels: one cross-attempt file per issue, and one file per attempt.

## issue-<iid>/state.json — cross-attempt issue state

Path: `${ISSUE_STATE_FILE}` = `${ISSUE_ROOT}/state.json`

```json
{
  "iid": 14,
  "session": "issue-px_ifp_hulat_test-14",
  "status": "in_progress",
  "mode": "continue",
  "attempts_total": 2,
  "latest_attempt_number": 2,
  "latest_attempt_dir": "/data/openclaw_work/.../issues/issue-14/attempts/attempt-002",
  "retry_count": 1,
  "block_reason": null,
  "merge_request_url": "http://gitlab.example.com/.../merge_requests/15",
  "skill_version": "2026-04-25.1",
  "updated_at": "2026-04-25T10:00:00Z"
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
| `latest_attempt_dir`    | string          | Convenience absolute path; matches `${ATTEMPT_DIR}` of latest attempt. |
| `retry_count`           | int             | How many times this issue has entered `blocked` (across attempts).     |
| `block_reason`          | string \| null  | Required when `status=blocked` or `failed`.                            |
| `merge_request_url`     | string \| null  | Strategy A: single MR per issue; this URL is reused across attempts.   |
| `skill_version`         | string          | Must equal the `SKILL_VERSION` in `SKILL.md`.                          |
| `updated_at`            | ISO-8601 UTC    | Update at every major step.                                            |

### Possible `status` values

| Status        | When written                                                                 | Terminal? |
| ------------- | ---------------------------------------------------------------------------- | --------- |
| `pending`     | After dispatcher reconciliation re-enqueues; before executor starts running. | no        |
| `in_progress` | After `prepare_attempt.sh` returns; during Claude execution.                 | no        |
| `blocked`     | Retryable failure (auth, runtime mismatch, leak guard tripped, etc.).        | no        |
| `failed`      | Non-recoverable, or `retry_count > blocked_retry_limit`.                     | yes       |
| `done`        | After MR creation succeeded and post-push verification passed.               | yes       |
| `no_changes`  | Claude produced no diff (`stage_and_guard.sh` printed `NO_CHANGES`).         | yes       |

## attempt-<NNN>/attempt_state.json — per-attempt state

Path: `${ATTEMPT_STATE_FILE}` = `${ATTEMPT_DIR}/attempt_state.json`

Each attempt writes one of these. Older attempts' files are preserved for audit; never delete them.

```json
{
  "iid": 14,
  "attempt_number": 2,
  "attempt_started_at": "2026-04-25T09:55:00Z",
  "attempt_finished_at": "2026-04-25T09:59:42Z",
  "mode_requested": "continue",
  "mode_actual": "continue",
  "mode_downgraded_from": null,
  "no_reviewer_comments": false,
  "prior_attempt_count": 1,
  "local_branch": "issue/14-auto-fix-att002",
  "commit_sha": "abc1234...",
  "status": "done",
  "block_reason": null,
  "summary_file": "/data/openclaw_work/.../attempts/attempt-002/summary.md",
  "summary_posted_to_issue": true,
  "skill_version": "2026-04-25.1"
}
```

| Field                     | Notes                                                                                    |
| ------------------------- | ---------------------------------------------------------------------------------------- |
| `attempt_number`          | matches `${ATTEMPT_NUMBER}` for this attempt                                              |
| `mode_requested`          | what the dispatcher asked for via `issue_mode=...` (or what the executor inferred)        |
| `mode_actual`             | what `prepare_attempt.sh` ended up running                                                |
| `mode_downgraded_from`    | non-null only when `mode_actual=fresh` but `mode_requested=continue` and the remote branch was missing |
| `no_reviewer_comments`    | continue mode only — true if `build_prompt.sh` reported `CONTINUE_MODE_NO_REVIEWER_COMMENTS=true` |
| `prior_attempt_count`     | continue mode only — number of past `uiautotester:attempt-summary` notes the prompt included |
| `local_branch`            | per-attempt local branch (`${LOCAL_ATTEMPT_BRANCH}`)                                      |
| `summary_file`            | `${SUMMARY_FILE}` once `summarize_attempt.sh` has run                                     |
| `summary_posted_to_issue` | true after the summary was successfully posted as a GitLab issue note                     |

The executor MUST update `attempt_state.json` at every major step inside the attempt (mirroring the issue-level `state.json` cadence). When the attempt reaches a terminal status, both files are updated atomically: per-attempt first (with full detail), then issue-level (which copies the latest summary fields).
