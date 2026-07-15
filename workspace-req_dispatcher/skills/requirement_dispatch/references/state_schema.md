# State Schema

`req_dispatcher` 只保存控制面小状态，不保存 executor 的 IID snapshot、物理槽位、worktree、
campaign state 或 claim token。所有文件由 `env_paths.sh` 从 `STATE_ROOT` 派生，
并共用 `pending.lock`；网络调用永远在共享锁外。

五类 selector 的 snapshot 都由 executor 从 intake 时的 OPEN Issue 冻结；dispatcher state 不保存
或补建 CLOSED Issue 记录。

## 磁盘布局

```text
${STATE_ROOT}/_dispatcher/
  pending.json
  executor_queue.json
  executor_batch_outbox.json
  executor_batches.json
  executor_batch_events.jsonl
  executor_batch_notifications.json
  executor_batch_notification_attempts/<event-hash>/
  accepted_intents/<sha256(batch_id)>.json
  delivered_notifications/<sha256(event_id)>.json
  ledger.jsonl
  seq
  pending.lock
  log/
```

初始值：

```json
{"pending":{}}
```

```json
{"next_id":1,"active":null,"queue":[]}
```

```json
{"version":1,"requests":[]}
```

```json
{"batches":{}}
```

```json
{"notifications":[]}
```

`executor_batch_events.jsonl` 与 `ledger.jsonl` 初始为空。

## `executor_batch_outbox.json`

每条新执行请求先写一条私有 durable intent。`callback_nonce` 是 256-bit 随机值的 64 字符
小写 hex 表示，明文只允许保留在该私有 intent/I1 中：

```json
{
  "version":1,
  "requests":[{
    "batch_id":"reqd-batch-1",
    "correlation_id":"reqd-1",
    "project":"group/subgroup/project",
    "selector":{"type":"range","iid_min":1,"iid_max":3},
    "force_rerun_pr":false,
    "auto_merge":false,
    "target_branch":null,
    "merge_target_branch":null,
    "executor_agent":"req_executor",
    "callback_nonce":"<64 lowercase hex>",
    "origin":{"channel":"wecom","user":"u","conversation":"c","reply_agent":"reply"},
    "payload":"RUN_DRIVEN_ISSUE_BATCH\n...",
    "request_digest":"<sha256>",
    "status":"waiting_for_legacy_drain|queued|received|accepted",
    "attempts":1,
    "last_attempt_at":"2026-07-11T00:00:00Z",
    "last_error":null,
    "matched_count":3,
    "snapshot_digest":"<executor snapshot digest>",
    "scheduler_status":"queued|running|completed",
    "created_at":"2026-07-11T00:00:00Z",
    "updated_at":"2026-07-11T00:00:00Z",
    "received_at":"2026-07-11T00:00:00Z",
    "accepted_at":"2026-07-11T00:00:00Z"
  }]
}
```

状态：

- `waiting_for_legacy_drain`：旧 FIFO active/queue 非空；I1 尚未发送。
- `queued`：intent 可发送；失败或 ack 不明时仍保持该状态并复用原 payload。
- `received`：严格五字段 executor receipt 已落盘，mirror/zero notification/accepted 投影可恢复。
- `accepted`：receipt、mirror 和 zero-match intent 已完成本地提交。

`waiting/queued` 的 receipt 字段与 `received_at/accepted_at` 都为 `null`；`received` 的
`matched_count,snapshot_digest,scheduler_status,received_at` 非空而 `accepted_at=null`；
`accepted` 全部非空。

`accepted` 只是提交阶段的热状态：drain 先把不含明文 nonce/payload 的精简记录写入
`accepted_intents/<sha256(batch_id)>.json`，校验内部 `batch_id` 后再原子移出热 outbox。
按 `BATCH_ID` 重放直接读取冷档。若崩溃留下 cold accepted 与 hot received 并存，只有两边
correlation、认证模式和 acceptance 事实完全一致时才清理热行；任何冲突都失败关闭。

同一 `batch_id` 只允许一个 request digest。receipt 重放固定校验
`executor_agent,matched_count,snapshot_digest`；冲突非零退出且不修改 state。
`scheduler_status` 只允许向前演进。
带 `callback_nonce` 的 nonce_v1 intent 在 receipt 发布前还必须要求 `snapshot_digest` 为
64 位小写 SHA-256；部署前 legacy intent 继续接受原可打印摘要。nonce_v1 acceptance、I3
公开字段及 legacy single receipt 还必须在任何 mirror、ledger、冷档、通知或公开输出前拒绝
包含原始 callback nonce 的下游内容，避免 bearer secret 被 executor 回显。

