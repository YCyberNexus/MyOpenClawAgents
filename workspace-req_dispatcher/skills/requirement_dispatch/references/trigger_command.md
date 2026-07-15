# Trigger / 跨 agent 调用契约

本文件只定义 public trigger、严格 JSON 与顶层 wrapper。LLM 不得把内部脚本展开为临时
编排。

## 接入与 origin

114/WebUI 自然语言先交给 `capture_origin.sh`。origin 优先读取 OpenClaw 运行时来源元数据，
正文 `[origin]` 行只是 fallback。origin 只允许
`channel,user,conversation,reply_agent,source_agent,source_session`，不接受其他字段。

动作只有 `create_issue|execute_issue|create_and_execute|clarify_or_reject`。建单继续使用既有
git_issuer 准备与调用 wrapper；所有执行动作进入下面的 batch wrapper。

## Dispatcher 顶层 trigger

路由第一优先级是首行精确 `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY`；兼容旧首行
`RUN_DRIVEN_BATCH_RESULT`。两者都必须直接进入下面的固定 I3 handler，不得落入自然语言动作判断。

### 运行时 slot 配置

用户命令固定为：

```text
/slot <正整数>
```

首行以 `/slot` 开始时调用：

```bash
MESSAGE='<完整原文>' bash scripts/set_executor_slots.sh
```

wrapper 严格校验完整消息，把规范化命令发送到
`agent:${DEFAULT_EXECUTOR_AGENT}:main`，并只接受 executor 的严格六字段成功对象：
`status,slot_count,previous_slot_count,active_count,available_slots,draining`。该命令调整的是
目标 executor 的共享物理槽位上限，不是当前 dispatcher 或某个 batch session 的私有并发。
`draining=true` 表示缩容值低于当前 active 数；已有任务继续运行，新 reservation 暂停。

### 运行时 acpx timeout 配置

用户命令固定为：

```text
/timeout-executor <60..18000 秒|Nm|Nh>
```

首行以 `/timeout-executor` 开始时调用：

```bash
MESSAGE='<完整原文>' bash scripts/set_executor_acpx_timeout.sh
```

wrapper 把时长规范化为秒并发送到默认 executor 主 session，只接受严格
`status,acpx_timeout_seconds,previous_acpx_timeout_seconds,
executor_agent_timeout_seconds,exec_tool_timeout_seconds,
queue_launch_reclaim_seconds,stuck_after_minutes,active_count,applies_to`
成功对象。新值仅影响后续 attempt，不改写在途任务的启动时预算。dispatcher
后续从 executor scheduler state 派生这些外层值；OpenClaw 全局 timeout 保持
独立部署值，命令不读取或写入它。旧 FIFO active 与 pending 保存创建时预算，
调低 timeout 不会让已经在途的旧任务提前回收或驱逐。

### 自然语言执行

`create_and_execute` 在 git_issuer 成功后必须保留用户的完整原请求，并把新返回的
`issue_url` 作为新增一行追加到同一个 `MESSAGE`；不得只拼接 URL、分支或模型转述，避免丢失
自动合并动作、合并目标及否定语义。

先在加载 `source_dispatcher_env.sh` 的同一环境调用
`get_executor_timeout_budget.sh`。它会显式读取并严格校验 executor scheduler state；
state 不存在、不可读或无效时立即停止。把严格结果中的
`exec_tool_timeout_seconds` 用作下面 Bash 调用的 OpenClaw exec 工具 timeout。
不得使用固定值或历史缓存。

```bash
source scripts/source_executor_timeout_budget.sh && \
MESSAGE='<原文>' ORIGIN_JSON='<origin 或 null>' \
bash scripts/submit_executor_batch.sh
```

它内部固定执行：

```text
prepare_executor_issue_payload.sh
  -> route_project.sh
  -> build_executor_batch_payload.sh
  -> enqueue_executor_batch_request.sh
  -> drain_executor_batch_outbox.sh
```

若已有 `prepare_executor_issue_payload.sh` 的严格 stdout，可以原样传
`PREPARED_REQUEST_JSON`；不得手写字段。

### Dispatcher 周期 tick

收到 `RUN_EXECUTOR_BATCH_TICK` 或兼容 `RUN_EXECUTOR_QUEUE_DRAIN`：

```bash
source scripts/source_executor_timeout_budget.sh && \
bash scripts/run_executor_batch_tick.sh
```

只读取：

```json
{
  "status":"tick",
  "legacy_recovery_before":{},
  "legacy_queue":{},
  "legacy_recovery_after":{},
  "batch_outbox":{},
  "notifications":{}
}
```

