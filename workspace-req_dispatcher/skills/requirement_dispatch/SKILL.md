---
name: requirement_dispatch
description: "[SKILL_VERSION=2026-07-14.6] 在 104 侧把 WebUI/智伴需求路由到固定的建单、受驱动批次执行、运行时 /slot 控制、恢复 tick 或结果回调 wrapper。执行请求支持单 IID、离散 IID 列表、IID 闭区间、OPEN 未完成 Issue 与 OPEN 指定标签 Issue；dispatcher 只持久化 durable I1 intent、紧凑批次镜像与通知待办，不查询 GitLab、不展开 IID 快照、不手写调度状态。"
allowed-tools: Bash, Read
---

# Requirement Dispatch Skill

`req_dispatcher` 是 prompt 路由器和薄控制器。LLM 只判断动作、调用本文件列出的固定
wrapper，并读取严格 JSON 分支；所有解析、路由、ID、持久状态、重投、去重和通知推进都由
脚本完成。

## 硬边界

- dispatcher 不建 Issue、不改 label/note、不执行 Issue，也不调用 GitLab Issue API。
- `WIKI_GITLAB_*` 只允许 `prepare_wiki_downstream_payloads.sh` 读取 wiki；该访问不得用于建
  Issue、修改 label/note 或 executor 操作。
- 不得自行查询 GitLab、分页、展开 IID、拼 100+ 个 `RUN_SINGLE_ISSUE`，也不得写
  `executor_batch_outbox.json`、mirror、event ledger、notification queue 或旧 FIFO。
- 五类 selector 都只处理 batch intake 时为 OPEN 的 Issue；OPEN snapshot 的查询、过滤与冻结
  全部由 executor 完成，dispatcher 不补查 CLOSED Issue。
- 新执行请求只能调用 `submit_executor_batch.sh`。不得把
  `prepare_executor_issue_payload.sh -> route_project.sh -> build_executor_batch_payload.sh`
  拆成 LLM 步骤；这条链只在 wrapper 内部运行。
- 周期恢复只能调用 `run_executor_batch_tick.sh`。认证的
  `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY` transport、兼容的旧
  `RUN_DRIVEN_BATCH_RESULT` transport，或仅供明确 `legacy_pre_upgrade` mirror 使用的纯 I3，
  都只能调用 `handle_executor_batch_event.sh`，并把其唯一 stdout JSON 原样作为 ack。
- `DISPATCHER_CALLBACK_TARGET` 为空时必须拒绝，不能分配 batch、落 intent 或触达 executor。
- 下游或本地脚本非零时按 No-Fallback 停止；不得内联重写脚本逻辑或手改 state。

## 路径判定

固定 session 为 `agent:req_dispatcher:main`。每次唤醒只选一条：

1. 首行是精确 `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY`：路径 D；不得进入自然语言动作判定。
2. 首行是兼容的精确 `RUN_DRIVEN_BATCH_RESULT`：路径 D。
3. 收到严格三字段兼容 `callback_envelope`，或带严格 `batch_acceptance` 的四字段对象：路径 D。
4. 收到兼容的纯 I3 JSON，且目标 mirror 明确标记 `legacy_pre_upgrade`：路径 D。
5. 收到旧 `RUN_EXECUTOR_RESULT_CALLBACK` I2：路径 B，兼容升级前 FIFO。
6. 收到 `RUN_EXECUTOR_BATCH_TICK` 或旧 `RUN_EXECUTOR_QUEUE_DRAIN`：路径 C。
7. 首行以 `/slot` 开始：路径 E；由固定 wrapper 校验完整消息。
8. 其余自然语言需求：路径 A。

禁止把任一 `RUN_DRIVEN_BATCH_RESULT*` callback marker 当自然语言或 I2，也禁止在一个回调
turn 中自行执行多个分支。

## 路径 E：运行时 slot 配置

收到 `/slot <正整数>` 时，只调用：

