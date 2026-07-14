# CLAUDE.md

## 工作区性质

这是 `req_dispatcher` OpenClaw agent 部署工件，不是应用仓库。它包含 prompt 契约、一个
`requirement_dispatch` SKILL、Bash wrapper/tests 与部署配置。不要在本机启动 agent；本机只做
shell 静态检查与临时 `STATE_ROOT` 功能测试。

一律使用 `/opt/homebrew/bin/bash`。本机 `/bin/bash` 版本过旧，缺少项目脚本使用的能力。

## Agent 边界

dispatcher 是 prompt 路由器和 batch 控制面：

- 建单使用 git_issuer；
- 执行只使用 `submit_executor_batch.sh`；
- 周期恢复只使用 `run_executor_batch_tick.sh`；
- I3 只使用 `handle_executor_batch_event.sh`；
- 旧 I2/FIFO 只为部署升级排空保留。

它不建 Issue、不改 GitLab、不跑 Issue、不查询 GitLab Issue、不展开 IID snapshot、不管理
worktree/campaign/物理并发。wiki 是唯一只读 GitLab 入口。

iid_list 支持同一仓库中排序去重后的离散 IID；single/iid_list/range/open_unfinished/open_label
都只处理 intake 时为 OPEN 的 Issue；snapshot 查询、过滤
和冻结由 executor 完成，dispatcher 不补查 CLOSED Issue。

## 薄控制器规则

LLM 不得拆开执行下面的内部链：

```text
prepare_executor_issue_payload.sh
  -> route_project.sh
  -> build_executor_batch_payload.sh
  -> enqueue_executor_batch_request.sh
  -> drain_executor_batch_outbox.sh
```

不得直接调用 receipt/mirror/event/notification/legacy bridge 内部脚本，也不得手写 JSON state。
只读取顶层 wrapper 的严格 JSON。

`DISPATCHER_CALLBACK_TARGET` 为空必须在 ID/intent/network 前拒绝。I1 intent 必须先落盘；旧
FIFO 非空时不发送。ack 丢失只重投同 batch。receipt immutable 字段冲突 fail closed。

每个新 batch/single intent 自动生成独立 callback nonce；明文只留在私有 outbox/active I1，
mirror/pending 只保存摘要。I3 handler 在落账前核对 nonce 摘要、完整 project 和 executor，纯
八字段 I3 只兼容明确 `legacy_pre_upgrade` 的部署前 mirror。stdout 只能有一个
accepted/duplicate ack；notification drain 输出隔离，失败不撤销 ack。zero-match 使用稳定
no-match notification intent。

## State

`${STATE_ROOT}/_dispatcher/`：

- `executor_batch_outbox.json`：durable I1 intent 与 received/accepted receipt；
- `executor_batches.json`：compact mirror；
- `executor_batch_events.jsonl`：canonical I3 ledger；
- `executor_batch_notifications.json`：notification intent；
- `executor_batch_notification_attempts/`：event 专属 durable notify outcome；
- `executor_queue.json`/`pending.json`：旧 FIFO、git_issuer、旧 I2 兼容；
- `ledger.jsonl`：append-only 审计。

schema 见
[`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## 配置约束

- tracked 蓝区默认保持 `/data`、GitLab/wik pin、callback 与 gateway 契约。
- 本机路径/session/测试 endpoint 只放 ignored `config/dispatcher.local.env` 或进程环境。
- 不在仓库中运行 `rm`。

## Per-exec

OpenClaw 每个 Bash tool call 是新 shell。一次调用必须在同一个 exec：

```bash
cd "<SKILL_DIR 绝对路径>" && \
source scripts/source_dispatcher_env.sh && \
<最小 env> bash scripts/<顶层 wrapper>.sh
```

不依赖上一个 exec 的 `cd/export`。

## No-Fallback

- 脚本非零：读取错误、分类、停止；不手工重写逻辑或 state。
- `waiting_for_legacy_drain`/`retryable_failure` 是 durable 分支，不生成新 batch。
- 不从 raw output 猜 acceptance；只认精确五字段 executor public receipt。
- transport 只重投同 intent；dispatcher 不自动重试业务 Issue。

完整运行契约见
[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md) 与
[`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)。

## 验证

脚本修改至少运行：

```bash
/opt/homebrew/bin/bash -n skills/requirement_dispatch/scripts/<file>.sh
/opt/homebrew/bin/bash skills/requirement_dispatch/tests/test_driven_batch_simulated_flow.sh
/opt/homebrew/bin/bash skills/requirement_dispatch/tests/test_executor_batch_recovery_contract.sh
```

并回归 Task 8 event/notification、旧 queue、`run_agent_turn` 与全部 dispatcher shell tests。

## SKILL_VERSION

通常修改本 workspace 后按项目根规则 bump
`skills/requirement_dispatch/SKILL.md` 的 `SKILL_VERSION=YYYY-MM-DD.N`。

当前受驱动 batch 总计划明确把 Task 1–9 的版本变更统一留给 Task 10；执行 Task 9 时不得提前
bump。Task 10 完成后恢复常规规则。

## Code review

非平凡改动在完成前必须走只读 review：review 未提交的 `workspace-req_dispatcher/` diff，修复
Critical/Important 后再复审，最多三轮。reviewer 不得修改工作树、index、HEAD 或分支。

## 入口索引

- 运行契约：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)
- public trigger：[`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)
- state：[`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)
- 用户语义：[`USER.md`](USER.md)
- agent 硬边界：[`SOUL.md`](SOUL.md)
- git_issuer：[`docs/integration/gitissuer_contract.md`](docs/integration/gitissuer_contract.md)
