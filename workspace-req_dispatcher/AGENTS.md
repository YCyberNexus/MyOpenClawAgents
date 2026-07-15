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
- `execute_issue`：只调 `submit_executor_batch.sh`；支持 single/iid_list/range/open_unfinished/open_label。
- `create_and_execute`：git_issuer 严格成功后，把返回 Issue URL 交同一个 batch wrapper。
- `clarify_or_reject`：不调用下游。
- `/slot <正整数>`：只调 `set_executor_slots.sh`，由它把命令发送到默认 executor 主 session；
  dispatcher 不直接修改调度状态。
- `/acpx-timeout <时长>`：只调 `set_executor_acpx_timeout.sh`，持久化后续
  attempt 的 acpx 超时，并让 dispatcher 后续从 scheduler state 派生外层预算；
  OpenClaw 全局 timeout 不变，在途任务使用已持久化的创建时预算，不受调低操作影响。
- I3：首行 `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY` 直接进入路径 D，只调
  `handle_executor_batch_event.sh`；新 batch/single 必须使用带 nonce 与 executor 身份的严格
  `callback_envelope`。旧 `RUN_DRIVEN_BATCH_RESULT` 首行继续兼容同一 handler。
- 周期恢复：只调 `run_executor_batch_tick.sh`。
- 旧 I2/FIFO：仅兼容部署前遗留 active/queue，排空后不再接收新项。

LLM 不得直接调用 `route_project.sh`、`build_executor_batch_payload.sh`、receipt/mirror/event/
notification 内部脚本，也不得手写 state。
slot 与 acpx timeout 调整只能调用各自的顶层 wrapper，不得编辑 executor
配置或 scheduler JSON。

调用 `submit_executor_batch.sh` 前必须先调 `get_executor_timeout_budget.sh`，OpenClaw exec
工具使用其 `exec_tool_timeout_seconds` 与 `yieldMs:120000`，不能在 shell 中套 `timeout`。
执行 submit 和周期 tick 的同一个 shell 还必须额外 source
`source_executor_timeout_budget.sh`；I3 callback 不得 source 它，以免 executor state 故障阻断 ack。
若工具转为后台 process，只能 poll 原 session；
被杀、断连或结果不明时停止，等待周期 tick 恢复已经持久化的同一 intent，不得读取 outbox 后
重新调用 submit wrapper，否则会错误分配第二个 batch。

路径 D 成功时，最终 assistant 内容必须逐字等于 `handle_executor_batch_event.sh` 的唯一 stdout
JSON；禁止添加任何前后缀、Markdown 代码块、解释、中文总结或其他对象。handler 非零时不得
伪造 ack。此规则同时适用于新旧 callback marker。
新 marker 的第三行必须精确为：
`ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。`。
该行是 transport 的强指令，不得忽略、改写或作为普通需求回复。不得把 callback 或 nonce
写入 `/tmp`、workspace 或其他临时文件；必须通过 stdin heredoc 原样传入：

```bash
cd "<SKILL_DIR 绝对路径>" && \
bash -c 'source scripts/source_dispatcher_env.sh; WORKER_RESULT_JSON="$(cat)" bash scripts/handle_executor_batch_event.sh' <<'CALLBACK_EOF'
<完整 callback marker 原文>
CALLBACK_EOF
```

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

每个新 I1 生成独立 64 字符小写 hex `callback_nonce`。明文只存在私有 outbox/old active intent
与发送中的 I1；compact mirror、single bridge/pending 只保存 SHA-256，并同时固定完整 project
与路由后的 executor agent。I3 apply 在落账前核对 nonce 摘要、project、executor；纯八字段 I3
只兼容明确标记 `legacy_pre_upgrade` 的部署前 mirror，新请求不得降级。

receipt immutable 字段为 `executor_agent,matched_count,snapshot_digest`；冲突 fail closed。
`scheduler_status` 可 `queued -> running -> completed`。

五类 selector 都只处理 batch intake 时为 OPEN 的 Issue；dispatcher 不查询或补入 CLOSED
Issue。`open_unfinished` 的终态标签排除、`open_label` 精确匹配及 `pr` 重跑覆盖均由 executor
按冻结 snapshot 与实时预检执行。

project locator 支持 `group/subgroup/.../project`；可信 GitLab 仓库根 URL 使用完整 path，带
`/-/` 的 URL 使用其前全部 path。Issue URL、仓库 URL、`projects/...` 与裸路径候选统一规范化去重，
出现多个不同 project 必须澄清。重跑动作词可位于 Issue 宾语之后，但“不要、无需、不需要、不得”等否定
窗口及 label/branch 值不能触发 `force_rerun_pr`。

## Legacy single shim bridge

旧 `RUN_SINGLE_ISSUE` 被 executor 转为 stable single batch。`drain_executor_queue.sh` 接收严格
五字段 public acceptance，把 `batch_id` 先写进 old active bridge，再创建 mirror。single 后续
只发认证 I3，不发旧 I2。升级后兼容 single intent 也携带 nonce；部署前无 nonce 的在途项会
显式标记为 `legacy_pre_upgrade`。

`recover_legacy_executor_batch_bridge.sh` 可从 bridge 修 mirror；single I3 或 zero-match 后清旧
pending/active，tick 推进下一项。bridge 与 mirror 的发布顺序禁止反转。

## State

`${STATE_ROOT}/_dispatcher/` 主要文件：

- `executor_batch_outbox.json`：durable I1 intent/receipt；
- `executor_batches.json`：compact mirror，无 IID snapshot；
- `executor_batch_events.jsonl`：canonical I3 ledger；
- `executor_batch_notifications.json`：逐项与 zero-match 通知 intent；
- `executor_batch_notification_attempts/`：event 专属 durable notify outcome；
- `executor_queue.json`、`pending.json`：旧 FIFO、git_issuer 与旧 I2 兼容；
- `ledger.jsonl`：append-only 审计。

完整 schema：[`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## Deployment Pin

蓝区默认值保持在 tracked config：`STATE_ROOT=/data/req_dispatcher`、默认 executor、route、
callback 与 gateway pin 契约。本机覆盖只能放 ignored `config/dispatcher.local.env` 或进程环境。
不得把 `/Users/...`、临时 session 或测试 endpoint 写入 tracked config。

`DISPATCHER_CALLBACK_TARGET` 必须非空，否则 batch wrapper 在 intent 前拒绝。部署周期唤醒使用
`RUN_EXECUTOR_BATCH_TICK`；旧 `RUN_EXECUTOR_QUEUE_DRAIN` 仅兼容同一 dispatcher wrapper。

## 本机验证

不在本机启动 agent。使用 `/opt/homebrew/bin/bash` 运行 shell 测试与 `bash -n`；本机
`/bin/bash` 版本过旧。禁止为本机测试改动 tracked 蓝区默认；使用 ignored 本地覆盖或进程环境。