```bash
cd "<SKILL_DIR 绝对路径>" && \
source scripts/source_dispatcher_env.sh && \
MESSAGE="<完整原文>" bash scripts/set_executor_slots.sh
```

wrapper 会严格校验命令，只把规范化后的 `/slot N` 发送到
`agent:${DEFAULT_EXECUTOR_AGENT}:main`，并只接受 executor 固定 wrapper 返回的严格 JSON。
`status=success` 时按 `slot_count,previous_slot_count,active_count,available_slots,draining`
回复用户；`draining=true` 表示在线缩容后已有任务数暂时高于新上限，任务不会被取消，但不会
继续发放新物理槽位。`status=failed` 时读取 `reason` 后停止，不得改写 executor 配置或调度状态。

## 路径 A：需求接入

### 1. 捕获 origin

接入原文只交给固定脚本。origin 优先来自 OpenClaw 运行时元数据，正文 `[origin]` 仅作
兼容 fallback；拿不到时为 `null`，不阻断执行。

```bash
cd "<SKILL_DIR 绝对路径>" && \
MESSAGE="<需求原文>" bash scripts/capture_origin.sh
```

### 2. 只判一个动作

- `create_issue`：只分析、拆分、创建或变更 Issue，不要求执行。
- `execute_issue`：处理既有单 Issue、离散 IID 列表、IID 范围、OPEN 未完成 Issue 或 OPEN 指定标签 Issue。
- `create_and_execute`：明确要求先建单再执行。
- `clarify_or_reject`：无法确定 project，或执行选择器不完整。

project 必须来自显式多段 namespace path（例如 `group/subgroup/project`）、可信 GitLab
repository/wiki/Issue URL 或既有确定性 locator；仓库根 URL 保留完整 path，带 `/-/` 的 URL
保留其前全部 path。Issue URL、普通仓库 URL、`projects/...` 与裸路径产生的候选必须统一解码、
规范化和去重；出现多个不同 project 时必须澄清，不得静默选任一来源，也不得把 label/branch 值
当 project。

五类 selector 都只纳入创建 snapshot 时为 OPEN 的 Issue。`iid_list` 表示同一 project 下排序、
去重后的至少两个离散 IID；`open_unfinished` 排除
`pr,timeout,blocked,blocked-*,failed,failed-*`；`open_label` 只按标签精确匹配，不追加这些
排除条件。普通处理实时遇到 `pr` 会跳过，只有原文明确要求重跑/重新处理/重新执行时才设置
`force_rerun_pr=true`；动作词可以位于宾语之后，但同分句否定窗口中的“不要、无需、不需要、
不得”等必须保持 false，label/branch 值中的动作词不算动作。CLOSED 始终不处理。

### 3. 建单动作

`create_issue` 与 `create_and_execute` 的建单半段保持既有固定链：

- wiki：`prepare_wiki_downstream_payloads.sh`；
- 自由文本：`prepare_downstream_payloads.sh`；
- 逐条调用 `run_agent_turn.sh` 发给 `${GIT_ISSUER_AGENT}`；
- 严格读取 git_issuer JSON，并用 `record_pending.sh` / `drain_pending.sh` 完成审计。

`create_issue` 成功即停止，绝不进入执行。`create_and_execute` 只在 git_issuer 返回严格
`status=success,project,issue_iid,issue_url` 后，把返回的 `issue_url` 与原始分支指令交给下面
的单一执行 wrapper；不得回到旧 `enqueue_executor_issue.sh`。

### 4. 执行动作只调用一个 wrapper

自然语言请求：

```bash
cd "<SKILL_DIR 绝对路径>" && \
source scripts/source_dispatcher_env.sh && \
MESSAGE="<包含明确 project 与 selector 的原文>" \
ORIGIN_JSON='<capture_origin 输出；无则 null>' \
bash scripts/submit_executor_batch.sh
```

