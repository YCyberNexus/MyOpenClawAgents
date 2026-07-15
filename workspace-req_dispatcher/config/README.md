# Workspace Config

本目录是 **部署期 pin（deployment-time pins）**：在每台部署 `req_dispatcher` 的 runner 上编辑一次。它们**不**由 trigger 输入生成，agent 运行时也**不**改写它们。

标准入口 `skills/requirement_dispatch/scripts/source_dispatcher_env.sh` 会先加载 tracked `dispatcher.env`，再加载 ignored `dispatcher.local.env`（若存在）。当前部署要求 `WIKI_GITLAB_*` 明文保存在 tracked `dispatcher.env`；本机路径、临时 session 或调试网关仍放在 ignored `dispatcher.local.env`。
基础配置加载不访问 executor state。只有执行和恢复路径额外 source `source_executor_timeout_budget.sh`，只读 `EXECUTOR_SCHEDULER_STATE_FILE` 并覆盖未来调用的派生外层预算；state 不存在、不可读或无效时失败关闭。I3 callback、建单及 `/slot`、`/timeout-executor` 控制路径不依赖这次读取，也不会访问或修改 OpenClaw 全局配置。

新部署必须先启动一次 req_executor scheduler/tick，或通过 `/slot`、`/timeout-executor` 初始化 scheduler state，再开放自然语言执行入口。这样执行路径不会在 state 路径错误时静默使用较短的 tracked 默认值。

## `dispatcher.env`

