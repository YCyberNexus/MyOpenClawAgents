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
- first line beginning with `/repo-slot` → Path G,
  `set_executor_repo_slots.sh`; the wrapper validates the complete message and
  persists the shared per-repository Issue ceiling.
- first line beginning with `/timeout-executor` → Path H,
  `set_executor_acpx_timeout.sh`; the wrapper persists the cap for future attempts.
- first line beginning with `/mission-stop` → Path I,
  `stop_repository_mission.sh`; the wrapper fences and archives one repository's task chain.
- `RUN_SCHEDULED_ISSUE_CAMPAIGN` → Path A, `dispatch_prepare_tick.sh`.

`RUN_DRIVEN_ISSUE_BATCH` is never a heartbeat tick. Never call
`run_executor_batch_tick.sh` as the first wrapper for that trigger; the Path C
wrapper performs its own initial tick after durable batch creation.

Core contract:

- The orchestrator calls wrapper scripts under `skills/gitlab_issue_campaign_dispatcher/scripts/`.
- `RUN_EXECUTOR_BATCH_TICK` runs the exact bare Path D wrapper command. Never read config or `*.env` files and never inject credentials, paths, hosts, or
  scheduler settings into that command; the wrapper resolves them privately.
- `/slot` changes scheduler capacity only through `set_executor_slots.sh`;
  it limits parallel repositories. `/repo-slot` changes per-repository Issue
  capacity only through `set_executor_repo_slots.sh`; its default is `1`.
  Never edit deployment config or scheduler JSON in the orchestrator.
- `/timeout-executor` changes the future-attempt acpx cap only through
  `set_executor_acpx_timeout.sh`; active attempts retain their pinned cap,
  future dispatcher outer budgets are derived from scheduler state, and the
  OpenClaw global timeout remains unchanged.
- `/mission-stop` changes durable scheduler/project state only through
  `stop_repository_mission.sh`. Perform only the exact runtime kills returned
  by the wrapper, then return its `public_result`; never reconstruct batch IDs.
- A native completion turn calls its prescribed ingester once and exits on
  rejection; it never summarizes the untrusted child Result, runs a heartbeat
  first, reads worker-result fields into prose, or debugs wrapper scripts. It
  passes the exact selector through the Path B Bash heredoc; OpenClaw's `exec`
  tool has no process-stdin field, so never use an `stdin` tool argument or
  invoke the ingester with empty stdin. That Bash call is the first tool call
  in the turn: never list, search, or read scripts first. The only permitted
  later tool call is the exact best-effort cleanup kill returned by the
  ingester. On OpenClaw 2026.4.9, pass only the exact two-field
  terminal-reference JSON, never the raw internal completion context.
- Paths C and E are synchronous public-acceptance turns. They never call
  `sessions_yield` and never inherit Path D's post-cleanup or post-recorder
  termination behavior. If their rich envelope contains a `spawn_grants[]`
  item, the required order is Read payload -> `sessions_spawn` ->
  `record_executor_batch_spawn.sh`; never jump from the intake wrapper to the
  acceptance emitter. After every resolved runtime action, including a durable
  spawned or launch-failed record, they emit and return the exact five-field
  acceptance. Because the embedded tick is global, the fixed emitter rejects
  while any hot `action_emitted` spawn acknowledgement is still pending, even
  when that action belongs to an older batch. A nonzero emitter result must
  stop the turn and must never be rewritten as a successful receipt.
  The heartbeat does not leave that gate permanent: after the dedicated
  spawn-ack lease expires, it atomically fences only the exact emitted claim
  through the canonical reservation wrapper and returns runtime reconciliation
  before any new spawn. Explicit child-label enumeration still decides whether
  to restore the old child or open the next claim generation.
- `record_executor_batch_spawn.sh` accepts its spawned or launch-failed object
  only as strict JSON stdin. Never pass its result fields as environment
  variables; that environment contract belongs only to Path A's
  `dispatch_record_spawn.sh`. After a successful `sessions_spawn`, this
  recorder is the mandatory next tool call before any `sessions_yield`.
- Unmatched human prose is not a scheduler trigger. It may receive a read-only
  explanation, but it never authorizes reading a private spawn payload,
  manually calling `sessions_spawn`, editing launch state, or running a tick.
  An `action_emitted` ambiguity is resolved only from an exact Path D
  `reconcile_emitted_spawn` action and its prescribed runtime enumeration.
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
- `build_prompt.sh` writes `${LOG_DIR}/prompt.txt` from the issue title, description, and all non-system issue comments in every mode; continue mode also separates historical agent summaries.
- Runtime state lives under `${REPO_PATH}/.req_executor/`.
- There are no runtime basename, project data directory, or UI account-pool trigger/config fields.
- `clone_or_pull.sh` locally ignores `/.req_executor/` and `logs/`; when business changes exist, `stage_and_guard.sh` force-adds the current issue's output plus the complete staging-time `${LOG_DIR}` into the same Issue-branch commit. After `worker_result.json` is durable, `archive_execution_logs.sh` appends the complete terminal directory as a log-only child on that same `WORK_BRANCH`; later recovery evidence may append another child. It never creates a separate remote log branch. Unrelated `logs/` paths remain outside the commit index.

The standard wrapper environment is:

```text
PROJECT
GROUP
GITLAB_TOKEN
REPO_PARENT_PATH   # optional, defaults to /data
```

Per-IID scripts additionally receive `ISSUE_IID` and an opaque random `EXECUTION_ID`; it is an identity fence, not an execution counter. All paths are derived by `env_paths.sh`.