这次 Bash/exec tool call 必须显式使用 `timeout:10800` 与 `yieldMs:120000`；这里的
`timeout` 是 OpenClaw `exec` 工具字段，不得在 shell 命令前加 `timeout 120` 等外层截断。
`submit_executor_batch.sh` 会同步等待 executor，短工具超时可能在 I1 已持久化、executor 已
受理后杀死调用方。若 exec 返回 process session，只能继续 poll **同一个** session 直到退出；
`SIGKILL`、overall timeout、连接中断或结果不明确时立即停止，留给周期 tick 重投原 durable
intent。禁止再次调用 `submit_executor_batch.sh`，否则会分配第二个 batch ID。

若上一步已经调用 `prepare_executor_issue_payload.sh`，只允许把它的**原样 stdout**作为
`PREPARED_REQUEST_JSON` 交给同一 wrapper；不得手写或增删字段：

```bash
cd "<SKILL_DIR 绝对路径>" && \
source scripts/source_dispatcher_env.sh && \
PREPARED_REQUEST_JSON='<prepare_executor_issue_payload.sh 原样 stdout>' \
ORIGIN_JSON='<capture_origin 输出；无则 null>' \
bash scripts/submit_executor_batch.sh
```

wrapper 内部固定执行：

```text
prepare_executor_issue_payload.sh
  -> route_project.sh
  -> build_executor_batch_payload.sh
  -> enqueue_executor_batch_request.sh
  -> drain_executor_batch_outbox.sh
```

`enqueue_executor_batch_request.sh` 必须先持久化完整 I1 payload，之后才允许
网络调用。batch 使用稳定 `batch_id/correlation_id`；发送成功但 ack 丢失、进程崩溃或 mirror
未完成时，后续 tick 以同一 payload 重投或从 durable receipt 修复，绝不生成新 ID 冒充原批次。
每个新 intent 同时生成 64 字符小写 hex `callback_nonce`；明文仅在私有 outbox/I1 中，mirror
只保存 SHA-256，并固定保存完整 project 与路由后的 executor agent。

只读以下严格分支：

- `status=failed`：入口或 route 被拒绝；读取 `reason`，通知或回复后停止。
- `status=waiting_for_legacy_drain`：旧 FIFO 的 active/queue 非空；intent 已持久化，未发送 I1。
- `status=retryable_failure`：调用失败或 ack 不明确；intent 仍在 outbox，等待 tick 同 ID 重投。
- `status=accepted`：严格含
  `batch_id,correlation_id,matched_count,snapshot_digest,scheduler_status`；mirror 已可接 I3。

`BATCH_ID` 定向 drain 若撞上并发投递锁，必须从 durable outbox 返回
`retryable_failure/reason=delivery_in_progress`；若该行已为 `accepted`，必须直接重建同一 compact
acceptance（`record_status=duplicate`），不得再次发送 I1，也不得把内部 `busy/idle` 瞬态暴露给
仍存在的目标 batch。

同步只回最小 ack。不得把 selector 展开结果或 snapshot 放进回复。

## 路径 B：旧 I2 兼容

升级前已经 active 的旧 FIFO 仍接受
`RUN_EXECUTOR_RESULT_CALLBACK`。沿用 `find_pending.sh -> notify_user.sh ->
drain_pending.sh -> finish_executor_queue_active.sh` 的收尾逻辑，但只允许身份完全一致、无
nonce、且已显式迁移为 `legacy_pre_upgrade` 的 launched active/pending。`find_pending.sh`
在同一 dispatcher 锁内完成该兼容标记；nonce_v1、launching、身份冲突或缺少 drain 证明的
旧 I2 均失败关闭且不修改状态。

`RUN_SINGLE_ISSUE` 已由 executor 转成 single driven batch。其初始 turn 返回严格五字段
acceptance 后，`drain_executor_queue.sh` 会先持久化 `driven_batch_id` bridge，再创建 Task 8
mirror。升级后生成的兼容 single intent 也携带独立 nonce，bridge/pending/mirror 只投影摘要。
后续该 single batch 只发认证 I3，不再发旧 I2；`recover_legacy_executor_batch_bridge.sh`
在 single I3 或 zero-match 后清旧 active/pending，并由 batch tick 推进下一条。LLM 不参与 bridge。

