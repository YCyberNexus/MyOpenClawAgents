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
        executions/
          execution-<execution_id>.json
        summary.md
        dispatch_origin.json
    .worktrees/
      issue-<iid>/
        .req_executor/
          issue-<iid>/
            output/
            log/
              execution-<execution_id>/
```

## Key Variables

| Variable | Meaning |
| --- | --- |
| `RESULT_ROOT` | `${REPO_PATH}/.req_executor` |
| `WORK_ROOT` | `${RESULT_ROOT}/_dispatcher` |
| `ISSUES_ROOT` | `${RESULT_ROOT}/issues` |
| `WORKTREES_ROOT` | `${RESULT_ROOT}/.worktrees` |
| `ISSUE_ROOT` | `${ISSUES_ROOT}/issue-${ISSUE_IID}` |
| `EXECUTIONS_ROOT` | `${ISSUE_ROOT}/executions` |
| `WORKTREE_DIR` | `${WORKTREES_ROOT}/issue-${ISSUE_IID}` |
| `ISSUE_WORKTREE_REL` | `.req_executor/issue-${ISSUE_IID}` |
| `OUTPUT_DIR` | `${WORKTREE_DIR}/${ISSUE_WORKTREE_REL}/output` |
| `EXECUTION_STATE_FILE` | `${EXECUTIONS_ROOT}/execution-${EXECUTION_ID}.json` |
| `ISSUE_LOG_REL` | `${ISSUE_WORKTREE_REL}/log/execution-${EXECUTION_ID}` |
| `LOG_DIR` | `${WORKTREE_DIR}/${ISSUE_LOG_REL}` |

`clone_or_pull.sh` appends `/.req_executor/` and `logs/` to `${REPO_PATH}/.git/info/exclude`. `stage_and_guard.sh` force-adds only `${OUTPUT_DIR}` and removes `${LOG_DIR}` plus any `logs/` path from the commit index, so logs stay local and do not appear in MR changes.

Claude Code is invoked only through `scripts/run_acpx_attempt.sh`, which changes directory to `${WORKTREE_DIR}` and runs the fixed acpx command against `${LOG_DIR}/prompt.txt`.

The worktree, output directory, and `LOCAL_ISSUE_BRANCH=issue/<iid>` are fixed
for one Issue. `EXECUTION_ID` is random and opaque; it selects an isolated state
file and log directory and fences stale callbacks without recording a run
number. Recovery files are atomically written only inside that execution's log
directory.
