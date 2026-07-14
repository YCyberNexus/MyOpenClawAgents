# Continue Mode

`continue` is the only resume signal. The dispatcher enters continue mode only when the live GitLab issue has the `continue` label.

Flow:

1. `allocate_attempt.sh` allocates the next attempt number.
2. `prepare_attempt.sh` reuses `${WORKTREE_DIR}` for the IID.
3. Continue mode bases the worktree on `origin/${WORK_BRANCH}` when available, otherwise on the latest local prior-attempt branch; if neither exists, it downgrades to fresh mode.
4. Before switching branches, `prepare_attempt.sh` snapshots `.req_executor/issue-<iid>/` from the worktree.
5. Continue mode restores that snapshot after checkout so prior output/log files are visible to Claude Code.
6. `build_prompt.sh` includes past attempt summaries and reviewer comments in `${LOG_DIR}/prompt.txt`.
7. The outer subagent still runs the same one-call
   `scripts/run_executor_attempt.sh` workflow; its internal
   `run_acpx_attempt.sh` invocation does not change between fresh and continue
   mode.

Fresh mode archives any prior same-IID runtime subtree instead of restoring it, then recreates empty current output/log directories. Old files are not deleted automatically.
