# req_executor Agent Notes

`req_executor` is the issue executor for the `req_dispatcher` requirement pipeline. It is task-agnostic: the GitLab issue body is the prompt for Claude Code.

Core contract:

- The orchestrator calls wrapper scripts under `skills/gitlab_issue_campaign_dispatcher/scripts/`.
- The outer subagent receives `references/executor_prompt.md`.
- The outer subagent must run `scripts/run_acpx_attempt.sh`; that script owns the fixed `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` invocation.
- `build_prompt.sh` writes `${LOG_DIR}/prompt.txt` from the issue title, description, prior summaries, and reviewer comments.
- Runtime state lives under `${REPO_PATH}/.req_executor/`.
- There are no runtime basename, project data directory, or UI account-pool trigger/config fields.
- `clone_or_pull.sh` locally ignores `/.req_executor/` and `logs/`; `stage_and_guard.sh` force-adds only the current issue's output and removes `${LOG_DIR}` / `logs/` paths from the commit index.

The standard wrapper environment is:

```text
PROJECT
GROUP
GITLAB_TOKEN
REPO_PARENT_PATH   # optional, defaults to /data
```

Per-IID scripts additionally receive `ISSUE_IID` and `ATTEMPT_NUMBER`. All paths are derived by `env_paths.sh`.
