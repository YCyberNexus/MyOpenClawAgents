# Per-Issue State Schema (Executor)

Path: `${ISSUE_STATE_FILE}` (i.e. `/data/openclaw_work/${PROJECT}/openclaw_state/issues/issue-<iid>.json`)

```json
{
  "iid": 14,
  "session": "issue-px_ifp_hulat_test-14",
  "status": "in_progress",
  "mode": "fresh",
  "mode_downgraded_from": null,
  "retry_count": 1,
  "block_reason": null,
  "work_branch": "issue/14-auto-fix",
  "commit_sha": null,
  "merge_request_url": null,
  "skill_version": "2026-04-24.9",
  "updated_at": "2026-04-24T10:00:00Z"
}
```

## Field meanings

| Field                  | Type            | Notes                                                            |
| ---------------------- | --------------- | ---------------------------------------------------------------- |
| `iid`                  | int             | The GitLab issue IID this session is bound to.                   |
| `session`              | string          | Dedicated session name `issue-<project>-<iid>`.                  |
| `status`               | string (enum)   | See "Possible status values" below.                              |
| `mode`                 | string (enum)   | `"fresh"` (default) or `"continue"`. Set in Step 6 of the executor algorithm. |
| `mode_downgraded_from` | string \| null  | Non-null only when the executor was asked for `continue` mode but `prepare_branch.sh` had to fall back to fresh because no remote branch existed. Value is the originally requested mode (`"continue"`). Lets the operator audit unexpected fresh runs. |
| `retry_count`          | int             | How many times this issue has entered `blocked`.                 |
| `block_reason`         | string \| null  | Human-readable reason; required when `status=blocked` or `failed`. |
| `work_branch`          | string \| null  | Set after `prepare_branch.sh` runs.                              |
| `commit_sha`           | string \| null  | Set after `commit_and_push.sh` returns.                          |
| `merge_request_url`    | string \| null  | Set after `create_mr.sh` returns the URL.                        |
| `skill_version`        | string          | Must equal the `SKILL_VERSION` in `SKILL.md`.                    |
| `updated_at`           | ISO-8601 UTC    | Update at every major step.                                      |

## Possible `status` values

| Status        | When written                                                                 | Terminal? |
| ------------- | ---------------------------------------------------------------------------- | --------- |
| `pending`     | Initial state if file is being created from scratch.                         | no        |
| `in_progress` | After `prepare_branch.sh`, before / during Claude execution.                 | no        |
| `blocked`     | Retryable failure (auth fail, runtime mismatch, leak guard tripped, etc.).   | no        |
| `failed`      | Non-recoverable, or `retry_count > blocked_retry_limit`.                     | yes       |
| `done`        | After MR successfully created and post-push verification passed.             | yes       |
| `no_changes`  | Claude produced no diff (`stage_and_guard.sh` printed `NO_CHANGES`).         | yes       |

## Update cadence

The executor must update the state file at each of these steps:

1. After `prepare_branch.sh` — write `work_branch`, `status=in_progress`.
2. After Claude Code returns — keep `status=in_progress`.
3. After `stage_and_guard.sh` — if `NO_CHANGES`, write `status=no_changes` and stop.
4. After `commit_and_push.sh` — write `commit_sha`.
5. After `post_push_verify.sh` — if `REMOTE_POLLUTED`, write `status=blocked` with reason and stop.
6. After `create_mr.sh` — write `merge_request_url` then `status=done`.
7. On any failure — write `status=blocked` (or `failed` if exhausted) with `block_reason`, increment `retry_count`.
