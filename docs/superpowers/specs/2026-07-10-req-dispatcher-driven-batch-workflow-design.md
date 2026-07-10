# req_dispatcher 受驱动批次与超长 Issue 工作流设计

## 背景

当前 `req_dispatcher` 的既有 Issue 执行入口只接受单个 GitLab Issue URL，
或显式 `group/project + IID`。`prepare_executor_issue_payload.sh` 输出单个
`project/iid`，随后 durable FIFO 只允许一个 active，最终调用
`req_executor RUN_SINGLE_ISSUE`。

这会导致以下问题：

- “处理某仓库中未完成的 Issue”因缺少 IID 被错误地要求补充信息。
- IID 范围、指定标签、多个 Issue URL 都没有可靠的结构化批量语义。
- 数百条 Issue 若直接展开为旧 FIFO 项，会频繁重写大 JSON 文件，并且只能串行执行。
- 并发扇出多个现有 `RUN_SINGLE_ISSUE` 并不安全：它们会改写同一项目唯一的
  `campaign_state.json`，不同作用域还可能把已有 pending 视为越界并驱逐。
- 现有 driven 回调是 best-effort 同步发送；长批次运行数小时或数天时，短暂的
  网关失败可能让单条结果永久丢失。

本设计将单 Issue driven 链路扩展为受驱动批次工作流。用户可以用自然语言选择
任意数量的 OPEN Issue；`req_executor` 使用自己的 GitLab 凭据冻结 IID 快照，
在 agent 级持久调度器中以默认 3 个槽位公平执行，并继续逐条把终态结果回投
`req_dispatcher`，由后者通知原用户。

## 目标

- 保持单 IID 和 GitLab Issue URL 兼容。
- 支持 IID 闭区间、OPEN 未完成 Issue、OPEN 指定标签 Issue。
- 不设置 100 条等固定业务上限；数百或数千个 IID 使用不可变快照和游标推进。
- `req_dispatcher` 不持有、不传递 GitLab token。
- 每个 `executor agent` 默认总并发为 3，并允许部署配置覆盖。
- 同一 executor 上的多个批次严格公平轮转，避免超大批次长期垄断。
- 每个 Issue 终态仍逐条推送给用户。
- 任一 OpenClaw turn、Gateway 或服务重启后都能从持久状态恢复。
- 保留现有 worktree、attempt、标签、提交、MR 和 Phase 6 执行链。

## 非目标

- 不让 `req_dispatcher` 直接访问 GitLab API。
- 不重新实现 `req_executor` 的 per-Issue 技术执行逻辑。
- 不把后续新建或后来获得匹配标签的 Issue 动态加入已创建批次。
- 不允许 CLOSED Issue 进入批次。
- 不恢复每 Issue 的并行 `sessions_spawn` 调用；launch 调用仍逐个完成 ack，
  已启动的子代理才并行运行。
- 不改变 `workspace-emcp` 或 `workspace-acpx_auto_tester` 的 campaign 行为。

## 已确认的用户语义

### 选择器

所有选择器都必须包含可确定的 GitLab `group/project` 或仓库 URL；dispatcher
不得根据业务语义猜测 project。

| 类型 | 自然语言示例 | 快照筛选规则 |
| --- | --- | --- |
| 单 IID | `处理 group/project 的 #42` | IID 为 42，且创建快照时为 OPEN |
| IID 范围 | `处理 group/project 的 #100 到 #250` | 闭区间 `100 <= iid <= 250`，只限 OPEN，不排除任何标签 |
| 未完成 | `处理 group/project 中未完成的 Issue` | OPEN，且不含 `pr`、`timeout`、`blocked`、`blocked-*`、`failed`、`failed-*` |
| 指定标签 | `处理 group/project 中 label 为 smoke 的 Issue` | OPEN，精确包含标签 `smoke`，不额外排除任何标签 |

