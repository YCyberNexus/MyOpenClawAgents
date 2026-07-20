# Continue Mode

`continue` is the only resume signal. The dispatcher enters continue mode only when the live GitLab issue has the `continue` label.

Flow:

1. `allocate_execution_id.sh` generates a new random opaque execution identity.
2. `prepare_attempt.sh` reuses `${WORKTREE_DIR}` for the IID.
3. Continue mode bases the worktree on `origin/${WORK_BRANCH}` when available, otherwise on the fixed local `issue/<iid>` branch; if neither exists, it downgrades to fresh mode.
4. `prepare_attempt.sh` resets the same local issue branch in place. It creates no numbered branch or runtime snapshot; the new execution receives its own log directory.
5. `build_prompt.sh` includes all non-system issue comments in the fixed `${LOG_DIR}/prompt.txt`; continue mode also separates historical agent-posted summaries from those comments.
6. The outer subagent still runs the same one-call
   `scripts/run_executor_attempt.sh` workflow; its internal
   `run_acpx_attempt.sh` invocation does not change between fresh and continue
   mode.

Fresh mode resets the same local issue branch to the selected clean baseline, while still including the current issue comments in the Claude Code prompt. Each execution receives isolated state and log paths, so a later run cannot overwrite earlier runtime evidence. Summaries remain local and are never posted back to the issue.
