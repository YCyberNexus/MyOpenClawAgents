# req_executor User Notes

- `RUN_SINGLE_ISSUE` is driven by `req_dispatcher` and carries `project` + `iid` or a GitLab `issue_url`, plus `correlation_id`, `dispatcher_callback_target`, optional `branch`, and optional `group`.
- GitLab host/protocol/token fallback and campaign defaults are pinned under `config/`.
- The issue content is rendered into `${LOG_DIR}/prompt.txt` and passed to Claude Code through `run_acpx_attempt.sh`.
- Runtime state is fixed at `${REPO_PATH}/.req_executor/`.
- No project data directory, runtime basename, or UI account-pool fields are part of the current req_executor contract.
