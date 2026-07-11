# State Schema

`req_dispatcher` 只保存控制面小状态，不保存 executor 的 IID snapshot、物理槽位、worktree、
campaign state、claim token 或 GitLab token。所有文件由 `env_paths.sh` 从 `STATE_ROOT` 派生，
并共用 `pending.lock`；网络调用永远在共享锁外。

四类 selector 的 snapshot 都由 executor 从 intake 时的 OPEN Issue 冻结；dispatcher state 不保存
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

每条新执行请求先写一条 token-free intent：

```json
{
  "version":1,
  "requests":[{
    "batch_id":"reqd-batch-1",
    "correlation_id":"reqd-1",
    "project":"group/project",
    "selector":{"type":"range","iid_min":1,"iid_max":3},
    "force_rerun_pr":false,
    "target_branch":null,
    "executor_agent":"req_executor",
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

同一 `batch_id` 只允许一个 request digest。receipt 重放固定校验
`executor_agent,matched_count,snapshot_digest`；冲突非零退出且不修改 state。
`scheduler_status` 只允许向前演进。

## `executor_batches.json`

Task 8 compact mirror：

```json
{
  "batches":{
    "reqd-batch-1":{
      "batch_id":"reqd-batch-1",
      "executor_agent":"req_executor",
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
按 canonical event ledger 投影 `terminal_count/status`。

## `executor_batch_events.jsonl`

canonical I3 commit，每行增加 `received_at`：

```json
{"event_id":"reqd-batch-1:snapshot-0:terminal-1","batch_id":"reqd-batch-1","snapshot_index":0,"project":"group/project","iid":42,"status":"done","mr_url":null,"reason":null,"received_at":"2026-07-11T00:01:00Z"}
```

event ledger 先于 mirror/notification 投影发布。相同 event_id + 相同 public I3 是 duplicate；
不同内容冲突 fail closed。重复 event 不增加 terminal_count。

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
  "delivered_at":null
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
  "delivered_at":null
}
```

每个 event 使用 `executor_batch_notification.<hash>.lock`，避免并发 drain 重复调用。
生产 `notify_user.sh` 在 event 专属
`executor_batch_notification_attempts/<hash>/` 中写 durable success/skipped outcome。若成功日志
已写但共享 notification 的 `delivered_at` 尚未提交就崩溃，下次 drain 先修复该投影，
`attempts` 不增加，也不再次调用 OpenClaw。

## `executor_queue.json`：仅旧 FIFO 排空

新请求不再写旧 FIFO。部署前遗留 active/queue 继续由 `drain_executor_queue.sh` 排空。
旧 active 的基础字段保持不变：

```json
{
  "queue_id":"execq-1",
  "project":"group/project",
  "iid":42,
  "executor_agent":"req_executor",
  "origin":null,
  "correlation_id":"reqd-23",
  "run_id":"executor-execq-1",
  "launch_state":"launching|launched|launch_failed"
}
```

RUN_SINGLE_ISSUE single shim 返回 receipt 后，active 增加 bridge：

```json
{
  "driven_batch_id":"single-<sha256>",
  "driven_request_digest":"<sha256>",
  "driven_executor_agent":"req_executor",
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
      "child_session_key":null,
      "spawned_at":1719300000,
      "req_digest":"string",
      "driven_batch_id":"single-<sha256>",
      "driven_matched_count":1,
      "driven_snapshot_digest":"<digest>"
    }
  }
}
```

`driven_*` 仅旧 FIFO bridge 可选存在。新 batch 不为每个 IID 创建 dispatcher pending。

## `ledger.jsonl`

既有 git_issuer/旧 I2 审计格式继续保留。legacy batch terminal 追加稳定证据：

```json
{"kind":"legacy_batch_terminal","run_id":"executor-execq-1","outcome":"success|failed","stage":"executor","project":"group/project","issue_iid":42,"status":"done|failed|timeout|skipped|no_matches","batch_id":"single-...","event_id":"single-...:snapshot-0:terminal-1","drained_at":1719300600,"was_pending":true}
```

ledger 是 append-only 审计，不作为 batch 调度 source。batch source 是 outbox receipt、mirror、
event ledger、notification queue 与旧 active bridge。
