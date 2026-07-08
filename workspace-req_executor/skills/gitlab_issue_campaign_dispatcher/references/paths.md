# Paths

`env_paths.sh` is the single source of path derivation.

## Repository Root

- `REPO_PARENT_PATH`: clone parent, defaults to `/data`.
- `REPO_PATH`: final project checkout, `${REPO_PARENT_PATH}/${PROJECT}`.
- `PROJECT_FULL`: `${GROUP}/${PROJECT}`.

`repo_path` in a trigger sets `REPO_PARENT_PATH`; it is a parent directory, not the final clone path.

## Runtime Root

`req_executor` always stores runtime state inside:

```text
${REPO_PATH}/.req_executor/
```

This directory name is fixed. It is not configurable through trigger fields or tracked config.

Layout:

```text
${REPO_PATH}/
  .req_executor/
    _dispatcher/
      campaign_state.json
      campaign.lock
      log/
      locks/repo.lock
    issues/
      issue-<iid>/
        state.json
        attempt_state.json
        summary.md
        dispatch_origin.json
    .worktrees/
      issue-<iid>/
        .req_executor/
          issue-<iid>/
            output/
            log/attempt-NNN/
```

## Key Variables

| Variable | Meaning |
| --- | --- |
| `RESULT_ROOT` | `${REPO_PATH}/.req_executor` |
| `WORK_ROOT` | `${RESULT_ROOT}/_dispatcher` |
| `ISSUES_ROOT` | `${RESULT_ROOT}/issues` |
| `WORKTREES_ROOT` | `${RESULT_ROOT}/.worktrees` |
| `ISSUE_ROOT` | `${ISSUES_ROOT}/issue-${ISSUE_IID}` |
| `WORKTREE_DIR` | `${WORKTREES_ROOT}/issue-${ISSUE_IID}` |
| `ISSUE_WORKTREE_REL` | `.req_executor/issue-${ISSUE_IID}` |
| `OUTPUT_DIR` | `${WORKTREE_DIR}/${ISSUE_WORKTREE_REL}/output` |
| `ATTEMPT_LOG_REL` | `${ISSUE_WORKTREE_REL}/log/attempt-${ATTEMPT_NUMBER_PADDED}` |
| `LOG_DIR` | `${WORKTREE_DIR}/${ATTEMPT_LOG_REL}` |

`clone_or_pull.sh` appends `/.req_executor/` and `logs/` to `${REPO_PATH}/.git/info/exclude`. `stage_and_guard.sh` force-adds only `${OUTPUT_DIR}` and removes `${LOG_DIR}` plus any `logs/` path from the commit index, so logs stay local and do not appear in MR changes.

Claude Code is invoked only through `scripts/run_acpx_attempt.sh`, which changes directory to `${WORKTREE_DIR}` and runs the fixed acpx command against `${LOG_DIR}/prompt.txt`.