不得根据子对象自行调用内部脚本。

### Dispatcher I3 callback

executor outbox 发送的真实 message 是：

```text
RUN_DRIVEN_BATCH_RESULT_ACK_ONLY
callback_envelope={"batch_acceptance":{"status":"success","batch_id":"<batch>","matched_count":1,"snapshot_digest":"<64 个小写 hex>","scheduler_status":"completed"},"callback_nonce":"<64 个小写 hex>","executor_agent":"req_executor","worker_result_json":{"event_id":"<id>","batch_id":"<batch>","snapshot_index":0,"project":"group/subgroup/project","iid":42,"status":"done","mr_url":null,"reason":null}}
ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。
```

```bash
bash -c 'source scripts/source_dispatcher_env.sh; WORKER_RESULT_JSON="$(cat)" bash scripts/handle_executor_batch_event.sh' <<'CALLBACK_EOF'
<完整 callback marker message>
CALLBACK_EOF
```

handler 也接受把严格四字段 `callback_envelope` 对象直接放入 `CALLBACK_ENVELOPE_JSON`，但不得由
LLM 手工解包真实 transport，也不得把 callback、nonce 或中间命令写入 `/tmp`、workspace 或
其他临时文件。新 transport 必须恰好包含精确首行、唯一一行 `callback_envelope=`
和上述逐字匹配的固定第三行；旧 marker 两行格式继续兼容。外层
新外层必须恰好是 `batch_acceptance,callback_nonce,executor_agent,worker_result_json`；滚动升级期间
继续兼容原三字段认证 envelope。`batch_acceptance` 必须是同 batch 的严格五字段 public
acceptance，内层 public I3 仍必须恰好八字段。
额外行、重复字段、非 object、缺字段或多字段都非零 fail closed，且不得进入 durable apply、
bridge、通知或网络调用。纯八字段 I3 只兼容已经明确标记 `legacy_pre_upgrade` 的部署前 mirror；
任何新 batch/single mirror 都禁止降级接受纯 I3。

durable apply 在提交 event ledger 前固定校验：nonce 的 SHA-256 等于 mirror 摘要、I3 project 等于
mirror project、envelope executor_agent 等于路由后 executor。nonce 明文不得进入 public
acceptance、compact mirror、event ledger、用户通知或日志。

mirror 缺失时，handler 先用 nonce、project、executor 对齐原 durable I1，再从
`batch_acceptance` 幂等补写 receipt/mirror；同步 acceptance 即使因超时或会话中断丢失，已经完成
的同一 I3 也不会陷入 `unknown_batch` 重投循环。

stdout 必须只有一个严格 accepted/duplicate ack JSON；bridge、通知和网络 stdout 均被隔离，
通知失败只写 stderr/state。最终 assistant 内容必须是该 stdout JSON 原样，禁止前后缀、Markdown、
解释、总结或第二个对象。旧 marker 只保留输入兼容，不放宽 schema、nonce 或 ack 校验。

## I1：RUN_DRIVEN_ISSUE_BATCH

只有 `build_executor_batch_payload.sh` 可以生成 I1：

```text
RUN_DRIVEN_ISSUE_BATCH
batch_id=<稳定安全 ID>
correlation_id=<稳定 reqd-N>
project=<完整 group/subgroup/.../project>
executor_agent=<路由后的 executor agent>
selector_type=single|iid_list|range|open_unfinished|open_label
iid=<single 专用正整数>
iids=<iid_list 专用、升序去重的逗号分隔正整数列表，至少两个>
iid_min=<range 专用正整数>
iid_max=<range 专用正整数，且 >= iid_min>
label=<open_label 专用精确标签>
force_rerun_pr=true|false
auto_merge=true|false
dispatcher_callback_target=<非空回调目标>
callback_nonce=<dispatcher 生成的 64 个小写 hex>
branch=<可选安全 Git ref；处理基准分支>
merge_target_branch=<可选安全 Git ref；MR 目标分支；auto_merge=true 时必填>
```

五类 selector 只允许各自字段：

- `single`：仅 `iid`；
- `iid_list`：仅 `iids`，规范形式如 `1,4,5`；
- `range`：仅 `iid_min/iid_max`，闭区间；
- `open_unfinished`：无 selector 附加字段；
- `open_label`：仅非空 `label`。

