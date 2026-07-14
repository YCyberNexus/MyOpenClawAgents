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
executor_agent=req_executor
callback_nonce=<64 个小写 hex>
```

Optional:

```text
group=<group>
branch=<target-branch>
```

也可以用 `issue_url=<GitLab Issue URL>` 代替 `project+iid`；若两种形式同时提供，二者必须一致。`correlation_id` 可省略，此时 shim 会生成稳定的内容寻址 correlation/batch ID。

`dispatcher_callback_target` 与 `executor_agent` 必须精确匹配部署 pin，`callback_nonce` 必须为 64 个小写 hex。nonce 仅存于私有 I1/request/outbox，不进入公开 acceptance 或八字段 Issue 结果。`dispatch_single_issue.sh` 校验 trigger、生成稳定 ID 并委托共享 driven wrapper。共享 driven 调度链从 executor 自身的进程环境或 `config/gitlab.env` 加载 `GITLAB_TOKEN`，把它直接写入内部 scheduled trigger 与子任务 prompt，并读取 `config/campaign_defaults.env` / ignored `config/campaign_defaults.local.env` 的 clone 与 scheduler 配置。single shim 进入 agent-wide driven scheduler，不再合成独立的单并发 scheduled campaign。

## Driven Batch I1 与公开 acceptance

批量入口为：

```text
RUN_DRIVEN_ISSUE_BATCH
batch_id=<stable-id>
correlation_id=<stable-id>
project=<group>/<project>
selector_type=single|iid_list|range|open_unfinished|open_label
dispatcher_callback_target=<target>
executor_agent=req_executor
callback_nonce=<64 个小写 hex>
force_rerun_pr=true|false
```

根据 selector 类型再提供 `iid`、`iids`、`iid_min/iid_max` 或 `label`，可选 `branch`。`iid_list` 的 `iids` 必须是至少两个升序去重的逗号分隔正整数，例如 `1,4,5`。I1 字段用于项目、selector 与回调路由；executor 按进程环境优先、tracked `config/gitlab.env` 回退的顺序加载 `GITLAB_TOKEN`，完成 OPEN Issue 查询，并在内部执行链和子任务 prompt 中直接传递该值。私有仓库网络 Git 操作使用普通 `git`，`origin` 为 `${GITLAB_API_PROTOCOL}://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${GROUP}/${PROJECT}.git` 形式的直接认证 URL，Git 子进程继承 executor 当前环境。Issue 列表使用 GraphQL cursor 完整扫描，重复 IID、异常游标或扫描预算耗尽都会失败关闭；只有连续两次规范化结果一致才冻结不可变 snapshot。

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

建议每分钟在 executor main session 唤醒一次。tick 会先扫描项目 durable intent、导入 terminal handoff、投递 callback outbox，并恢复未完成的 post-spawn coordinator；随后用 scheduler active job 与未完成 launch coordinator 构造保护集，在项目锁内清除不受保护且没有任何运行标识的旧 placeholder。项目预检发现 running Issue 已有 `pr` 或已关闭时，tick 会立即按当前 claim fence 重新核验 GitLab 并生成 `skipped` handoff，不再等待运行租约；超过运行租约且确已越过项目 ACPX 截止时间的丢回调任务仍由 timeout 路径兜底。最后才按严格 round-robin 补满空槽。进程重启或聊天 turn 中断后，下一次 tick 从 durable state 继续。完成批次、已确认 outbox 和完成的 launch action 会退出热索引并保留在按 ID 可定位的冷记录中，周期成本只随活动工作量增长。

整个 topup/skip-finalize 事务由 agent 级 nonblocking tick 锁串行化；重叠唤醒立即返回 `idle`，不会使用旧的 pending 快照终结刚创建的新任务。

每个 Issue 的终态逐项发送，不发送一条代替明细的聚合结果。callback transport 固定为：