| 字段 | 必填 | 说明 |
|------|------|------|
| `GIT_ISSUER_AGENT` | 是 | 下游目标 agent 名。`req_dispatcher` 通过 `run_agent_turn.sh` 调用它，由它完成"需求→issue"。默认 `git_issuer`。 |
| `STATE_ROOT` | 是 | 运行时 state 根目录。`pending.json` / `executor_queue.json` / `ledger.jsonl` / 锁 / 序号 / 日志都在 `${STATE_ROOT}/_dispatcher/` 下。必须是 server 上 agent 可写的持久目录。 |
| `EXECUTOR_SCHEDULER_STATE_FILE` | 是 | req_executor 共享 scheduler state 的绝对路径，蓝区默认 `/data/req_executor/_scheduler/scheduler_state.json`。dispatcher 从其中读取持久化的 `acpx_timeout_seconds`，作为未来外层预算的单一真实来源。104 上两个 agent 必须由可读取该 mode `0600` 文件的同一 service account 运行。 |
| `EXECUTOR_ACPX_TIMEOUT_SECONDS` | 是 | 已存在的 scheduler state 尚无 `acpx_timeout_seconds` 字段时的初始化回退，默认 `3600`。执行/恢复前 state 文件本身必须存在；运行时 `/timeout-executor` 不编辑本文件。 |
| `OPENCLAW_SUBAGENT_TIMEOUT_SECONDS` | 是 | OpenClaw 全局 subagent 固定安全上限，默认 `20400`。只用于预算检查和展示；`/timeout-executor` 不修改 OpenClaw 全局配置。 |
| `STUCK_AFTER_MINUTES` | 是 | 新 pending 的 stuck/timeout 预算（分钟）。默认一小时 acpx 对应 `150`；执行/恢复时按 `ceil((acpx+4200)/60)+20` 自动派生，并在创建旧 FIFO active/pending 时固化。部署前无快照记录兼容使用旧值 `390`。 |
| `OPS_NOTIFY_CHANNEL` | 否 | 失败通知 channel = **企业微信群机器人 webhook URL**（http/https）。留空则不通知。消费方 `scripts/ops_notify.sh`（best-effort，发送失败不阻断失败路径；要换通知形态改该脚本）。 |
| `DEFAULT_ENTRY_LABEL` | 否 | 仅当将来需要 `req_dispatcher` 向 git_issuer 显式指定执行器入口标签时用。默认空＝由 git_issuer 自决。 |
| `DEFAULT_EXECUTOR_AGENT` | 是 | 默认执行器 agent。只有用户明确要求处理 issue 时才使用；所有形态合法的 GitLab project（`group/project`）未命中覆盖路由时都路由到这里，默认 `req_executor`。 |
| `/slot` 目标 | 自动 | `/slot <正整数>` 固定发送到 `agent:${DEFAULT_EXECUTOR_AGENT}:main`，调整该 executor 共享 scheduler 的物理并发上限；不按 project 路由表拆分。 |
| `/timeout-executor` 目标 | 自动 | `/timeout-executor <时长>` 固定发送到 `agent:${DEFAULT_EXECUTOR_AGENT}:main`，持久化 60 到 18000 秒的后续 attempt acpx 上限；支持裸秒数、`Ns`、`Nm`、`Nh`。 |
| `DOWNSTREAM_AGENT_TIMEOUT_SECONDS` | 否 | `scripts/run_agent_turn.sh` 调用下游 agent 时传给 `openclaw agent --timeout` 的配置下限，默认 `600`。若单次调用误传更短的 `AGENT_TIMEOUT_SECONDS`，脚本会提升到本值。 |
| `EXECUTOR_AGENT_TIMEOUT_SECONDS` | 自动 | `scripts/run_agent_turn.sh` 调用 executor 目标时的专用超时下限，按 `acpx+3600` 派生；默认 `7200`。git_issuer 仍使用 `DOWNSTREAM_AGENT_TIMEOUT_SECONDS`。 |
| `EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS` | 自动 | 调用 `submit_executor_batch.sh` 的 OpenClaw exec 工具 timeout，按 `acpx+3900` 派生；默认 `7500`。LLM 必须先调用 `get_executor_timeout_budget.sh` 读取，不得使用固定旧值。 |
| `EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS` | 自动 | 旧 executor queue active 创建时固化的回收阈值，按 `acpx+4200` 派生；默认 `7800`，始终晚于 executor turn 和 exec 工具 timeout。部署前无快照 active 兼容使用旧值 `22200`。 |
| `EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS` | 否 | `launch_failed` active 下一次允许重试前等待的秒数，默认 `60`。 |
| `EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS` | 否 | 单次 `drain_executor_queue.sh` 对同一 executor payload 的启动尝试次数，默认 `3`。 |
| `EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS` | 否 | 同一 drain 内相邻启动尝试之间的固定退避秒数，默认 `2`。 |
| `RUN_AGENT_TURN_HEARTBEAT_SECONDS` | 否 | `scripts/run_agent_turn.sh` 等待下游 agent 时向 stderr 输出 heartbeat 的间隔，默认 `30`；stdout 仍只输出最终 JSON envelope。 |
| `ROUTING_FILE` | 否 | project 覆盖路由表文件路径（见下「`routing.env`」）。git_issuer 返回 project 后，先查本表；未命中则使用 `DEFAULT_EXECUTOR_AGENT`。消费方 `scripts/route_project.sh`。默认相对 SKILL_DIR 的 `../../config/routing.env`，也可改绝对路径。 |
| `WIKI_GITLAB_HOST` | wiki 入口必填 | 只读拉取 GitLab wiki 的 host（含端口则写端口）。仅由 `prepare_wiki_downstream_payloads.sh` 的 `FETCH_WIKI=1` 路径使用。 |
| `WIKI_GITLAB_API_PROTOCOL` | wiki 入口必填 | `http` 或 `https`，与 wiki 所在 GitLab 服务一致。 |
| `WIKI_GITLAB_TOKEN` | wiki 入口必填 | 只读 wiki token。当前部署按要求明文写入 tracked `dispatcher.env`，用于 `glab api projects/<project>/wikis/<slug>` 拉取 wiki 内容；不得用于建 issue、打标签、写 note 或 executor 操作。 |
| `WIKI_GLAB_BIN` | 否 | `glab` 可执行文件路径，默认 `glab`。本机 fake glab 测试可覆盖。 |
| `REPLY_GATEWAY_URL` | 否 | 114 OpenClaw 网关 URL。用户结果推送机制已对齐为 104 反向网关调用 114 接收 agent；为空时兼容回落到旧 `ZHIBAN_GATEWAY_URL`。网关、token、目标 agent 都无法解析时，`scripts/notify_user.sh` no-op（仅记 ledger 留痕、不静默丢）。 |
| `REPLY_GATEWAY_TOKEN` | 否 | 114 OpenClaw 网关 token。仅由 `notify_user.sh` 用于 `openclaw agent run` 投递结果信封；为空时兼容回落到旧 `ZHIBAN_GATEWAY_TOKEN`；不要写入日志。 |
| `DEFAULT_REPLY_AGENT` | 否 | 114 上接收结果信封的默认 agent 名。`notify_user.sh` 只有在 `ORIGIN_JSON` 是合法 object 时才允许出站推送；目标 agent 优先使用 `origin.reply_agent`，该字段只在合法 origin 未提供 `reply_agent` 时兜底。`ORIGIN_JSON` 为空/null/非 object 时视为手动入口，不使用该兜底值；为空时兼容回落到旧 `ZHIBAN_AGENT`。接收 agent 负责根据信封里的 `origin` 完成企微最后一跳。 |
| `REPLY_NOTIFY_TIMEOUT_SECONDS` | 否 | 104 反向调用 114 接收 agent 的超时秒数，默认 `30`；为空时兼容回落到旧 `ZHIBAN_NOTIFY_TIMEOUT_SECONDS`；必须为正整数，配置形态错误时 `notify_user.sh` 以 `2` 退出。实际投递超时只写 `user_notify_failed` 留痕并 `exit 0`，不阻断终态回调路径。 |
| `DISPATCHER_CALLBACK_TARGET` | 是 | executor 结果回调的部署期固定 pin：batch I1 与旧 `RUN_SINGLE_ISSUE` bridge 都把它作为 `dispatcher_callback_target` 传给 req_executor，执行器 Phase 6 据此把 I3 结果投回 req_dispatcher。仅允许 `agent:req_dispatcher:<safe-session>`，其中 `<safe-session>` 必须匹配 `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`；不接受裸 agent、其他 agent 或调用方临时指定的 session。req_executor intake 与 delivery 还会要求它精确等于自身部署 pin。必须非空；缺失时 intake/legacy drain 会在分配序号、修改 active/pending、落 batch intent 或网络调用前失败关闭，payload builder 还会二次校验。 |
| callback 认证 | 自动生成 | 不设静态配置。dispatcher 为每个新 batch/single intent 生成独立 64 字符小写 hex nonce，并在 I1 中私密传给路由后的 executor；mirror 只保存 SHA-256。executor 回调使用严格 `callback_envelope={batch_acceptance,callback_nonce,executor_agent,worker_result_json}`，dispatcher 在 I3 落账前同时核对 nonce 摘要、完整 project 与 executor；同步回执丢失时，认证 `batch_acceptance` 可先修复 receipt/mirror。nonce 不得进入 public acceptance、用户通知或日志。 |
| 跨 agent 调用契约 | 已定 | `scripts/run_agent_turn.sh` 先探测本机 OpenClaw 能力：安全新版使用真正的 `--session-key` 或 `--session-id` 并从 `--message-file /dev/stdin` 读正文；2026.4.9 缺少该组合时仅通过本机 loopback Gateway 调用，正文绝不进入 argv。普通调用默认 `agent:<target>:main`，`RUN_SINGLE_ISSUE` 默认 `agent:<target>:issue-<sanitized-project>-<iid>`；真正的 `TARGET_SESSION_ID` 在目标 registry 中唯一精确解析，历史完整 `agent:*` 值仅作为 key alias；`RUN_SINGLE_ISSUE` 显式 main 仍会改投 issue 级 session。Gateway 地址/token 由 runner 的本地 OpenClaw 配置管理。 |