升级后新 intent 必须含 nonce，且 `payload` 中的 `executor_agent/callback_nonce` 必须与同一行
durable 字段精确一致。部署前已经在途、缺少 nonce 的旧 outbox 行只用于恢复，并在建 mirror 时
显式投影为 `legacy_pre_upgrade`，不能由新 intake 创建。

## `executor_batches.json`

Task 8 compact mirror：

```json
{
  "batches":{
    "reqd-batch-1":{
      "batch_id":"reqd-batch-1",
      "project":"group/subgroup/project",
      "executor_agent":"req_executor",
      "callback_auth_mode":"nonce_v1",
      "callback_nonce_sha256":"<sha256>",
      "origin":null,
      "matched_count":3,
      "terminal_count":1,
      "status":"queued|running|completed|failed|waiting_for_legacy_drain|resolving",
      "request_digest":"<dispatcher I1 digest>",
      "created_at":"2026-07-11T00:00:00Z",
      "updated_at":"2026-07-11T00:01:00Z"
    }
  }
}
```

mirror 不含 `.iid/.iids/snapshot`。`matched_count=0` 在 receipt 时直接 `completed`；其他 batch
按 canonical event ledger 投影 `terminal_count/status`。新 mirror 必须保存完整 project、路由后的
executor agent 与 nonce SHA-256，不保存 nonce 明文。部署前旧 mirror 首次恢复时先原子增加
`callback_auth_mode=legacy_pre_upgrade,callback_nonce_sha256=null`；其 project 在可信兼容投影可得后补齐。

## `executor_batch_events.jsonl`

canonical I3 commit，每行增加 `received_at`：

```json
{"event_id":"reqd-batch-1:snapshot-0:terminal-1","batch_id":"reqd-batch-1","snapshot_index":0,"project":"group/project","iid":42,"status":"done","mr_url":null,"reason":null,"received_at":"2026-07-11T00:01:00Z"}
```

event ledger 先于 mirror/notification 投影发布。相同 event_id + 相同 public I3 是 duplicate；
不同内容冲突 fail closed。重复 event 不增加 terminal_count。

event ledger 永不保存 callback nonce。`nonce_v1` 事件只有在 handler 校验 nonce 摘要、project 和
executor agent 全部匹配 mirror 后才能提交；纯八字段 I3 只能提交到明确的
`legacy_pre_upgrade` mirror。

## `executor_batch_notifications.json`

普通 I3 notification：

```json
{
  "event_id":"reqd-batch-1:snapshot-0:terminal-1",
  "origin":null,
  "project":"group/project",
  "iid":42,
  "status":"done|failed|timeout|skipped",
  "mr_url":null,
  "reason":null,
  "attempts":0,
  "delivered_at":null,
  "next_attempt_at":null
}
```

zero-match notification：

```json
{
  "event_id":"reqd-batch-1:no-matches",
  "origin":null,
  "project":"group/project",
  "iid":null,
  "status":"no_matches",
  "mr_url":null,
  "reason":"无匹配 OPEN Issue",
  "attempts":0,
  "delivered_at":null,
  "next_attempt_at":null
}
```

每个 event 使用 `executor_batch_notification.<hash>.lock`，避免并发 drain 重复调用。
生产 `notify_user.sh` 在 event 专属
`executor_batch_notification_attempts/<hash>/` 中写 durable success/skipped outcome。若成功日志
已写但共享 notification 的 `delivered_at` 尚未提交就崩溃，下次 drain 先修复该投影，
`attempts` 不增加，也不再次调用 OpenClaw。

已送达热行在后续 drain 开始时写入 `delivered_notifications/<sha256(event_id)>.json` 并移出
热队列。重复 I3 投影会先核对该冷档；规范事件一致时不重建热通知，内部 event_id 或事件事实
冲突时失败关闭。`matched_count=0` 的 `no_matches` 重放使用同一冷档规则；即使 accepted intent
或 legacy bridge 在崩溃后残留，也不得重建已经送达的通知。

## `executor_queue.json`：仅旧 FIFO 排空

