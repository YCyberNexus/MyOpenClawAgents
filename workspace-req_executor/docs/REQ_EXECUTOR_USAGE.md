# req_executor Usage

`req_executor` takes GitLab issue content as the Claude Code task prompt. It does not require project material directories, runtime basename fields, or UI account-pool fields.

## Driven Single Issue

`req_dispatcher` sends:

```text
RUN_SINGLE_ISSUE
project=<group>/<project>
iid=<iid>
correlation_id=<id>
dispatcher_callback_target=<target>
```

Optional:

```text
group=<group>
branch=<target-branch>
```

也可以用 `issue_url=<GitLab Issue URL>` 代替 `project+iid`；若两种形式同时提供，二者必须一致。`correlation_id` 可省略，此时 shim 会生成稳定的内容寻址 correlation/batch ID。

`dispatcher_callback_target` 必须非空。`dispatch_single_issue.sh` 本身只校验 trigger、生成稳定 ID 并委托共享 driven wrapper，不加载或转发 GitLab token。共享 intake/tick wrapper 从 executor 自身的进程环境或 `config/gitlab.env` 加载凭据，并读取 `config/campaign_defaults.env` / ignored `config/campaign_defaults.local.env` 的 clone 与 scheduler 配置。single shim 进入 agent-wide driven scheduler，不再合成独立的单并发 scheduled campaign。

## Driven Batch I1 与公开 acceptance

批量入口为：

```text
RUN_DRIVEN_ISSUE_BATCH
batch_id=<stable-id>
correlation_id=<stable-id>
project=<group>/<project>
selector_type=single|range|open_unfinished|open_label
dispatcher_callback_target=<target>
force_rerun_pr=true|false
```

根据 selector 类型再提供 `iid`、`iid_min/iid_max` 或 `label`，可选 `branch`。I1 必须无 GitLab token；executor 使用自身进程环境或 tracked `config/gitlab.env` 的凭据完成 OPEN Issue 查询和不可变 snapshot。

`run_driven_issue_batch.sh` 与 `dispatch_single_issue.sh` 的 rich envelope 只用于 runtime 编排。按数组原序串行完成 `reconcile_actions`、`spawn_grants` 及逐条 `sessions_spawn` ack 后，Path C/E 必须调用固定 `emit_driven_batch_acceptance.sh`，并把它的唯一一行 JSON 原样返回。公开 acceptance 字段集合固定为：

```text
status,batch_id,matched_count,snapshot_digest,scheduler_status
```

不得用 rich envelope、`chat_summary` 或手工构造的 JSON 替代这五字段 acceptance。

## Durable scheduler、周期 tick 与 I3

默认部署值为 `EXECUTOR_MAX_CONCURRENCY=3` 和 `EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler`。所有 driven batch 共享这 3 个物理槽位；scheduler 持久保存不可变 snapshot、游标与 active jobs，并在多个 runnable batch 间严格 round-robin。单个批次包含 100+ Issue 时，wrapper 每次只返回本 tick 所需的有限 grant/reconcile action，不把完整 IID 列表展开到聊天上下文。

部署周期触发固定为：

```text
RUN_EXECUTOR_BATCH_TICK
```

建议每分钟在 executor main session 唤醒一次。tick 先扫描项目 durable intent、导入 terminal handoff、投递 callback outbox，并恢复未完成的 post-spawn coordinator；随后才按严格 round-robin 补满空槽。进程重启或聊天 turn 中断后，下一次 tick 从 durable state 继续。

每个 Issue 的终态逐项发送，不发送一条代替明细的聚合结果。callback transport 固定为：

```text
RUN_DRIVEN_BATCH_RESULT
worker_result_json=<strict single-line I3 JSON>
```

dispatcher 对同一 `event_id` 返回 `accepted` 或 `duplicate` 都表示该 I3 已确认；executor 只有收到匹配 event ID 的 ack 才把对应 outbox item 标记为 delivered。发送失败保留相同 event ID 重试，不重复生成 Issue 结果。

## 本地覆盖、升级与回滚

- 本地 `REPO_PARENT_PATH`、`EXECUTOR_SCHEDULER_ROOT` 或 `EXECUTOR_MAX_CONCURRENCY` 只能通过进程环境或 ignored `config/campaign_defaults.local.env` 覆盖；显式 scheduler 进程环境优先。tracked 配置继续保留蓝区 GitLab host/protocol、token 注入、callback 和 `/data` 默认，不写本机路径或测试 endpoint。
- 升级时先排空 req_dispatcher 的旧 FIFO。旧 active/queue 非空期间，新 batch 只保持 `waiting_for_legacy_drain`，不与旧 single active 重叠；清空后由 `RUN_EXECUTOR_BATCH_TICK` 推进新 scheduler。
- 回滚时先停止新的 batch 入口和周期 tick。可先排空，也可保留 scheduler state、batch snapshot、handoff 与 callback outbox 等 durable 记录等待恢复；不得删除运行时 state/outbox，也不得用新 batch ID 替代未完成批次。

## Scheduled Trigger

Minimum scheduled trigger:

```text
RUN_SCHEDULED_ISSUE_CAMPAIGN
group=<group>
project=<project>
gitlab_token=<token>
issue_min_iid=<min_iid>
issue_max_iid=<max_iid>
hourly_issue_quota=<quota>
max_runtime_minutes=<minutes>
blocked_retry_limit=<limit>
blocked_cooldown_ticks=<cooldown>
non_interactive=true
session_mode=per_issue
scheduling_mode=quota_carryover
blocked_policy=skip_and_retry
```

Common optional fields:

- `branch` (omitted means the remote default branch from `origin/HEAD`)
- `repo_path`
- `max_concurrent_subagents`
- `acpx_timeout_seconds`
- `stuck_after_minutes`
- `issue_iids`
- `require_labels`
- `require_labels_match`
- `result_note_enabled`
- `model_tiers`
- `continue_upgrade_threshold`

Do not send runtime basename, data directory, or UI account-pool fields.
Do not send the legacy `run_timeout_seconds` field. OpenClaw 2026.6.11 reads
the optional global `agents.defaults.subagents.runTimeoutSeconds` internally;
it is not visible in an individual `sessions_spawn` call.

## Runtime Layout

```text
${REPO_PATH}/.req_executor/
  _dispatcher/
  issues/issue-<iid>/
  .worktrees/issue-<iid>/
    .req_executor/issue-<iid>/output/
    .req_executor/issue-<iid>/log/attempt-NNN/
```

`run_acpx_attempt.sh` runs from `${WORKTREE_DIR}` and invokes:

```bash
acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"
```

The acpx invocation logic is intentionally centralized in that script.
