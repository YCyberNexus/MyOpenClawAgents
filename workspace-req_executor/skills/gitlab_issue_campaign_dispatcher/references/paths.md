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

Repository-wide scheduler interruption evidence is stored outside individual
clones at `${EXECUTOR_SCHEDULER_ROOT}/mission_stop_archive/<stop_id>/`. It
contains stopped launch actions, undelivered callback entries, the pre-stop
campaign snapshot when present, and the compact public result. The hot files
are moved into this private archive rather than deleted.

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

`clone_or_pull.sh` appends `/.req_executor/` and `logs/` to `${REPO_PATH}/.git/info/exclude`. When a business change exists, `stage_and_guard.sh` force-adds `${OUTPUT_DIR}` and the complete staging-time `${LOG_DIR}` into the same Issue-branch commit; log-only runs still return `NO_CHANGES` for business-change classification. After terminal `worker_result.json` persistence, `archive_execution_logs.sh` appends the complete directory as the one log-only child on the same `${WORK_BRANCH}`. For a single-Issue branch, business `commit_sha` remains separate from the exact remote `work_branch_sha`; private hash-bound `attempt_finalized.json` is published only after both are persisted. It never creates another remote branch. Unrelated `logs/` paths remain local.

Claude Code is invoked only through `scripts/run_acpx_attempt.sh`, which changes directory to `${WORKTREE_DIR}` and runs the fixed acpx command against `${LOG_DIR}/prompt.txt`.

The worktree, output directory, and `LOCAL_ISSUE_BRANCH=issue/<iid>` are fixed
for one Issue. `EXECUTION_ID` is random and opaque; it selects an isolated state
file and log directory and fences stale callbacks without recording a run
number. Recovery files are atomically written only inside that execution's log
directory.