## 两类 timeout 的边界

`req_dispatcher` 的 `EXECUTOR_AGENT_TIMEOUT_SECONDS` 控制同步
`openclaw agent --timeout` CLI 等待，必须继续保留。它与
`agents.defaults.subagents.runTimeoutSeconds` 不是同一个参数：后者由
OpenClaw 运行时内部应用到 `req_executor` 派发的匿名 subagent，允许缺失
或为 `0`，也不会显示在单次 `sessions_spawn` 调用中。

当前 OpenClaw 2026.4.9 对省略单次 `runTimeoutSeconds` 的 subagent 使用
`agents.defaults.subagents.runTimeoutSeconds`；不要依赖 `agents.list[]` 里的 agent 级
同名字段来隔离该超时。全局值必须覆盖所有省略单次参数的直接派发
agent 中最大的完整执行预算。`req_executor` 默认 acpx 为 3600 秒，
但 `/timeout-executor` 允许调回最大 18000 秒；再加 2400 秒收尾，因此全局兜底
仍应独立保持 `20400`。命令只联动 dispatcher 侧外层预算，不读取或写入 OpenClaw
全局配置。`acpx_auto_tester` 会在每次
`sessions_spawn` 时显式传 `runTimeoutSeconds`，不使用这个全局默认值。检查配置时必须
使用网关相同的 service account 和 OpenClaw profile/config path：

```bash
openclaw config get agents.defaults.subagents.runTimeoutSeconds
openclaw config validate
```

`config get` 若返回 `Config path not found`，表示该项未设置，按 OpenClaw
默认即为 `0`（不限制）。若查到的正数小于 `20400`，会在 acpx 或收尾
完成前提前终止 subagent。建议在 104 上用网关的同一 service account 和
profile 把全局兜底调整为 5 小时 40 分：

```bash
openclaw config set agents.defaults.subagents.runTimeoutSeconds 20400 --strict-json
openclaw config validate
```

配置变更后按该环境的标准流程重启 OpenClaw gateway，使新值生效。