解析原始请求时，必须先把 `single/iid_list/range/open_unfinished/open_label` 全部规范化为
selector 证据并去重，不能按类型优先级静默选中一个。同一 project 下由逗号、顿号、“和、
跟、与、及、and”等明确并列的多个 IID 规范化为一个升序去重 `iid_list`；“或/or”表达的备选
IID 必须澄清。离散 IID 与范围或其他类型组合、同类型不同值，以及范围附加非 OPEN 状态都必须
失败并要求拆分/澄清。只有同一 selector 的等价重复可以去重通过；`OPEN/打开`仅是状态修饰词，
不产生第二个 `open_unfinished` selector。

五类 selector 都只查询 intake 时为 OPEN 的 Issue。`open_unfinished` 排除
`pr,finish,timeout,blocked,blocked-*,failed,failed-*`，`open_label` 不追加终态标签排除；普通处理实时
遇到 `pr` 或 `finish` 时跳过，只有明确重跑语义把 `force_rerun_pr` 设为 true。CLOSED 不进入 snapshot。
重跑动作词可以位于 Issue 宾语之后；同分句中的“不要、无需、不需要、不得”等否定窗口保持
false，label/branch selector 值中的动作词不算动作。project 支持多层 subgroup；可信 GitLab
仓库根 URL 保留完整 path，带 `/-/` 的 URL 保留其前 path。Issue URL、仓库 URL、
`projects/...` 与裸路径候选统一规范化去重，多个不同候选必须澄清，不能静默截断或选第一个。

`dispatcher_callback_target` 为空时必须在 ID 分配、intent 落盘和网络调用之前拒绝。
I1 字段固定为上表，不携带任何 IID snapshot。
`callback_nonce` 只允许以明文存在私有 durable outbox/intent 与发送中的 I1；重投必须复用原值，
不得重新生成。

`auto_merge=true` 只能来自用户明确的“完成后直接/自动 merge”语义，否定表达不得启用。
`branch` 与 `merge_target_branch` 分别表示处理基准和 MR 目标：未指定 MR 目标时回退到处理基准，
两者都未指定时使用 `master`。仅给出普通 MR 目标但没有完成后合并动作时，保持
`auto_merge=false`，MR 创建后停留在 `pr`。
自然语言及用户输入字段中，`branch`、`base_branch`、`source_branch` 与“基于某分支”映射到
处理基准；`target_branch`、`merge_target_branch` 与“目标分支”映射到 MR 目标。只给出后者
时，处理基准兼容性回退到同一分支，但字段归属不能覆盖另行明确指定的处理基准。

### I1 durable intent

`enqueue_executor_batch_request.sh` 在任何 `run_agent_turn.sh` 之前原子写
`executor_batch_outbox.json`。旧 `executor_queue.json` 的 active 或 queue 非空时，状态固定为
`waiting_for_legacy_drain`，I1 调用次数必须为零。

旧队列清空后，`drain_executor_batch_outbox.sh` 以 intent 中原始 payload 发送。调用失败、
ack 丢失或进程中断只增加 attempts/保留错误，后续仍使用同一
`batch_id/correlation_id/payload`。

submit 使用 `BATCH_ID` 定向 drain。若并发 tick 已把该 batch 标成 `accepted`，定向调用只从
outbox 重建 `record_status=duplicate` 的 compact acceptance，不再调用 executor；若另一个进程
正持有该 batch 的投递锁，则从 outbox 返回
`retryable_failure/reason=delivery_in_progress`。对仍存在的目标 batch 不返回内部锁状态
`busy`，也不把并发完成误报成 `idle`。

### Executor public acceptance

`run_agent_turn.sh` 的 `worker_result_json` 只认精确五字段：

```json
{
  "status":"success",
  "batch_id":"reqd-batch-1",
  "matched_count":3,
  "snapshot_digest":"<非空摘要>",
  "scheduler_status":"queued|running|completed"
}
```

- `matched_count` 是非负整数；为 0 时 `scheduler_status` 必须为 `completed`。
- `executor_agent,matched_count,snapshot_digest` 是 immutable receipt 字段；同 intent 重放冲突
  必须非零 fail closed。
- `scheduler_status` 只允许向前演进：`queued -> running -> completed`。
- receipt 先持久化为 `received`，再创建 Task 8 mirror，最后标 `accepted`。
- public acceptance 不得含 callback nonce、IID 数组、grant、claim token 或 raw scheduler state。

Dispatcher 顶层返回：

```json
{
  "status":"accepted",
  "batch_id":"reqd-batch-1",
  "correlation_id":"reqd-1",
  "matched_count":3,
  "snapshot_digest":"<摘要>",
  "scheduler_status":"queued",
  "record_status":"accepted|duplicate"
}
```

或 durable 非终态：

