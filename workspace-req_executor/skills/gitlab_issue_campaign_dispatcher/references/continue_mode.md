# Continue Mode

`continue` is the only resume signal. The dispatcher enters continue mode only when the live GitLab issue has the `continue` label.

Flow:

1. `allocate_attempt.sh` allocates the next attempt number.
2. `prepare_attempt.sh` reuses `${WORKTREE_DIR}` for the IID.
3. Continue mode bases the worktree on `origin/${WORK_BRANCH}` when available, otherwise on the fixed local `issue/<iid>` branch; if neither exists, it downgrades to fresh mode.
4. `prepare_attempt.sh` resets the same local issue branch in place. It creates no per-attempt branch, runtime snapshot, or log archive.
5. `build_prompt.sh` includes past attempt summaries and reviewer comments in the fixed `${LOG_DIR}/prompt.txt`.
6. The outer subagent still runs the same one-call
   `scripts/run_executor_attempt.sh` workflow; its internal
   `run_acpx_attempt.sh` invocation does not change between fresh and continue
   mode.

Fresh mode resets the same local issue branch to the selected clean baseline. The issue-local runtime and log paths remain fixed; later runs overwrite current-result evidence rather than moving it into attempt-specific directories.
