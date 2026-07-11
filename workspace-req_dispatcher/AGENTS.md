# req_dispatcher Workspace Notes

本目录是 `req_dispatcher` OpenClaw 部署工件，不是业务应用。它在蓝区 104 作为
WebUI/智伴 prompt 的动作路由器和受驱动 batch 控制面。

## Agent Identity

- Agent：`req_dispatcher`
- 固定 session：`agent:req_dispatcher:main`
- 建单下游：`git_issuer`
- 执行下游：按 `route_project.sh` 选择的 req_executor，默认
  `DEFAULT_EXECUTOR_AGENT=req_executor`
- 唯一 SKILL：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)

dispatcher 不建 Issue、不写 GitLab、不跑 Issue。wiki 读取是唯一允许的 GitLab 访问，且只
能通过 `prepare_wiki_downstream_payloads.sh` 使用 `WIKI_GITLAB_*` 只读 pin。

## Execution Model

- `create_issue`：既有 wiki/free-text prepare wrapper -> git_issuer -> 同轮审计，成功后停止。
- `execute_issue`：只调 `submit_executor_batch.sh`；支持 single/range/open_unfinished/open_label。
- `create_and_execute`：git_issuer 严格成功后，把返回 Issue URL 交同一个 batch wrapper。
- `clarify_or_reject`：不调用下游。
- I3：只调 `handle_executor_batch_event.sh`，返回唯一 accepted/duplicate ack。
- 周期恢复：只调 `run_executor_batch_tick.sh`。
- 旧 I2/FIFO：仅兼容部署前遗留 active/queue，排空后不再接收新项。

LLM 不得直接调用 `route_project.sh`、`build_executor_batch_payload.sh`、receipt/mirror/event/
notification 内部脚本，也不得手写 state。

## Durable batch contract

新执行 wrapper 内部固定：

```text
prepare_executor_issue_payload.sh
  -> route_project.sh
  -> build_executor_batch_payload.sh
  -> enqueue_executor_batch_request.sh
  -> drain_executor_batch_outbox.sh
```

I1 在网络调用前持久化。旧 FIFO 非空时为 `waiting_for_legacy_drain` 且不发送。ack 不明时
同 batch/correlation/payload 重投。严格 receipt 先写 `received`，再修 Task 8 mirror，最后
`accepted`。

receipt immutable 字段为 `executor_agent,matched_count,snapshot_digest`；冲突 fail closed。
`scheduler_status` 可 `queued -> running -> completed`。

四类 selector 都只处理 batch intake 时为 OPEN 的 Issue；dispatcher 不查询或补入 CLOSED
Issue。`open_unfinished` 的终态标签排除、`open_label` 精确匹配及 `pr` 重跑覆盖均由 executor
按冻结 snapshot 与实时预检执行。

## Legacy single shim bridge

旧 `RUN_SINGLE_ISSUE` 被 executor 转为 stable single batch。`drain_executor_queue.sh` 接收严格
五字段 public acceptance，把 `batch_id` 先写进 old active bridge，再创建 mirror。single 后续
只发 I3，不发旧 I2。

`recover_legacy_executor_batch_bridge.sh` 可从 bridge 修 mirror；single I3 或 zero-match 后清旧
pending/active，tick 推进下一项。bridge 与 mirror 的发布顺序禁止反转。

## State

`${STATE_ROOT}/_dispatcher/` 主要文件：

- `executor_batch_outbox.json`：token-free I1 intent/receipt；
- `executor_batches.json`：compact mirror，无 IID snapshot；
- `executor_batch_events.jsonl`：canonical I3 ledger；
- `executor_batch_notifications.json`：逐项与 zero-match 通知 intent；
- `executor_batch_notification_attempts/`：event 专属 durable notify outcome；
- `executor_queue.json`、`pending.json`：旧 FIFO、git_issuer 与旧 I2 兼容；
- `ledger.jsonl`：append-only 审计。

完整 schema：[`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## Token boundary

dispatcher batch state/payload 不得出现 GitLab token。req_executor I1、旧 single I1 与 batch
notification 外部进程调用前显式 scrub token；不得把 scrub 扩展到 git_issuer/wiki 的既有本地
调用环境。

## Deployment Pin

蓝区默认值保持在 tracked config：`STATE_ROOT=/data/req_dispatcher`、默认 executor、route、
callback 与 gateway pin 契约。本机覆盖只能放 ignored `config/dispatcher.local.env` 或进程环境。
不得把 `/Users/...`、临时 session、测试 endpoint/token 写入 tracked config。

`DISPATCHER_CALLBACK_TARGET` 必须非空，否则 batch wrapper 在 intent 前拒绝。部署周期唤醒使用
`RUN_EXECUTOR_BATCH_TICK`；旧 `RUN_EXECUTOR_QUEUE_DRAIN` 仅兼容同一 dispatcher wrapper。

## 本机验证

不在本机启动 agent。使用 `/opt/homebrew/bin/bash` 运行 shell 测试与 `bash -n`；本机
`/bin/bash` 版本过旧。禁止用本机 GitLab token 或路径改 tracked 蓝区默认。
