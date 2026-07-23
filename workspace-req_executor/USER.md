# req_executor User Notes

- `RUN_SINGLE_ISSUE` is driven by `req_dispatcher` and carries `project` + `iid` or a GitLab `issue_url`, plus `correlation_id`, `dispatcher_callback_target`, optional `branch`, and optional `group`.
- GitLab host/protocol/token fallback and campaign defaults are pinned under `config/`.
- The issue content is rendered into `${LOG_DIR}/prompt.txt` and passed to Claude Code through `run_acpx_attempt.sh`.
- Runtime state is fixed at `${REPO_PATH}/.req_executor/`.
- `/slot <positive-integer>` updates the parallel-repository ceiling shared by
  every batch session under one executor scheduler root. Issues from the same
  GitLab repository run serially; different repositories may run in parallel.
- `/timeout-executor <duration>` updates the acpx cap for future attempts. Examples:
  `/timeout-executor 1h`, `/timeout-executor 90m`, `/timeout-executor 3600`. Future
  dispatcher-side outer timeouts follow the persisted value; the OpenClaw
  global timeout remains an independent deployment setting.
- `/mission-stop <GitLab repository URL|group/project>` interrupts all durable
  work for that repository, archives private recovery evidence, and frees the
  scheduler/project state so the repository can be submitted again.
- No project data directory, runtime basename, or UI account-pool fields are part of the current req_executor contract.