```text
RUN_DRIVEN_BATCH_RESULT_ACK_ONLY
callback_envelope={"batch_acceptance":<strict 5-field acceptance>,"callback_nonce":"<64 hex>","executor_agent":"req_executor","worker_result_json":<strict 8-field I3 JSON>}
ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。
```

dispatcher 对同一 `event_id` 返回 `accepted` 或 `duplicate` 都表示该 I3 已确认；executor 只有收到匹配 event ID 的 ack 才把对应 outbox item 标记为 delivered。发送失败保留相同 event ID 重试，不重复生成 Issue 结果。
ack stdout 必须整体是唯一严格 JSON，或整体恰为单个 `json`/无语言 Markdown 围栏且 body 为
唯一严格 JSON。围栏外字符、中文总结、解释、双围栏、前后缀或多个 JSON 都按
`malformed_or_ambiguous_ack` 保留 outbox 并重试。dispatcher 仍接受旧
`RUN_DRIVEN_BATCH_RESULT` 输入 marker，但新 outbox 不再发送它。新 marker 缺失、伪造或追加
第三行也会在 durable apply 前失败关闭。

callback `openclaw` 子进程继承 executor 当前环境，包括按既定优先级选中的 `GITLAB_TOKEN`；`callback_envelope` 的字段集合仍按上述 I3 业务 schema 生成。

每次 outbox drain 默认最多实际投递 3 条；失败项持久保存 `next_attempt_at`，按 30 秒起步、最长 3600 秒的指数退避继续重试。可用进程环境 `DRIVEN_CALLBACK_MAX_ATTEMPTS_PER_TICK`、`DRIVEN_CALLBACK_BACKOFF_BASE_SECONDS`、`DRIVEN_CALLBACK_BACKOFF_MAX_SECONDS` 调整。预算耗尽或存在 100+ 失败积压时，同一 executor tick 仍继续 post-spawn recovery 和 reservation，不会让回调网络超时长期占住调度循环。

## 本地覆盖、升级与回滚

- 本地 `REPO_PARENT_PATH`、`EXECUTOR_SCHEDULER_ROOT`、`EXECUTOR_MAX_CONCURRENCY`、`EXECUTOR_RUNNING_LEASE_SECONDS`、`EXECUTOR_AGENT` 或 `DISPATCHER_CALLBACK_TARGET` 只能通过进程环境或 ignored `config/campaign_defaults.local.env` 覆盖；显式 scheduler 进程环境优先，并须在 intake、tick、import、delivery 使用同一组值。tracked 配置继续保留蓝区 GitLab host/protocol、token 注入、callback 和 `/data` 默认，不写本机路径或测试 endpoint。
- 升级时先排空 req_dispatcher 的旧 FIFO。旧 active/queue 非空期间，新 batch 只保持 `waiting_for_legacy_drain`，不与旧 single active 重叠；清空后由 `RUN_EXECUTOR_BATCH_TICK` 推进新 scheduler。
- 认证回调上线前已经存在于 executor 私有 scheduler 根、且同时缺少 `executor_agent` 与 `callback_nonce` 的旧 request/outbox，会在读取时一次性显式标记为 `legacy_pre_upgrade`，并用 `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY` 加 `worker_result_json=<严格八字段 I3>` 完成旧 mirror。dispatcher 仍接受旧 marker 以兼容已发出的在途消息。新 I1 始终强制 nonce、executor 与固定 target；触发输入不能请求或伪造 `legacy_pre_upgrade`。
- 新旧锁目录滚动升级默认保留 86400 秒兼容窗口（起点持久化在 scheduler 根的 `lock_layout_v2.json`）。窗口内新进程同时获取旧、新两条 callback/launch 锁；窗口后才在双锁保护下把旧锁移出热目录。只有确认所有旧 executor 进程已停止，才可用 `DRIVEN_LEGACY_LOCK_COMPAT_SECONDS=0` 提前结束窗口。
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
