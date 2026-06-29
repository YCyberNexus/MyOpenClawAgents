# State Schema

`req_dispatcher` 的 state 极小：只有一张以 `run_id` 为主键的 pending 表，加一个 append-only 审计 ledger。**没有** campaign_state / worktree / glab / 标签机。所有路径由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生。

编排器对一条需求做**两段异步 spawn**：先 `git_issuer` 段（建 issue），其回调成功后再起 `executor` 段（驱动 `req_executor` 单次 issue 执行）。每段各记一条 pending（各自 `run_id`），由 `stage` 字段区分；两段不强制重叠（git_issuer 段 drain 后再起 executor 段）。

## 磁盘布局

```
${STATE_ROOT}/_dispatcher/
    pending.json        ← 唯一可变状态；flock(pending.lock) 保护
    ledger.jsonl        ← append-only 终态审计（每行一条 JSON）
    seq                 ← 可选单调递增序号（仅当启用 correlation_id 回显时用）
    pending.lock        ← flock 目标
    log/                ← best-effort 通知留痕（notify_user / ops_notify 等）
```

## `pending.json`（主键 = `run_id`，I3 契约）

```json
{
  "pending": {
    "<run_id>": {
      "run_id": "<run_id>",
      "stage": "git_issuer|executor",
      "origin": { "channel": "..", "user": "..", "conversation": ".." },
      "project": "string|null",
      "iid": 0,
      "correlation_id": "string|null",
      "child_session_key": "string|null",
      "spawned_at": 1719300000,
      "req_digest": "string"
    }
  }
}
```

> 与跨 agent spawn/回调对齐项配套——此 entry 形状即设计稿 §4.6 / 计划 I3，两侧（编排器内的两段）逐字一致。`iid` 在没有时为 `null`，executor 段有时为正整数。

字段：

- **`run_id`**（对象 key，且冗余进 value 便于 `to_entries` 后直接取）：跨 agent 异步 spawn 下游 agent 返回的 runtime 运行标识。**回调路径以它为主匹配键**。
- `stage`：`git_issuer`（接入路径 spawn git_issuer 后记）或 `executor`（git_issuer 回调成功后 spawn req_executor 单次 issue 执行时记）。`record_pending.sh` 必填校验，仅接受这两个值。
- `origin`：发起人元数据 `{channel,user,conversation}`，由接入路径从需求文本约定行 capture，**全程随两段 pending 携带**，executor 回调时取出用于把结果推回用户。`record_pending.sh` 经 `--argjson` 注入（`ORIGIN_JSON` 入参），缺省 `null`。
- `project`：GitLab project slug。git_issuer 段一般为 `null`；executor 段由 git_issuer 回调透传后携带。缺省 `null`。
- `iid`：要测的 issue IID（正整数）。git_issuer 段一般为 `null`；executor 段携带。`record_pending.sh` 给定时做正整数校验，写入为数字。
- `correlation_id`：req_dispatcher 在 spawn executor 时生成的关联 token，随 `RUN_SINGLE_ISSUE` 入参下发、由执行器原样回显在结果回调里——**作 executor 回调的二次校验**（防 run_id 错配）；主匹配仍按 `run_id`。git_issuer 段一般为 `null`。
- `child_session_key`：spawn 返回的子 session key（兜底匹配用；无则 `null`）。
- `spawned_at`：epoch 秒（`date -u +%s`）。stuck 兜底据此判超时（覆盖两 stage）。
- `req_digest`：需求文本前若干字摘要，仅供人读/审计，不参与逻辑。

初始内容（`ensure_state_dirs` 自动建）：`{"pending":{}}`。

## `ledger.jsonl`（append-only 终态审计）

每条 pending 走到终态（成功 / 失败 / launch 失败 / stuck 驱逐）时追加一行：

```json
{"run_id":"...","outcome":"success|failed|launch_failed|stuck_evicted","stage":"git_issuer|executor|null","project":"..|null","issue_iid":null,"issue_url":null,"status":"done|failed|timeout|null","mr_url":"..|null","reason":null,"drained_at":1719300600,"was_pending":true}
```

字段：

- `outcome`：终态枚举。`success`（git_issuer 建成 issue / executor 段成功收尾）/ `failed`（下游回调报失败）/ `launch_failed`（spawn 3 次重试仍失败，从未进 pending，`RUN_ID` 形如 `launch-fail-<epoch>`）/ `stuck_evicted`（超 `STUCK_AFTER_MINUTES` 没等到回调被兜底驱逐）。
- `stage`：该终态属哪段（`git_issuer`/`executor`）。drain 由 `STAGE` 入参写；`stuck_evicted` 由 `evict_stuck.sh` 从对应 pending entry 的 `.value.stage` 读出。未给定则 `null`（如旧 launch_failed 不带 stage）。
- `project`：drain 时由 `PROJECT` 入参写（executor 段沿用透传值）；缺省 `null`。
- `issue_iid`：成功时由回调带回（drain 的 `IID`/旧 `ISSUE_IID` 入参），写入时 `tonumber` 规整为数字（IID 是正整数、无前导零，故安全）；非数字串则原样保留为字符串；否则 `null`。
- `issue_url`：成功时由回调带回；否则 `null`。
- `status`：executor 回调终态（`done`/`failed`/`timeout`，源自执行器 `final_status`），drain 由 `STATUS` 入参写并做枚举校验；git_issuer 段终态此项 `null`。
- `mr_url`：executor `done` 时回调带回的 MR 链接，drain 由 `MR_URL` 入参写；否则 `null`。
- `reason`：失败/驱逐原因；成功时 `null`。
- `drained_at`：epoch 秒。
- `was_pending`：drain 时该 `run_id` 是否还在 pending（用于发现重复回调 / 已被驱逐后又到的迟到回调；`launch_failed` 永远 `false`）。

**at-least-once 语义（重要）**：ledger 是 append-only 审计，**可能为同一 `run_id` 出现多条终态行**——成因：(a) 迟到/重复回调（每次都照常写一行，`was_pending=false`）；(b) 写 ledger 与删 pending 之间的崩溃窗口（ledger 已写、pending 未删，下一轮 `evict_stuck` 会再为同一 `run_id` 写一条 `stuck_evicted`）。消费方读 ledger 时须以 `run_id` 去重（按需取最早或最末一条）。`evict_stuck` 内部"写 ledger 的集合"与"从 pending 删除的集合"严格同一（按已确定的 key 精确删除），不会一轮内自相矛盾。

ledger 仅审计，不被读回做决策（不是 source of truth，也无 source of truth——本 agent 不维护跨 tick 业务状态）。
