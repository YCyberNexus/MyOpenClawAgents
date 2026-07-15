# req_executor Agent Notes

`req_executor` is the issue executor for the `req_dispatcher` requirement pipeline. It is task-agnostic: the GitLab issue body is the prompt for Claude Code.

## First-line trigger router (HARD)

Before classifying command text, route a protected native subagent completion
input to Path B. This higher-priority route covers OpenClaw 2026.4.9 internal
completion context and OpenClaw 2026.6.11 structured `task_completion` events.
For 4.9, submit only the exact child session key as an
`openclaw_4_9_terminal_reference`; never reconstruct the raw context.

Classify the exact first line before doing anything else. One turn executes
exactly one matching wrapper path:

- `RUN_DRIVEN_ISSUE_BATCH` → Path C, `run_driven_issue_batch.sh`.
- `RUN_EXECUTOR_BATCH_TICK` → Path D, `run_executor_batch_tick.sh`.
- `RUN_SINGLE_ISSUE` → Path E, `run_single_issue_batch.sh`.
- first line beginning with `/slot` → Path F, `set_executor_slots.sh`; the
  wrapper validates the complete message and persists the shared ceiling.
- first line beginning with `/timeout-executor` → Path G,
  `set_executor_acpx_timeout.sh`; the wrapper persists the cap for future attempts.
- `RUN_SCHEDULED_ISSUE_CAMPAIGN` → Path A, `dispatch_prepare_tick.sh`.

`RUN_DRIVEN_ISSUE_BATCH` is never a heartbeat tick. Never call
`run_executor_batch_tick.sh` as the first wrapper for that trigger; the Path C
wrapper performs its own initial tick after durable batch creation.

Core contract:

- The orchestrator calls wrapper scripts under `skills/gitlab_issue_campaign_dispatcher/scripts/`.
- `RUN_EXECUTOR_BATCH_TICK` runs the exact bare Path D wrapper command. Never read config or `*.env` files and never inject credentials, paths, hosts, or
  scheduler settings into that command; the wrapper resolves them privately.
- `/slot` changes scheduler capacity only through `set_executor_slots.sh`;
  never edit deployment config or scheduler JSON in the orchestrator.
- `/timeout-executor` changes the future-attempt acpx cap only through
  `set_executor_acpx_timeout.sh`; active attempts retain their pinned cap,
  future dispatcher outer budgets are derived from scheduler state, and the
  OpenClaw global timeout remains unchanged.
- A native completion turn calls its prescribed ingester once and exits on
  rejection; it never reads, edits, patches, or debugs wrapper scripts.
- The outer subagent receives `references/executor_prompt.md`.
- The outer subagent makes one long call to `scripts/run_executor_attempt.sh`.
  That wrapper owns the complete acpx-to-finalization sequence and atomically
  persists `${LOG_DIR}/worker_result.json` before returning.
- Only `scripts/run_executor_attempt.sh` may invoke
  `scripts/run_acpx_attempt.sh`; the latter owns the fixed
  `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"` invocation
  and writes `${LOG_DIR}/acpx_terminal.json` immediately after acpx exits.
- A heartbeat may claim-fence and process a durable worker result, or emit one
  `cleanup_actions[]` kill after the post-acpx watchdog expires. This is the
  recovery path when OpenClaw does not schedule the outer model's final turn.
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
