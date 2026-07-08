# req_executor Runtime Contract

`req_executor` executes GitLab issues from the requirement pipeline. It does not assume a project-specific test framework or material directory. The issue title, description, prior attempt summaries, and reviewer comments are rendered into `${LOG_DIR}/prompt.txt`.

## Wrapper Flow

1. `dispatch_prepare_tick.sh` validates the trigger, reconciles GitLab labels, selects IIDs, prepares worktrees, builds prompts, and emits spawn entries.
2. The orchestrator calls `sessions_spawn` with the rendered outer executor prompt.
3. The outer subagent runs `scripts/run_acpx_attempt.sh`.
4. `run_acpx_attempt.sh` changes directory to `${WORKTREE_DIR}` and runs `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"`.
5. The outer subagent stages, pushes, creates/updates the MR, summarizes, and returns compact JSON.
6. `dispatch_followup.sh` validates the compact JSON, updates state and labels, and reports terminal driven results to `req_dispatcher` when applicable.

Terminal child sessions are not auto-cleaned for any final status. `done`, `blocked`, `failed`, and `timeout` all preserve the child session so operators can inspect tool output and local diagnostic context after a run.

## Paths

All paths are derived by `env_paths.sh`.

```text
${REPO_PATH}/
  .req_executor/
    _dispatcher/
    issues/issue-<iid>/
    .worktrees/issue-<iid>/
      .req_executor/issue-<iid>/output/
      .req_executor/issue-<iid>/log/attempt-NNN/
```

`clone_or_pull.sh` writes `/.req_executor/` and `logs/` to local `.git/info/exclude`. `stage_and_guard.sh` force-adds only `${OUTPUT_DIR}` and removes any `logs/` path plus `${LOG_DIR}` from the commit index.

## Removed Legacy Inputs

The current req_executor contract does not support:

- runtime basename trigger/config fields
- data directory trigger/config fields
- project-specific material paths
- UI account-pool trigger/config fields

If an issue needs credentials, fixtures, or project-specific context, the issue body must describe them.
