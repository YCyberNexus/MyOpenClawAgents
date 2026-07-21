# req_executor Runtime Contract

`req_executor` executes GitLab issues from the requirement pipeline. It does not assume a project-specific test framework or material directory. The issue title, description, and all non-system issue comments are rendered into `${LOG_DIR}/prompt.txt` in every mode; continue mode also separates historical agent summaries.

`/slot <正整数>` 只调用 `set_executor_slots.sh`。该 wrapper 在 scheduler lock 下持久化所有
batch session 共享的物理并发上限；不得由 LLM 修改配置文件或 scheduler JSON。

`/timeout-executor <时长>` 只调用 `set_executor_acpx_timeout.sh`。该 wrapper 持久化
后续 attempt 使用的 acpx 上限，并返回 dispatcher 后续使用的派生外层预算；
在途 attempt 保留启动时固定的超时，OpenClaw 全局 timeout 不变。

## Wrapper Flow

1. `dispatch_prepare_tick.sh` validates the trigger, reconciles GitLab labels, selects IIDs, prepares worktrees, builds prompts, and emits spawn entries.
2. The orchestrator calls `sessions_spawn` with the rendered outer executor prompt.
3. The outer subagent makes one long call to `scripts/run_executor_attempt.sh`.
4. That wrapper calls `run_acpx_attempt.sh`, which changes directory to `${WORKTREE_DIR}` and runs `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"`; the same wrapper then stages, pushes, creates/updates the MR, summarizes, and atomically writes `${LOG_DIR}/worker_result.json`.
5. The outer subagent echoes the wrapper's final compact JSON. If OpenClaw does not schedule that final model turn, the periodic heartbeat processes the durable result under the scheduler claim fence and reclaims the native child slot.
6. `dispatch_followup.sh` validates the compact JSON, updates state and labels, and reports terminal driven results to `req_dispatcher` when applicable.

Ordinary native terminal callbacks preserve child sessions for diagnosis. The
durable-result recovery path is the deliberate exception: after Phase 6 has
committed the exact result, it emits a best-effort kill for the stale native
child that failed to return its final line.

## Paths

All paths are derived by `env_paths.sh`.

```text
${REPO_PATH}/
  .req_executor/
    _dispatcher/
    issues/issue-<iid>/
    .worktrees/issue-<iid>/
      .req_executor/issue-<iid>/output/
      .req_executor/issue-<iid>/log/
```

`clone_or_pull.sh` writes `/.req_executor/` and `logs/` to local `.git/info/exclude`. When business changes exist, `stage_and_guard.sh` force-adds `${OUTPUT_DIR}` and the complete staging-time `${LOG_DIR}` into the MR. Once `worker_result.json` is durable, `archive_execution_logs.sh` publishes terminal snapshots on append-only branch `req-executor-logs/issue-<iid>/execution-<execution_id>` without moving the business branch; later recovery evidence appends another snapshot. Unrelated `logs/` paths remain outside the commit index.

The worktree, output directory, and local Git branch are fixed per Issue. Each
run receives a random opaque `execution_id`, an isolated log directory, and an
immutable execution-state file. The ID is a stale-callback fence, never a count
of how many times the Issue has run.

## Removed Legacy Inputs

The current req_executor contract does not support:

- runtime basename trigger/config fields
- data directory trigger/config fields
- project-specific material paths
- UI account-pool trigger/config fields

If an issue needs credentials, fixtures, or project-specific context, the issue body must describe them.