```json
{"status":"waiting_for_legacy_drain","batch_id":"...","correlation_id":"..."}
```

```json
{"status":"retryable_failure","batch_id":"...","correlation_id":"...","reason":"...","attempts":1}
```

这两个状态都禁止生成新 ID。

## I2：旧 RUN_SINGLE_ISSUE 兼容

旧 FIFO 排空期间，`drain_executor_queue.sh` 仍构造：

```text
RUN_SINGLE_ISSUE
project=<group/project>
iid=<正整数>
correlation_id=<稳定 reqd-N>
dispatcher_callback_target=<非空目标>
executor_agent=<路由后的 executor agent；升级后新 intent 必填>
callback_nonce=<64 个小写 hex；升级后新 intent 必填>
branch=<可选>
```

executor single shim 把它转成 single driven batch，并返回上面的严格五字段 public acceptance。
dispatcher 以 acceptance `batch_id` 写入旧 active 的 `driven_batch_id` bridge，同时保存
`driven_project,driven_callback_auth_mode,driven_callback_nonce_sha256`，然后创建只含 nonce 摘要的
mirror。升级前已在途且没有 nonce 的旧 active/receipt 会被明确标记为 `legacy_pre_upgrade`。

single shim 后续只在上述认证 envelope 的 `worker_result_json` 中发送 I3：

```text
event_id=<single-batch-id>:snapshot-0:terminal-1
batch_id=<single-batch-id>
snapshot_index=0
```

`recover_legacy_executor_batch_bridge.sh` 在 I3 terminal 后删除匹配 pending、清 active，并推进
下一条；`matched_count=0` 用 receipt 直接完成同样收尾。bridge 重复恢复幂等。

升级前已经启动、仍使用旧 Phase 6 的 executor 可以继续发送：

```json
{
  "correlation_id":"reqd-23",
  "iid":42,
  "project":"group/project",
  "status":"done|failed|timeout",
  "mr_url":null,
  "wiki_url":null,
  "reason":null
}
```

这条旧 I2 仍走 `find_pending.sh`、`notify_user.sh`、`drain_pending.sh`、
`finish_executor_queue_active.sh`，但仅限同一 launched active/pending 在 dispatcher 锁内显式
投影为 `legacy_pre_upgrade`、身份逐项一致且完全没有 nonce 的部署前状态。nonce_v1、launching、
身份冲突或缺少已授权 drain ledger 证明时必须失败关闭。新 batch 不发送旧 I2。

## I3：逐项终态

public I3 必须精确八字段：

```json
{
  "event_id":"reqd-batch-1:snapshot-0:terminal-1",
  "batch_id":"reqd-batch-1",
  "snapshot_index":0,
  "project":"group/project",
  "iid":42,
  "status":"done|failed|timeout|skipped",
  "mr_url":null,
  "reason":null
}
```

约束：

- `event_id` 必须等于
  `<batch_id>:snapshot-<snapshot_index>:terminal-1`；重投保持不变。
- handler 先提交 event ledger，再修 mirror/notification 投影。
- 第一次返回 `accepted`；一致重放返回 `duplicate`；两者都带同 event_id，并在 durable apply 后
  立即返回。bridge 恢复和通知 drain 由后续 `RUN_EXECUTOR_BATCH_TICK` 完成。
- event_id 内容冲突、snapshot_index 越界或 batch 未记录时 fail closed；unknown 不 ack。
- I3 handler stdout 精确为：

```json
{"status":"accepted|duplicate","event_id":"<same event_id>"}
```

通知失败不改变 ack。通知成功日志已经持久化、但 `delivered_at` 尚未提交就崩溃时，下次 tick/drain
先从 event 专属 state root 的 durable log 修复 `delivered_at`，不得再次调用 OpenClaw。

## Zero-match

`matched_count=0` 不生成虚假 IID/I3。dispatcher 在 receipt 后幂等创建：

```json
{
  "event_id":"<batch_id>:no-matches",
  "iid":null,
  "status":"no_matches",
  "reason":"无匹配 OPEN Issue"
}
```

它进入同一 durable notification queue；重启、receipt 重放和 tick 只能保留一条 intent，交付后
不再调用通知通道。

## 外部进程环境

- wiki 读取仍由本地准备脚本使用只读 `WIKI_GITLAB_TOKEN`，不得用于 GitLab 写操作。
- git_issuer 的既有 `run_agent_turn.sh` 环境契约不改。
- req_executor I1、旧 single I1 与 batch notification 外部进程继承调用方进程环境；transport、
  payload 与 notification 数据仍按本文件定义的严格 schema 构造。
