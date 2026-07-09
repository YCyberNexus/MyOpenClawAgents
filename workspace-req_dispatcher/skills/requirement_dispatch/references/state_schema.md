# State Schema

`req_dispatcher` 的 state 极小：一张以 `run_id` 为主键的 pending 表、一个 durable executor FIFO queue、一个 append-only 审计 ledger。**没有** campaign_state / worktree / glab / 标签机。所有路径由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生。

编排器先按 prompt 判定 action：`create_issue` 只进入 `git_issuer` 段并同轮审计 record/drain；`execute_issue` 直接把既有 issue 追加到 durable executor FIFO queue；`create_and_execute` 先 `git_issuer` 建单，成功后才入 executor queue。`drain_executor_queue.sh` 是唯一启动 `executor` 段（驱动 `req_executor` 单次 issue 执行）的脚本。`git_issuer` 段用 `run_agent_turn.sh` envelope 的 `run_id` 做同轮审计 record/drain；`executor` 段由 queue active 生成稳定 `run_id` / `correlation_id`，启动成功后进入 pending，等待后续 I2 结果回调。

## 磁盘布局

```
${STATE_ROOT}/_dispatcher/
    pending.json        ← 下游结果 pending 表；flock(pending.lock) 保护
    executor_queue.json ← executor durable FIFO；同一 pending.lock 保护
    ledger.jsonl        ← append-only 终态审计（每行一条 JSON）
    seq                 ← correlation_id 单调递增序号
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
      "origin": { "channel": "..", "user": "..", "conversation": "..", "reply_agent": ".." },
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

> 与 `run_agent_turn.sh` envelope 和 executor I2 回调配套。`iid` 在没有时为 `null`，executor 段有时为正整数。

字段：

- **`run_id`**（对象 key，且冗余进 value 便于 `to_entries` 后直接取）：`run_agent_turn.sh` envelope 里的运行审计标识。executor 回调路径优先以它为主匹配键；回调缺 run_id 时按 `correlation_id` 反查。
- `stage`：`git_issuer`（接入路径调用 git_issuer 后同轮审计）或 `executor`（调用 req_executor 单次 issue 执行后记 pending）。`record_pending.sh` 必填校验，仅接受这两个值。
- `origin`：发起人元数据 `{channel,user,conversation,reply_agent}`，由接入路径通过 `capture_origin.sh` capture：优先读取 OpenClaw 网关/运行时来源元数据，其次才读需求文本里的显式 `[origin]` 行。该字段**全程随两段 pending 携带**，executor 回调时取出用于把结果推回用户。`reply_agent` 是 114 上接收终态结果的 agent 名；`notify_user.sh` 优先使用它，缺省才用默认 `DEFAULT_REPLY_AGENT`。`record_pending.sh` 经 `--argjson` 注入（`ORIGIN_JSON` 入参），缺省 `null`。
- `project`：GitLab `group/project`。git_issuer 段一般为 `null`；executor 段由 git_issuer JSON 透传后携带。缺省 `null`。
- `iid`：要测的 issue IID（正整数）。git_issuer 段一般为 `null`；executor 段携带。`record_pending.sh` 给定时做正整数校验，写入为数字。
- `correlation_id`：req_dispatcher 在调用 executor 时生成的关联 token，随 `RUN_SINGLE_ISSUE` 入参下发、由执行器原样回显在结果回调里——**作 executor 回调的二次校验**（防 run_id 错配）；主匹配仍按 `run_id`，回调缺 run_id 时也用它反查 pending。git_issuer 段一般为 `null`。
- `child_session_key`：`run_agent_turn.sh` 调用目标 agent 时使用的 session selector（字段名沿用历史命名，仅审计用；无则 `null`）。
- `spawned_at`：epoch 秒（`date -u +%s`）。stuck 兜底据此判超时（覆盖两 stage）。
- `req_digest`：需求文本前若干字摘要，仅供人读/审计，不参与逻辑。

初始内容（`ensure_state_dirs` 自动建）：`{"pending":{}}`。

## `executor_queue.json`（executor durable FIFO）

```json
{
  "next_id": 1,
  "active": {
    "queue_id": "execq-1",
    "project": "group/project",
    "iid": 12,
    "issue_url": "http://gitlab/issues/12",
    "executor_agent": "req_executor",
    "target_branch": "release/2026.07",
    "origin": { "channel": "..", "user": "..", "conversation": "..", "reply_agent": ".." },
    "req_digest": "string",
    "queued_at": 1719300000,
    "correlation_id": "reqd-23",
    "run_id": "executor-execq-1",
    "launch_state": "launching|launched|launch_failed",
    "launch_attempts": 1,
    "launch_started_at": 1719300060,
    "launched_at": null,
    "next_retry_after": null,
    "launch_error": null,
    "child_session_key": null
  },
  "queue": []
}
```

初始内容（`ensure_state_dirs` 自动建）：`{"next_id":1,"active":null,"queue":[]}`。

职责边界：

- `enqueue_executor_issue.sh` 只把用户明确要求执行的 issue 追加到 `.queue` 队尾，并生成单调 `queue_id`。来源可以是 `prepare_executor_issue_payload.sh` 解析出的既有 issue，也可以是 `create_and_execute` 中 `git_issuer` 已创建成功的 issue。
- `drain_executor_queue.sh` 是唯一允许把 `.queue[0]` 移入 `.active` 并启动 executor 的入口。它在认领 active 时同步预写同 `run_id` 的 executor pending 占位，避免 executor 很快回调时找不到 pending；启动失败会删除该占位，启动成功会补 `child_session_key` 并把 active 标为 `launched`。
- `finish_executor_queue_active.sh` 只在 executor I2 回调的 `correlation_id` 匹配当前 `.active` 时清空 active；随后必须再次调用 `drain_executor_queue.sh` 继续推进队首。
- `evict_stuck.sh` 驱逐 executor pending 时，如果该 pending 的 `run_id` 或 `correlation_id` 匹配当前 `.active`，会同步清空 active；后续 queue drain 可继续启动下一条。
- `.active.launch_state="launching"` 表示已经从队列认领、正在启动 executor。若该状态超过 `EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS`，下一次 drain 会复用同一个 `run_id` / `correlation_id` 重新启动，恢复 OpenClaw 会话被用户或运行时中断的场景；部署默认应覆盖 `EXECUTOR_AGENT_TIMEOUT_SECONDS` 再留余量，避免正常长 executor turn 尚未返回时重复启动。
- executor 启动成功必须同时满足外层 `run_agent_turn.sh` envelope `status="success"`，以及 executor `worker_result_json.status="waiting_for_callbacks"` 或 raw output 含 `waiting_for_callbacks`。其他状态会删除 pending 占位，并保留 active 为 `launch_failed` 等后续 drain 重试。
- 如果 executor 在初始 turn 返回前已经完成并回调，回调会 drain pending 并清 active；此时 `drain_executor_queue.sh` 返回 `active_changed_after_launch`，不再补写已完成 issue 的旧 pending。
- `.active.launch_state="launched"` 表示 executor 已经启动且 pending 已记录；此时 queue drain 返回 `busy`，直到 I2 回调清空 active。
- `.active.launch_state="launch_failed"` 表示本轮 drain 对同一个 payload 的启动尝试已耗尽；active 不丢弃，`next_retry_after` 到期后的下一次 drain 会继续重试。

字段：

- `next_id`：下一条入队 issue 的数字序号。`queue_id` 形如 `execq-N`。
- `active`：当前正在启动或等待回调的 executor issue。为 `null` 时可启动队首。
- `queue`：等待执行的 FIFO 列表。只有明确执行动作才追加队尾，不抢占 active。
- `project` / `iid` / `issue_url`：要执行的 issue 事实；既有 issue 执行来自 `prepare_executor_issue_payload.sh`，显式建单并执行来自 `git_issuer` 成功返回。
- `executor_agent`：`route_project.sh` 选出的目标 executor agent。
- `target_branch`：入口消息明确指定的本次执行分支；未指定时为 `null`，executor 继续用 `origin/HEAD` 兜底。下发给 executor 后，executor 基于该分支 checkout，MR/PR 目标也指向该分支。
- `origin` / `req_digest` / `queued_at`：从接入路径携带的回推与审计信息。
- `correlation_id`：下发给 executor 并由 I2 回显的关联 token，用于回调二次校验和 active 清理。
- `run_id`：queue 生成的稳定 executor run id，形如 `executor-execq-N`。同一个 active 重试必须复用该值，避免重复 pending key。
- `launch_state` / `launch_attempts` / `launch_started_at` / `launched_at` / `next_retry_after` / `launch_error`：启动状态机与恢复信息。
- `child_session_key`：executor 启动成功后由 `run_agent_turn.sh` envelope 返回，仅审计用。

`executor_queue.json` 是“还有哪些 issue 必须继续执行”的 durable source；`pending.json` 是“哪些下游调用正在等待终态回调”的 pending source。ledger 仍只做 append-only 审计，不参与调度决策。

## `ledger.jsonl`（append-only 终态审计）

每条 pending 走到终态（成功 / 失败 / launch 失败 / stuck 驱逐）时追加一行：

```json
{"run_id":"...","outcome":"success|failed|launch_failed|stuck_evicted","stage":"git_issuer|executor|null","project":"..|null","issue_iid":null,"issue_url":null,"status":"done|failed|timeout|null","mr_url":"..|null","reason":null,"drained_at":1719300600,"was_pending":true}
```

字段：

- `outcome`：终态枚举。`success`（git_issuer 建成 issue / executor 段成功收尾）/ `failed`（下游业务结果失败）/ `launch_failed`（`run_agent_turn.sh` 三次重试仍失败，从未进 pending 或只写审计，`RUN_ID` 取最后一次 envelope.run_id）/ `stuck_evicted`（executor pending 超 `STUCK_AFTER_MINUTES` 没等到回调被兜底驱逐）。
- `stage`：该终态属哪段（`git_issuer`/`executor`）。drain 由 `STAGE` 入参写；`stuck_evicted` 由 `evict_stuck.sh` 从对应 pending entry 的 `.value.stage` 读出。未给定则 `null`（如旧 launch_failed 不带 stage）。
- `project`：drain 时由 `PROJECT` 入参写（executor 段沿用透传值）；缺省 `null`。
- `issue_iid`：成功时由 git_issuer JSON 或 executor I2 带回（drain 的 `IID`/旧 `ISSUE_IID` 入参），写入时 `tonumber` 规整为数字（IID 是正整数、无前导零，故安全）；非数字串则原样保留为字符串；否则 `null`。
- `issue_url`：git_issuer 成功时由其 JSON 带回；否则 `null`。
- `status`：executor 回调终态（`done`/`failed`/`timeout`，源自执行器 `final_status`），drain 由 `STATUS` 入参写并做枚举校验；git_issuer 段终态此项 `null`。
- `mr_url`：executor `done` 时回调带回的 MR 链接，drain 由 `MR_URL` 入参写；否则 `null`。
- `reason`：失败/驱逐原因；成功时 `null`。
- `drained_at`：epoch 秒。
- `was_pending`：drain 时该 `run_id` 是否还在 pending（用于发现重复回调 / 已被驱逐后又到的迟到回调；`launch_failed` 永远 `false`）。

**at-least-once 语义（重要）**：ledger 是 append-only 审计，**可能为同一 `run_id` 出现多条终态行**——成因：(a) 迟到/重复回调（每次都照常写一行，`was_pending=false`）；(b) 写 ledger 与删 pending 之间的崩溃窗口（ledger 已写、pending 未删，下一轮 `evict_stuck` 会再为同一 `run_id` 写一条 `stuck_evicted`）。消费方读 ledger 时须以 `run_id` 去重（按需取最早或最末一条）。`evict_stuck` 内部"写 ledger 的集合"与"从 pending 删除的集合"严格同一（按已确定的 key 精确删除），不会一轮内自相矛盾。

ledger 仅审计，不被读回做决策（不是 source of truth，也无 source of truth——本 agent 不维护跨 tick 业务状态）。