旧 FIFO 仅用于排空部署前遗留项。新请求禁止调用 `enqueue_executor_issue.sh`。

## 路径 C：周期恢复

对 `RUN_EXECUTOR_BATCH_TICK` 与兼容的 `RUN_EXECUTOR_QUEUE_DRAIN`，只调用：

```bash
cd "<SKILL_DIR 绝对路径>" && \
source scripts/source_dispatcher_env.sh && \
bash scripts/run_executor_batch_tick.sh
```

wrapper 顺序固定：

1. 修复 legacy single receipt/mirror/terminal bridge；
2. 推进一条旧 FIFO；
3. 再次修复 zero-match 或已终态 bridge；
4. 旧 active/queue 清空后才发送 durable batch I1；
5. 重试未交付通知。

stdout 固定为 `status=tick`，并含
`legacy_recovery_before,legacy_queue,legacy_recovery_after,batch_outbox,notifications`。只按 JSON
读取，不自行补跑内部脚本。executor agent 自身的 `RUN_EXECUTOR_BATCH_TICK` 由 executor
固定 wrapper 与部署周期唤醒负责，dispatcher 不展开子代理启动调用。

## 路径 D：I3 固定 handler

executor outbox 实际发送的完整 transport 为：

```text
RUN_DRIVEN_BATCH_RESULT_ACK_ONLY
callback_envelope={"batch_acceptance":<严格五字段 acceptance>,"callback_nonce":"<64 个小写 hex>","executor_agent":"<路由 agent>","worker_result_json":<严格八字段 I3 object>}
ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。
```

新 marker 必须恰好包含以上三行，第三行逐字匹配后才允许 durable apply。缺失、伪造或附加行
全部 fail closed。旧 sender 的 `RUN_DRIVEN_BATCH_RESULT` 两行格式继续由同一 handler 接受；
不得因此改变 envelope、nonce、project、executor 或八字段 I3 的任一校验。

把收到的**完整原文**原样交给 handler，不得由 LLM 手工截取第二行，也不得把 callback、nonce
或中间命令写入 `/tmp`、workspace 或其他临时文件。固定使用 stdin heredoc：

```bash
cd "<SKILL_DIR 绝对路径>" && \
bash -c 'source scripts/source_dispatcher_env.sh; WORKER_RESULT_JSON="$(cat)" bash scripts/handle_executor_batch_event.sh' <<'CALLBACK_EOF'
<完整 callback marker 原文>
CALLBACK_EOF
```

handler 还接受把严格四字段对象放入 `CALLBACK_ENVELOPE_JSON`；滚动升级期间兼容不带
`batch_acceptance` 的旧三字段认证对象。transport 必须只有首行和唯一一行
`callback_envelope=`；外层字段、五字段 acceptance 及内层八字段对象都按精确 schema 校验。
纯八字段 I3 只允许命中
明确 `legacy_pre_upgrade` mirror；新 batch/single 的任意纯 I3 都在 durable apply、bridge、通知
和网络调用前 fail closed。apply 还必须先核对 nonce SHA-256、完整 project 与授权 executor。
nonce 不得出现在 public acceptance、ack、用户通知、event ledger 或日志。

若 mirror 尚未建立，handler 会先用 nonce、project、executor 与原 durable I1 核对
`batch_acceptance`，幂等补写 `received` receipt 和 mirror，再执行
`apply_executor_batch_event.sh` durable apply；已有 mirror 时直接校验并落 I3。随后立即返回唯一
ack；legacy bridge recovery 与通知投递由 `run_executor_batch_tick.sh` 周期恢复：

```json
{"status":"accepted|duplicate","event_id":"<与输入完全相同>"}
```