标签比较沿用 GitLab 返回的标签字符串，按精确值比较。`blocked-*` 与
`failed-*` 是前缀匹配，同时兼容历史裸标签 `blocked`、`failed`。

### 冻结快照

`req_executor` 在受理批次时分页查询一次 GitLab，按 IID 升序去重后原子写入
不可变 `snapshot.json`。批次后续 tick 只消费该清单：

- 新建 Issue 不加入。
- 后来才获得匹配标签的 Issue 不加入。
- GitLab 分页中任意一页失败时，整个快照创建失败，不保留部分批次。
- 快照冻结的是成员 IID；每个成员真正启动前仍重新读取实时 state/labels，
  防止已经 CLOSED 或刚完成的 Issue 被错误执行。

### 终态标签与重跑

每个快照成员启动前按实时 GitLab 状态决定执行模式：

1. Issue 已 CLOSED：`skipped`，不执行。
2. 带 `pr` 且用户只是普通“处理”：视为已完成，`skipped`。
3. 带 `pr` 且用户明确说“重跑”“重新处理”或“重新执行”：设置
   `force_rerun_pr=true`，覆盖完成态并按全新执行处理；即使同时存在
   `continue`，本条的 fresh 语义也优先。
4. 未命中前述 `pr` 规则、但带 `continue` 或兼容拼写 `contiune`：沿用现有
   continue 语义，从工作分支续跑。
5. 显式选中的 `timeout`、`blocked-*`、`failed-*` 以及其他非 continue 情形：
   按 retry/fresh 语义从目标分支重新开始，用户不需要预先手工改标签。

“明确重跑措辞”只控制 `pr` 完成态覆盖；它不会让 CLOSED Issue 重新打开。

## 架构边界

### req_dispatcher：控制面

`req_dispatcher` 负责：

- 识别 `execute_issue` 批量意图并确定性解析选择器。
- 捕获 origin、生成全局唯一 `batch_id`、按 project 路由 executor。
- 把结构化批次请求交给 executor，不传 GitLab token。
- 保存批次镜像：executor、origin、matched/terminal 计数、最后 event_id 和状态。
- 按 `event_id` 幂等接收逐项回调，并通过现有反向网关逐条通知用户。
- 对 executor 发送周期性恢复 tick；该 tick 幂等，不重新解析或扩大快照。

dispatcher 不保存完整 IID 快照，不持有物理执行槽位；这样批次数千条时，
dispatcher 的用户闭环状态仍保持很小。

### req_executor：执行面与物理调度真相源

`req_executor` 新增 agent 级持久调度层，位于项目仓库之外：

```text
${EXECUTOR_SCHEDULER_ROOT:-/data/req_executor/_scheduler}/
  scheduler_state.json
  scheduler.lock
  batches/<batch_id>/
    request.json
    snapshot.json
    state.json
  callback_inbox/
  callback_outbox/
```

tracked 蓝区默认继续位于 `/data`。工作站测试只能通过进程环境或忽略的
`*.local.env` 覆盖，不能把本机路径写进 tracked 配置。

executor agent 级调度器负责：

- 使用 executor 自持 token 查询 GitLab 并写不可变快照。
- 保存每个批次的游标、状态和计数。
- 维护全 agent 共享的执行槽位；默认 `3`，部署配置可覆盖。
- 在多个可运行批次间严格轮转。
- 为项目级 campaign 发放本轮 grant，并跟踪物理作业租约。
- 将项目 Phase 6 的终态 handoff 持久导入 outbox，再重试回投 dispatcher。

### 项目级 campaign：受控补位

现有项目级 `campaign_state.json`、`campaign.lock`、worktree 和 Phase 6 保留。
新增显式 `driven_topup` 模式：

- scope 是“当前合法 driven pending + 本轮 agent 调度器 grant”。
- 不允许把其他 driven pending 当成 scope 外任务驱逐。
- 候选排除已经 pending/running 的 IID。
- 容量由 agent 级 grant 决定，不再把项目内 `max_concurrent_subagents`
  当成跨项目总并发真相源。
