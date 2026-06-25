# State Schema

`req_dispatcher` 的 state 极小：只有一张以 `run_id` 为主键的 pending 表，加一个 append-only 审计 ledger。**没有** campaign_state / worktree / glab / 标签机。所有路径由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生。

## 磁盘布局

```
${STATE_ROOT}/_dispatcher/
    pending.json        ← 唯一可变状态；flock(pending.lock) 保护
    ledger.jsonl        ← append-only 终态审计（每行一条 JSON）
    seq                 ← 可选单调递增序号（仅当启用 correlation_id 回显时用）
    pending.lock        ← flock 目标
    log/                ← 预留日志目录
```

## `pending.json`（主键 = `run_id`）

```json
{
  "pending": {
    "<run_id>": {
      "child_session_key": "string|null",
      "correlation_id": "string|null",
      "spawned_at": 1719300000,
      "req_digest": "string"
    }
  }
}
```

字段：

- **`run_id`**（对象 key）：跨 agent 异步 spawn `git_issuer` 返回的 runtime 运行标识。**回调路径以它为主匹配键**。
- `child_session_key`：spawn 返回的子 session key（兜底匹配用；无则 `null`）。
- `correlation_id`：可选回显 token；**默认不用**——仅当 §跨 agent 原语对齐后确认回调不携带 `run_id`、需靠 git_issuer 回显才能匹配时才填（见 `trigger_command.md`）。
- `spawned_at`：epoch 秒（`date -u +%s`）。stuck 兜底据此判超时。
- `req_digest`：需求文本前若干字摘要，仅供人读/审计，不参与逻辑。

初始内容（`ensure_state_dirs` 自动建）：`{"pending":{}}`。

## `ledger.jsonl`（append-only 终态审计）

每条 pending 走到终态（成功 / 失败 / launch 失败 / stuck 驱逐）时追加一行：

```json
{"run_id":"...","outcome":"success|failed|launch_failed|stuck_evicted","issue_iid":null,"issue_url":null,"reason":null,"drained_at":1719300600,"was_pending":true}
```

字段：

- `outcome`：终态枚举。`success`（git_issuer 建成 issue）/ `failed`（git_issuer 回调报失败）/ `launch_failed`（spawn 3 次重试仍失败，从未进 pending，`RUN_ID` 形如 `launch-fail-<epoch>`）/ `stuck_evicted`（超 `STUCK_AFTER_MINUTES` 没等到回调被兜底驱逐）。
- `issue_iid`：成功时由回调带回，写入时 `tonumber` 规整为数字（git_issuer IID 是正整数、无前导零，故安全）；非数字串则原样保留为字符串；否则 `null`。
- `issue_url`：成功时由回调带回；否则 `null`。
- `reason`：失败/驱逐原因；成功时 `null`。
- `drained_at`：epoch 秒。
- `was_pending`：drain 时该 `run_id` 是否还在 pending（用于发现重复回调 / 已被驱逐后又到的迟到回调；`launch_failed` 永远 `false`）。

**at-least-once 语义（重要）**：ledger 是 append-only 审计，**可能为同一 `run_id` 出现多条终态行**——成因：(a) 迟到/重复回调（每次都照常写一行，`was_pending=false`）；(b) 写 ledger 与删 pending 之间的崩溃窗口（ledger 已写、pending 未删，下一轮 `evict_stuck` 会再为同一 `run_id` 写一条 `stuck_evicted`）。消费方读 ledger 时须以 `run_id` 去重（按需取最早或最末一条）。`evict_stuck` 内部"写 ledger 的集合"与"从 pending 删除的集合"严格同一（按已确定的 key 精确删除），不会一轮内自相矛盾。

ledger 仅审计，不被读回做决策（不是 source of truth，也无 source of truth——本 agent 不维护跨 tick 业务状态）。
