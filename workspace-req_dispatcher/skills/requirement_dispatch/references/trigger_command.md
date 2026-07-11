# Trigger / 跨 agent 调用契约

本文件只定义 public trigger、严格 JSON 与顶层 wrapper。LLM 不得把内部脚本展开为临时
编排。

## 接入与 origin

114/WebUI 自然语言先交给 `capture_origin.sh`。origin 优先读取 OpenClaw 运行时来源元数据，
正文 `[origin]` 行只是 fallback。origin 只允许
`channel,user,conversation,reply_agent,source_agent,source_session`；不得包含 token。

动作只有 `create_issue|execute_issue|create_and_execute|clarify_or_reject`。建单继续使用既有
git_issuer 准备与调用 wrapper；所有执行动作进入下面的 batch wrapper。

## Dispatcher 顶层 trigger

路由第一优先级是首行精确 `RUN_DRIVEN_BATCH_RESULT`；它必须直接进入下面的固定 I3 handler，
不得落入自然语言动作判断。

### 自然语言执行

```bash
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
RUN_DRIVEN_BATCH_RESULT
worker_result_json={"event_id":"<id>","batch_id":"<batch>","snapshot_index":0,"project":"group/project","iid":42,"status":"done","mr_url":null,"reason":null}
```

```bash
WORKER_RESULT_JSON='<完整 RUN_DRIVEN_BATCH_RESULT message>' \
bash scripts/handle_executor_batch_event.sh
```

handler 兼容直接传纯八字段 I3 JSON，但不得由 LLM 手工解包真实 transport。transport 必须只有
精确首行和唯一一行 `worker_result_json=`；额外行、重复 `worker_result_json`、非 object、缺字段或
多字段都非零 fail closed，且不得进入 durable apply、bridge、通知或网络调用。

stdout 必须只有一个严格 accepted/duplicate ack JSON；bridge、通知和网络 stdout 均被隔离，
通知失败只写 stderr/state。

## I1：RUN_DRIVEN_ISSUE_BATCH

只有 `build_executor_batch_payload.sh` 可以生成 I1：

```text
RUN_DRIVEN_ISSUE_BATCH
batch_id=<稳定安全 ID>
correlation_id=<稳定 reqd-N>
project=<完整 group/project>
selector_type=single|range|open_unfinished|open_label
iid=<single 专用正整数>
iid_min=<range 专用正整数>
iid_max=<range 专用正整数，且 >= iid_min>
label=<open_label 专用精确标签>
force_rerun_pr=true|false
dispatcher_callback_target=<非空回调目标>
branch=<可选安全 Git ref>
```

四类 selector 只允许各自字段：

- `single`：仅 `iid`；
- `range`：仅 `iid_min/iid_max`，闭区间；
- `open_unfinished`：无 selector 附加字段；
- `open_label`：仅非空 `label`。

四类 selector 都只查询 intake 时为 OPEN 的 Issue。`open_unfinished` 排除
`pr,timeout,blocked,blocked-*,failed,failed-*`，`open_label` 不追加终态标签排除；普通处理实时
遇到 `pr` 时跳过，只有明确重跑语义把 `force_rerun_pr` 设为 true。CLOSED 不进入 snapshot。

`dispatcher_callback_target` 为空时必须在 ID 分配、intent 落盘和网络调用之前拒绝。
I1 不允许 `gitlab_token,GITLAB_TOKEN,GLAB_TOKEN,WIKI_GITLAB_TOKEN` 或任何 IID snapshot。
executor 使用自己的部署凭据查询 GitLab。

### I1 durable intent

`enqueue_executor_batch_request.sh` 在任何 `run_agent_turn.sh` 之前原子写
`executor_batch_outbox.json`。旧 `executor_queue.json` 的 active 或 queue 非空时，状态固定为
`waiting_for_legacy_drain`，I1 调用次数必须为零。

旧队列清空后，`drain_executor_batch_outbox.sh` 以 intent 中原始 payload 发送。调用失败、
ack 丢失或进程中断只增加 attempts/保留错误，后续仍使用同一
`batch_id/correlation_id/payload`。

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
- public acceptance 不得含 IID 数组、grant、claim token、GitLab token、raw scheduler state。

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
branch=<可选>
```

executor single shim 把它转成 single driven batch，并返回上面的严格五字段 public acceptance。
dispatcher 以 acceptance `batch_id` 写入旧 active 的 `driven_batch_id` bridge，然后创建 mirror。

single shim 后续只发送 I3：

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

这条旧 I2 仍走 pending/correlation 二次校验、`notify_user.sh`、`drain_pending.sh`、
`finish_executor_queue_active.sh`。新 batch 不发送旧 I2。

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
- 第一次返回 `accepted`；一致重放返回 `duplicate`；两者都带同 event_id，且都触发通知 drain。
- event_id 内容冲突、snapshot_index 越界或 batch 未记录时 fail closed；unknown 不 ack。
- I3 handler stdout 精确为：

```json
{"status":"accepted|duplicate","event_id":"<same event_id>"}
```

通知失败不改变 ack。通知成功日志已经持久化、但 `delivered_at` 尚未提交就崩溃时，下次 drain
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

## Token 边界

- wiki 读取仍可在本地准备脚本使用 `WIKI_GITLAB_TOKEN`。
- git_issuer 的既有 `run_agent_turn.sh` 环境契约不改。
- 只有 req_executor I1/旧 single I1 与 batch notification 外部进程边界显式 scrub GitLab token。
- token 不得进入 payload、outbox、mirror、event ledger、notification item 或错误摘要。