- `scheduled` 与 `driven` 通过项目 owner lease 互斥；另一模式到达时返回
  `busy`，不得覆盖当前 scope。

agent 级 `scheduler.lock` 只保护预留和状态提交。调用任何项目 wrapper 前必须
释放 agent 锁，避免与项目 `campaign.lock` 形成锁序死锁。

## 协议

### I1：创建受驱动批次

新增 trigger：

```text
RUN_DRIVEN_ISSUE_BATCH
batch_id=<dispatcher 生成的稳定 ID>
correlation_id=<dispatcher 关联 ID>
project=<group/project>
selector_type=single|range|open_unfinished|open_label
iid=<正整数，仅 single>
iid_min=<正整数，仅 range>
iid_max=<正整数，仅 range>
label=<精确标签，仅 open_label>
force_rerun_pr=true|false
dispatcher_callback_target=<req_dispatcher target>
branch=<可选目标分支>
```

要求：

- `batch_id` 幂等。相同 `batch_id` 和相同 request digest 重放只返回现有批次；
  相同 ID 但请求内容不同则 fail closed。
- executor 从自身 env/config 加载 token 和 `/data` 根，不接受 dispatcher 传 token。
- 创建成功返回紧凑 envelope，包含 `status`、`batch_id`、`matched_count`、
  `snapshot_digest`、`scheduler_status`；不返回完整 IID 数组。
- `matched_count=0` 时批次直接完成，dispatcher 只通知一次“没有匹配的 OPEN Issue”。

### I2：恢复和补位

新增 trigger：

```text
RUN_EXECUTOR_BATCH_TICK
```

它在 executor main session 上运行：

1. 处理项目 handoff 和 callback outbox。
2. 驱逐或恢复超时的 reserved/preparing 租约。
3. 计算全 agent 空闲槽位。
4. 严格轮转所有可运行批次并发放 grant。
5. 逐个调用 `sessions_spawn` 等待 ack；已 ack 的子代理并行运行。
6. 写回 spawned/launch_failed 结果并再次尝试填满空槽。

批次创建成功、每个子代理 Phase 6 完成以及部署周期唤醒都会触发该 tick；任意
一次中断都可由下一次 tick 恢复。

### I3：逐项终态回调

executor outbox 发往 dispatcher 的信封：

```json
{
  "event_id": "reqd-batch-20260710-0001:snapshot-12:terminal-1",
  "batch_id": "reqd-batch-20260710-0001",
  "snapshot_index": 12,
  "project": "group/project",
  "iid": 42,
  "status": "done|failed|timeout|skipped",
  "mr_url": null,
  "reason": null
}
```

- `event_id` 在 executor 持久化生成，重试不变。
- dispatcher 先按 `event_id` 幂等落账，再逐条调用 `notify_user.sh`。
- dispatcher 回调路径返回包含相同 `event_id` 的 accepted ack；executor 只有
  收到该 ack 才把 outbox 条目标记为 delivered。
- 回投失败时 outbox 保留；收到 dispatcher ack 后才标记 delivered。
- `skipped` 用于 CLOSED、普通处理遇到 `pr`、或其他实时预检已不应执行的情况。
- 不另发周期性聚合通知；最后一条逐项通知可以附带“本批次已结束”的计数，
  但不再单独制造一条汇总通知。

## 公平调度与去重

### 严格轮转

每次填槽按以下规则：

1. 从持久 round-robin 游标后的第一个 runnable batch 开始。
2. 本轮每个 runnable batch 最多领取一个 item。
3. 若仍有空槽，再进入下一轮。
4. 单批次内部始终按 snapshot IID 升序推进。
5. `reserved`、`preparing`、`running` 都占用槽位；只有终态或明确回滚预留才释放。

因此，只有一个批次时可连续占满默认 3 个槽位；多个批次并存时会公平共享。

### 同 Issue 互斥