对新 `RUN_DRIVEN_BATCH_RESULT_ACK_ONLY` 以及兼容旧 marker，handler 成功后，当前 turn 的最终 assistant 内容必须严格等于该 handler 的唯一 stdout JSON。禁止任何前后缀、Markdown 代码块、
解释、中文总结、第二个 JSON 或其他文本；不得改写、重排或重新序列化。handler 非零时不得伪造
ack。executor 只接受整个响应恰为一个严格 ack JSON，或整个响应恰为单个 `json`/无语言
Markdown 围栏且围栏 body 是唯一严格 ack JSON；任何围栏外字符、prose、双围栏、多个对象都
必须重试。

- `accepted` 与 `duplicate` 都是 executor outbox 的成功 ack。
- duplicate 不会重复 terminal_count 或生成第二个通知 item，也不会在 ack 路径同步投递通知。
- bridge、通知与网络调用都位于周期 tick；通知调用失败不会撤销 durable I3，也不会污染/压制
  ack，后续 tick 会按预算和退避继续重试。
- 未知 batch 返回 `unknown_batch` 且非零，executor 必须保留原 event_id 重投。
- `matched_count=0` 不接 I3；receipt 生成稳定 `<batch_id>:no-matches` 通知 intent，文案为
  “无匹配 OPEN Issue”，重复 receipt/tick 不生成第二份。

## Durable receipt 与 fail-closed

executor acceptance 的 immutable 字段是
`executor_agent,matched_count,snapshot_digest`。同一 request digest 重放时任一冲突都必须
fail closed；`scheduler_status` 只允许 `queued -> running -> completed` 向前演进。

receipt 先落 `executor_batch_outbox.json` 的 `received` 状态，再生成 mirror，最后转
`accepted`。因此：

- receipt 后崩溃：tick 不再触网，直接修 mirror；
- ack 丢失且 receipt 未落：同 batch I1 重投；
- mirror 已落但 accepted 未落：相同 receipt 幂等修复；
- 带 `batch_acceptance` 的认证 I3 早到 mirror 之前：先补 receipt/mirror，再以同一调用 accepted；
  滚动升级中的旧三字段认证 I3 仍返回 unknown，待 mirror 修复后以同 event 重投。

## Working Directory 与 JSON 纪律

OpenClaw 每个 Bash exec 都是新 shell。每次调用都必须在同一 exec 中 `cd`、source 配置并
调用一个顶层 wrapper。不得依赖上一个 exec 的 `export` 或工作目录。

内部脚本如 `record_executor_batch_receipt.sh`、`record_executor_batch.sh`、
`enqueue_executor_batch_empty_notification.sh`、`recover_legacy_executor_batch_bridge.sh`、
`apply_executor_batch_event.sh` 只供固定 wrapper 调用；LLM 不得直接调用。

## No-Fallback

- wrapper 非零：读取错误、分类、停止；不手改 JSON，不换临时命令重做。
- `submit_executor_batch.sh` 的 exec/process 未得到确定终态时，不查看私有 outbox、不另加 shell
  timeout、不再次提交原 MESSAGE；后续 `RUN_EXECUTOR_BATCH_TICK` 只会恢复同一 durable intent。
- `retryable_failure`/`waiting_for_legacy_drain` 是 durable 正常分支，不得生成新 batch。
- 不把下游 raw output 当 acceptance；只认严格 JSON object 与精确字段集合。
- 不在 dispatcher 重试业务 Issue；这里只重投同一个 durable transport intent。
- 不清理或删除 state 证据。

## Chat Output Policy

同步只返回受理、等待旧队列排空或入口拒绝的最小结论。每个 Issue 的
`done|failed|timeout|skipped` 由 durable notification queue 异步逐条通知；不发送额外聚合
进度。zero-match 只通知一次。

## References

- trigger 与严格信封：[`references/trigger_command.md`](references/trigger_command.md)
- state schema：[`references/state_schema.md`](references/state_schema.md)
- git_issuer 对接：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)
