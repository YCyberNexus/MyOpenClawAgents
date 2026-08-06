# req_executor Runtime Contract

`req_executor` executes GitLab issues from the requirement pipeline. It does not assume a project-specific test framework or material directory. The issue title, description, and all non-system issue comments are rendered into `${LOG_DIR}/prompt.txt` in every mode; continue mode also separates historical agent summaries.

`/slot <正整数>` 只调用 `set_executor_slots.sh`。该 wrapper 在 scheduler lock 下持久化所有
batch session 共享的并行仓库数上限。

`/repo-slot <正整数>` 只调用 `set_executor_repo_slots.sh`。该 wrapper 持久化每个 GitLab
仓库允许并行的 Issue 数，默认值为 1；在线缩容不取消已启动任务。两个并发参数都不得由
LLM 修改配置文件或 scheduler JSON。

`/timeout-executor <时长>` 只调用 `set_executor_acpx_timeout.sh`。该 wrapper 持久化
后续 attempt 使用的 acpx 上限，并返回 dispatcher 后续使用的派生外层预算；
在途 attempt 保留启动时固定的超时，OpenClaw 全局 timeout 不变。

`/mission-stop <GitLab 仓库 URL|group/project>` 只调用
`stop_repository_mission.sh`。先由 wrapper 原子清理 scheduler、batch、launch action 与
项目 pending 状态，再按其私有 envelope 精确 kill 运行时 child；最后把精确
`public_result.stop_id` 传给 `emit_mission_stop_receipt.sh`，并只返回 emitter 的唯一紧凑 JSON。

## Wrapper Flow

1. `dispatch_prepare_tick.sh` validates the trigger, reconciles GitLab labels, selects IIDs, prepares worktrees, builds prompts, and emits spawn entries.
2. The orchestrator calls `sessions_spawn` with the rendered outer executor prompt.
3. The outer subagent makes one long call to `scripts/run_executor_attempt.sh`.
4. That wrapper calls `run_acpx_attempt.sh`, which changes directory to `${WORKTREE_DIR}` and runs `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"`; the same wrapper then stages, pushes, creates/updates the MR, summarizes, atomically writes `${LOG_DIR}/worker_result.json`, completes log/state persistence, and finally publishes the private hash-bound `${LOG_DIR}/attempt_finalized.json`.
5. The outer subagent echoes the wrapper's final compact JSON. If OpenClaw does not schedule that final model turn, the periodic heartbeat processes the result only after the finalization marker matches the exact bytes and scheduler claim, then reclaims the native child slot.
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

`clone_or_pull.sh` writes `/.req_executor/` and `logs/` to local `.git/info/exclude`. When business changes exist, `stage_and_guard.sh` force-adds `${OUTPUT_DIR}` and the complete staging-time `${LOG_DIR}` into the same Issue-branch commit. After `worker_result.json` is durable, `archive_execution_logs.sh` appends the complete terminal directory as the one log-only child on that same `WORK_BRANCH`. For a single-Issue branch, `commit_sha` remains the business artifact while `work_branch_sha` records that exact remote log-child tip. It never creates a separate remote log branch. Unrelated `logs/` paths remain outside the commit index.

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