物理 worktree 以 Issue 为单位，不能并发执行相同 `(完整 project, iid)`。

- 执行意图完全相同（目标分支、continue/fresh、`force_rerun_pr` 相同）时，
  多个批次 membership 共享一个物理作业；终态结果向每个 membership 的
  dispatcher origin 扇出。
- 执行意图不同则不合并；后到 membership 等待该 `(project,iid)` 租约释放后
  再单独执行。
- 路径键使用完整 `group/project`，不能只用短 project slug，避免不同 group
  的同名仓库共用 clone、worktree 或锁。

## 状态机

### 批次状态

```text
resolving -> queued -> running -> completed
    |          |          |
    +----------+----------+-> failed
```

- `resolving`：正在分页查询并创建不可变快照。
- `queued`：快照完成但尚无物理作业运行。
- `running`：至少一个 membership 已 reserved/active 或仍有待领取项。
- `completed`：所有 snapshot membership 均有终态事件，包括 `skipped`。
- `failed`：快照创建失败、请求冲突或不可恢复的状态损坏；不会保留部分快照继续跑。

### membership 与物理作业

批次 membership 使用：

```text
pending -> attached|reserved -> preparing -> running -> terminal
             |                    |
             +--------------------+-> retry_wait -> preparing
pending -------------------------------------------> skipped
```

`attached` 表示共享另一个批次已经启动的相同物理作业。retry/blocked 行为沿用
现有 executor policy；只有最终 `done/failed/timeout/skipped` 才向 dispatcher
发送用户可见结果。

## 回调可靠性与恢复

当前 `dispatch_followup.sh` 在项目锁持有期间 best-effort 发送 dispatcher 回调，
发送失败也会让 Phase 6 成功返回。新路径改成：

1. Phase 6 在项目锁内完成标签和项目状态写入，同时原子写项目本地 terminal handoff。
2. 释放项目锁。
3. 将 handoff 幂等导入 agent 级 `callback_outbox/`，释放物理槽位。
4. outbox worker 发送 I3；失败保留，周期 tick 重试。
5. dispatcher 按 `event_id` 去重后通知用户。

恢复规则：

- `reserved/preparing` 超时：回滚到待领取或转成 launch failure，复用稳定 item ID。
- `running` 超时：沿用 executor 的 stuck/timeout 证据和 Phase 6 规则，生成终态 handoff。
- executor 重启：从 scheduler state、batch cursor、物理租约和项目 pending 重建空槽。
- dispatcher 重启：从批次镜像与 event ledger 恢复通知去重；executor outbox 会重投未 ack 事件。
- 同一批次创建消息、tick 或终态回调都允许至少一次投递，不允许依赖聊天内存。

## 兼容与迁移

- `RUN_SINGLE_ISSUE` 保留为兼容入口，内部转成 matched_count=1 的单 item driven batch，
  从而与其他批次共享 agent 级并发上限。
- `RUN_SCHEDULED_ISSUE_CAMPAIGN` 保留；同项目已有 driven owner lease 时返回 busy，
  不得改写 scope。反向同理。
- 部署升级时，旧 dispatcher FIFO 的 active/queue 继续按旧路径排空，不做破坏性
  迁移；新请求可以持久化为 `waiting_for_legacy_drain`，但在旧 queue 清空前不向
  executor 提交新批次。排空后切换到新 scheduler，避免旧 active 与新 3 槽位重叠。
- dispatcher 继续兼容旧单 Issue I2 信封；新 I3 通过 `event_id/batch_id` 与旧路径区分。
- 完整 project 的 clone 路径需要 collision-safe 映射，并且仍在 `/data` 下。
  已存在 legacy clone 只有在 `origin` 与目标 project 完全匹配时才能复用；不匹配时
  必须使用新路径，绝不能重写现有 clone 的 origin。

## 失败策略