## `routing.env`（多 project 路由表）

当 action 是 `execute_issue` 或 `create_and_execute` 时，req_dispatcher 先查本表是否有专属 executor 覆盖项；未命中时统一路由到 `DEFAULT_EXECUTOR_AGENT`。project key 支持完整多层 namespace path（例如 `group/subgroup/project`），始终整体精确匹配。新执行请求由 `submit_executor_batch.sh` 持久化 I1，并向目标 executor 发送 `RUN_DRIVEN_ISSUE_BATCH`；旧 `executor_queue.json` 只用于排空升级前已经入队的 `RUN_SINGLE_ISSUE`，新请求不得再写入旧 FIFO。只建单 action 不查本表、不创建 executor batch。消费方 `scripts/route_project.sh`。

行格式：每行一条 `PROJECT=AGENT`。

| 段 | 含义 |
|----|------|
| `PROJECT` | git_issuer 返回的 `group/project`（含 `/`，故本文件**不能**被 shell `source`，由 `route_project.sh` 逐行手解）。 |
| `AGENT` | 该 project 对应的专属 `req_executor` 部署 agent 名。 |

匹配规则：对 `PROJECT` **整体精确相等**（无前缀 / 正则 / 大小写折叠，避免误投）；`#` 起头行与空行忽略；`PROJECT = AGENT`（等号两侧带空格）也容忍；重复键按首行（first-match wins）。未命中且 `DEFAULT_EXECUTOR_AGENT` 非空时输出默认执行器。

**no-route 语义**：只有 `DEFAULT_EXECUTOR_AGENT` 未配置且覆盖表未命中时才输出 `__NO_ROUTE__` 并 `exit 0`。蓝区默认配置下，所有合法 `group/project` 都应路由到默认执行器。要让某个 project 走专属 executor，就在 `routing.env` 加覆盖行并部署对应 executor。

**配置写错的退出码**：某行无 `=`、`PROJECT`/`AGENT` 为空、或 `ROUTING_FILE` 指向的文件缺失 = 部署期配置写错，`route_project.sh` `exit 2`，orchestrator 走 No-Fallback（分类 / 记录 / 停），**不**当成 no-route 处理。

## 为什么 group / project 不在这里

`req_dispatcher` 是**全公司共用**的需求接入链路。不同员工/团队的需求会落到不同的 GitLab project。把 project 写死在 config 里会让这个 agent 变成单租户、违背"共用接入点"的目标。

因此：**114/WebUI 发送的 prompt 决定目标 project 和动作**。建单入口从 wiki URL 的 `<group>/<project>/-/wikis/<slug>` 或自由文本里的 `group/project`、GitLab 仓库/Wiki URL、`glab api projects/<encoded-group%2Fproject>/...` 片段确定 project，并生成带 `repo=<group/project>` 的 `git_issuer_payload`；既有 issue 执行入口统一收集 GitLab Issue URL、可信 GitLab 仓库根 URL、`projects/...` locator 与显式多段 project path，规范化去重后再结合 selector 提取。多个不同 project 必须在调用下游前歧义失败。`req_dispatcher` 仍不写 GitLab，建单事实仍以 git_issuer 返回 JSON 为准。

## 受驱动批次部署、迁移与回滚

- `DISPATCHER_CALLBACK_TARGET` 是新 batch I1 和旧 single bridge 的必填部署 pin。蓝区固定使用 `agent:req_dispatcher:main`；只允许 `agent:req_dispatcher:<safe-session>`，不得使用裸 agent、其他 agent、本机 session 或临时 callback 目标。空值必须在生成 ID、持久化 intent 或调用 executor 前失败关闭。
- req_executor I1、旧 single I1 与 batch notification 的外部进程调用继承 req_dispatcher 进程环境；I1 payload 与 callback/notification 数据仍按各自严格 schema 构造。
- executor 的公开受理响应必须来自固定 acceptance emitter，且只含精确五字段 `status,batch_id,matched_count,snapshot_digest,scheduler_status`。rich orchestration envelope、`chat_summary` 或手工拼接 JSON 都不是有效 acceptance。
- executor 每个 Issue 终态都以三行 `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY` transport 单独回投 I3；第三行固定为禁止临时文件并强制原样返回 handler stdout 的 `ack_instruction=`。旧 `RUN_DRIVEN_BATCH_RESULT` 两行格式仍兼容接收。dispatcher 必须用 stdin heredoc 把完整 callback 交给 handler，不能把 callback 或 nonce 写入 `/tmp`、workspace 或其他临时文件；最终 assistant 内容必须原样等于 handler 唯一 stdout JSON，不能添加 prose 或 Markdown。对同一 `event_id` 返回 `accepted` 或 `duplicate` 都能确认该事件；重复事件不会重复计数或重复通知用户。
- 升级时保留并先排空旧 `executor_queue.json` 的 active/queue。旧 FIFO 非空期间，新 batch 只持久化为 `waiting_for_legacy_drain`，不得向 executor 发送 I1；旧 active/queue 清空后，统一 tick 才会提交这些 durable intent。禁止删除旧 queue 或把它破坏性迁移进新 scheduler。
- 部署周期触发统一使用 `RUN_EXECUTOR_BATCH_TICK`，建议每分钟唤醒一次 req_dispatcher 主 session；该路径恢复旧 bridge/FIFO、发送等待中的 batch I1 并重试通知。旧 `RUN_EXECUTOR_QUEUE_DRAIN` 仅保留为兼容触发，不再作为新部署的周期入口。req_executor 主 session 也必须按同一周期触发字面量补位和投递 outbox。
- 回滚时先停止新的 batch 入口和周期 `RUN_EXECUTOR_BATCH_TICK`。根据恢复计划排空或原样保留 dispatcher intent/mirror/notification 与 executor scheduler/outbox；不得删除 durable state、outbox、snapshot、handoff 或运行时审计证据。恢复部署后用相同 tick 继续处理，不生成替代 batch ID。

