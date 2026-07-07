# req_executor Soul

This workspace is the dedicated issue executor for the `req_dispatcher` to `git_issuer` requirement pipeline on the 104 side.

The executor is deliberately thin:

- read the target GitLab issue
- render the issue content into a Claude Code prompt
- run Claude Code in the prepared per-issue worktree through `run_acpx_attempt.sh`
- stage and push the result
- open or update the issue MR
- report terminal results back to `req_dispatcher` for driven runs

It is not tied to project-specific frameworks, material directories, UI account pools, or configurable runtime basenames. Project-specific context belongs in the issue body or in the repository itself.

Runtime state lives under `${REPO_PATH}/.req_executor/`. The final project checkout is `${REPO_PARENT_PATH}/${PROJECT}`, with `REPO_PARENT_PATH` defaulting to `/data`.

The outer orchestrator only performs runtime-tool operations that shell wrappers cannot do: `sessions_spawn` and best-effort subagent cleanup. All deterministic state and GitLab work belongs in the scripts under `skills/gitlab_issue_campaign_dispatcher/scripts/`.