- project 或选择器不合法：dispatcher 直接要求补充，不调用 executor。
- GitLab 快照分页任一页失败：batch `failed`，通知用户，不执行部分结果。
- 同 batch ID 内容冲突：fail closed，不覆盖旧批次。
- project route 缺失：沿用现有失败通知和 ledger。
- launch ack 失败：沿用同 payload 3 次、2 秒固定退避；耗尽后进入现有 blocked/retry
  处理，不静默丢 membership。
- 项目 owner 冲突：返回 busy，由周期 tick 重试，不驱逐另一 owner。
- callback 发送失败：保留 outbox 并重试，不改变已经完成的 Phase 6 结果。
- state/manifest JSON 损坏：停止对应 batch，记录 ops 事件；不从 GitLab 重新创建一个
  可能不同的快照冒充原批次。

## 测试策略

### req_dispatcher

- 单 IID、范围、未完成、指定标签的确定性解析。
- 范围为闭区间，标签模式不应用终态排除。
- 只有明确重跑措辞才设置 `force_rerun_pr=true`。
- executor trigger 不含 token，包含稳定 batch/correlation/origin callback 信息。
- 新 I3 `event_id` 重放只落一份终态，不重复推进；逐条用户通知按现有通道执行。
- `matched_count=0` 只通知一次。
- 旧 I2/FIFO active 回调兼容。

### req_executor

- GitLab 多页 OPEN Issue 全量读取、升序去重、四类 selector 过滤。
- 分页中途失败不会留下可运行的部分快照。
- 相同 batch ID 幂等重放与内容冲突拒绝。
- 默认并发 3，配置覆盖生效。
- 单批次填满 3 个槽位；多批次严格轮转。
- 某项终态后立即补位，不等待同窗口其他项结束。
- `(project,iid)` 物理互斥、相同意图共享、不同意图串行。
- 普通处理跳过 `pr`；明确重跑覆盖 `pr`；continue 续跑；其他终态 fresh。
- CLOSED 实时预检跳过。
- `driven_topup` 不 scope-evict 合法 pending；scheduled/driven owner 互斥。
- 项目锁与 agent 锁不嵌套。
- handoff/outbox 在发送失败和进程重启后重投，event ID 保持不变。
- 同名短 slug 的不同 group 使用不同 clone/worktree 路径。

### 端到端模拟

- 一个含 250 个 IID 的快照不会展开成 dispatcher 旧 FIFO 的 250 个完整对象。
- 两个批次共享默认 3 槽位，启动顺序符合严格轮转。
- 每个终态都回投正确 batch/origin 并逐条推用户。
- 在快照创建后新增匹配 Issue，不会进入批次。
- 在 reserved、preparing、running、outbox send 四个位置模拟中断，周期 tick 均能恢复。

## 部署与版本

- `req_dispatcher`、`req_executor` 均部署在蓝区 `10.64.5.104`；不新增跨区直连。
- executor GitLab host/token 继续由 executor 侧现有环境或 `config/gitlab.env` 注入。
- scheduler 持久根默认保持 `/data`；本地测试只使用忽略的 local env 或进程环境覆盖。
- 部署增加或复用周期唤醒 `RUN_EXECUTOR_BATCH_TICK`，建议 1 分钟一次。
- 所有 `workspace-req_dispatcher` 改动完成时 bump
  `skills/requirement_dispatch/SKILL.md`。
- 所有 `workspace-req_executor` 改动完成时 bump
  `skills/gitlab_issue_campaign_dispatcher/SKILL.md`。

## 实施范围

预计修改：

- `workspace-req_dispatcher`：动作/选择器契约、批次镜像与 I3 回调脚本、配置、测试和文档。
- `workspace-req_executor`：agent 级 scheduler、批次快照发现、driven topup、持久 outbox、
  单 Issue shim、完整 project 路径映射、测试和文档。
- 根目录 `docs/superpowers/plans/`：本设计对应的分步实施计划。

不修改任何 tracked 蓝区 token、GitLab 地址、`/data` clone 根或 callback 默认目标。