## 部署校验清单

1. `STATE_ROOT` 指向的目录在 runner 上存在且 agent 可写。
2. `GIT_ISSUER_AGENT` 指向的下游 agent 已在同一 OpenClaw 上线，可被 `run_agent_turn.sh` 通过 `openclaw agent` 调用。
3. wiki 入口部署时，`WIKI_GITLAB_HOST` / `WIKI_GITLAB_API_PROTOCOL` / `WIKI_GITLAB_TOKEN` 可读目标蓝区 GitLab wiki；该 token 权限保持只读。
4. 跨 agent 调用原语的连接参数已按对齐结果填好（见 `references/trigger_command.md`）。
5. `DEFAULT_EXECUTOR_AGENT` 指向的 req_executor 已在同一 OpenClaw 上线，且具备处理蓝区目标 GitLab project 的 token。只有执行动作会用到它；只建单动作不会入队。`ROUTING_FILE` 若配置则必须存在且可读；表里只写专属覆盖项，未命中默认执行器。执行分支由用户 prompt 明确指定后作为 executor `branch=` 下发，未指定时由 executor 解析远端默认分支。
6. `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` 按 114 网关部署值填好；114 调用方在 origin 里带 `reply_agent`，或在本文件填默认 `DEFAULT_REPLY_AGENT` 兜底。该兜底只对合法 origin object 生效；手动 WebUI 入口没有 origin 时只留 ledger/log，不推 114/企微。旧部署里的 `ZHIBAN_GATEWAY_URL` / `ZHIBAN_GATEWAY_TOKEN` / `ZHIBAN_AGENT` / `ZHIBAN_NOTIFY_TIMEOUT_SECONDS` 仍被 `notify_user.sh` 兼容读取，但新部署应迁移到 `REPLY_*`。缺少网关 pin 或目标 agent 时 `notify_user.sh` 只留痕、不推送用户结果。`REPLY_NOTIFY_TIMEOUT_SECONDS` 保持默认 `30` 或按网关预期延迟调整为正整数。
7. `DISPATCHER_CALLBACK_TARGET` 必须精确 pin 到 req_dispatcher 长期安全 session；蓝区固定为 `agent:req_dispatcher:main`，session 部分匹配 `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`。不得留空或使用裸 agent/其他 agent，否则 batch intake 与旧 FIFO drain 会拒绝，req_executor 也会在 intake 与 delivery 双重拒绝。
8. req_dispatcher 部署侧必须每分钟周期性唤醒 `RUN_EXECUTOR_BATCH_TICK`。该统一路径先恢复旧 single bridge 并排空升级前 FIFO，再发送 durable batch I1、修复 receipt/mirror，最后重试逐 Issue 通知；只建单请求不会进入 executor batch。
9. req_executor 部署侧也必须每分钟在其 main session 唤醒 `RUN_EXECUTOR_BATCH_TICK`，让默认 3 槽严格 round-robin 调度、handoff 导入和 callback outbox 在没有新聊天消息时持续恢复与补位。

## 与 acpx 工作区的差异

`req_dispatcher` **不**像 `acpx_auto_tester` 那样管理 UI 账号池。它只保存 wiki 只读 GitLab pin 和派发相关 pin；GitLab 写操作仍由 `git_issuer` / `req_executor` 执行。