新请求不再写旧 FIFO。部署前遗留 active/queue 继续由 `drain_executor_queue.sh` 排空。
旧 I2 只兼容无 nonce、`launch_state` 缺省或为 `launched`、且 pending/active 身份完全一致的
部署前记录；`find_pending.sh` 在同一锁内把两侧显式标记为 `legacy_pre_upgrade`。后续
`drain_pending.sh` 与 `finish_executor_queue_active.sh` 分别重新校验该标记、身份以及已授权
drain ledger 证明。nonce_v1 或 `launching` 不能通过旧 I2 清理状态。
旧 active 的基础字段保持不变：

```json
{
  "queue_id":"execq-1",
  "project":"group/project",
  "iid":42,
  "executor_agent":"req_executor",
  "callback_nonce":"<升级后兼容 intent 的 64 lowercase hex；部署前旧项可缺失>",
  "origin":null,
  "correlation_id":"reqd-23",
  "run_id":"executor-execq-1",
  "launch_reclaim_seconds":7800,
  "stuck_after_minutes":150,
  "launch_state":"launching|launched|launch_failed"
}
```

`launch_reclaim_seconds` 与 `stuck_after_minutes` 在该 active 首次启动时按当时的 acpx
预算固化，后续 `/timeout-executor` 调低不追溯改写。部署前缺少这两个字段的 active 分别按旧值
`22200` 秒和 `390` 分钟兼容，避免滚动升级时把在途任务提前回收。

RUN_SINGLE_ISSUE single shim 返回 receipt 后，active 增加 bridge：

```json
{
  "driven_batch_id":"single-<sha256>",
  "driven_request_digest":"<sha256>",
  "driven_executor_agent":"req_executor",
  "driven_project":"group/project",
  "driven_callback_auth_mode":"nonce_v1|legacy_pre_upgrade",
  "driven_callback_nonce_sha256":"<sha256|null>",
  "driven_matched_count":1,
  "driven_snapshot_digest":"<digest>",
  "driven_scheduler_status":"queued|running|completed",
  "driven_receipt_at":"2026-07-11T00:00:00Z"
}
```

bridge 必须先于 mirror 发布。这样早到 I3 只会收到 unknown 并重投，不会出现 I3 已 ack 但
旧 active 无法清理。`recover_legacy_executor_batch_bridge.sh` 可从 bridge 修 mirror；mirror
completed 后幂等删除对应 pending、清 active，并写 `kind=legacy_batch_terminal` ledger 行。

`driven_matched_count=0` 不等 I3：创建 stable no-match notification 后立即清 active。下一条由
`run_executor_batch_tick.sh` 推进。

## `pending.json`

```json
{
  "pending":{
    "<run_id>":{
      "run_id":"<run_id>",
      "stage":"git_issuer|executor",
      "origin":null,
      "project":"group/project|null",
      "iid":42,
      "correlation_id":"reqd-23|null",
      "callback_auth_mode":"nonce_v1|legacy_pre_upgrade",
      "callback_nonce_sha256":"<sha256|null>",
      "child_session_key":null,
      "spawned_at":1719300000,
      "stuck_after_minutes":150,
      "req_digest":"string",
      "driven_batch_id":"single-<sha256>",
      "driven_matched_count":1,
      "driven_snapshot_digest":"<digest>"
    }
  }
}
```

`stuck_after_minutes` 在 pending 创建时固化；部署前缺少该字段的记录按旧值 `390` 兼容。
`driven_*` 仅旧 FIFO bridge 可选存在。pending 只保存 nonce 摘要，不保存明文；明文仍留在私有
old active intent。新 batch 不为每个 IID 创建 dispatcher pending。

## `ledger.jsonl`

既有 git_issuer/旧 I2 审计格式继续保留。legacy batch terminal 追加稳定证据：

```json
{"kind":"legacy_batch_terminal","run_id":"executor-execq-1","outcome":"success|failed","stage":"executor","project":"group/project","issue_iid":42,"status":"done|failed|timeout|skipped|no_matches","batch_id":"single-...","event_id":"single-...:snapshot-0:terminal-1","drained_at":1719300600,"was_pending":true}
```

ledger 是 append-only 审计，不作为 batch 调度 source。batch source 是 outbox receipt、mirror、
event ledger、notification queue 与旧 active bridge。
