# req_dispatcher Workspace Notes

本工作区实现 `req_dispatcher`：104 OpenClaw 上的需求接入与下游派发编排器。它接收 114 转发来的自由文本需求，跨 agent 异步派发给 `git_issuer` 建 issue（git_issuer 解析 project、打 acpx 入口标签），被动衔接 `acpx_auto_tester` 既有 cron 流程。

这是一个**薄派发器**：唯一 SKILL `requirement_dispatch`，三个 flock 保护的 shell 脚本（record_pending / drain_pending / evict_stuck），一张 `run_id` 主键的 pending 表 + append-only ledger。**没有** worktree / glab / campaign_state / UI 账号 / 模型档位——这些 acpx 专有概念在本 agent 不存在。

## Agent Identity

- Agent name: `req_dispatcher`
- 编排器 session: `agent:req_dispatcher:main`
- 下游目标 agent: `git_issuer`（独立 agent，经跨 agent 原语调用，**非**本 agent 的子代理）

## Execution Model（两路径）

唯一 SKILL：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。编排器处理两类唤醒：

- **接入路径**（114 投来自由文本需求，经 `agent run --agent req_dispatcher --deliver`）：`evict_stuck.sh` 兜底 → 跨 agent 异步 spawn `git_issuer`（payload `{requirement_text}`）→ `record_pending.sh` 记 pending（主键 `run_id`）→ 回最小受理 ack → `waiting_for_callback`。
- **回调路径**（git_issuer 完成回调，trigger 名待对齐，占位 `RUN_GITISSUER_CALLBACK`）：解析终态 → 按 `run_id` `drain_pending.sh` → 成功收尾 / 失败记 ledger + 可选 ops 通知。回调路径**不**派发新 spawn。

完整算法、精确 env 行、脚本入参契约：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。

## 跨 agent 原语依赖（待对齐）

req_dispatcher 经 OpenClaw **原生跨 agent spawn 原语**（形态类 `sessions_spawn`、可指定目标 agent、异步回调）调起 `git_issuer`。确切工具名、参数、回调字段**待与 OpenClaw 维护者/同事对齐**——契约与对齐清单见 [`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)。

**匹配以 `run_id` 为主**，故即便对齐前也能推进；且不要求 git_issuer 回显任何 token（零侵入）。

## State 布局

全部由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生：

```
${STATE_ROOT}/_dispatcher/
    pending.json     ← 唯一可变状态（run_id 主键）；flock(pending.lock) 保护
    ledger.jsonl     ← append-only 终态审计
    seq              ← 可选序号（仅回显模式用）
    pending.lock     ← flock 目标
    log/             ← 预留日志目录
```

schema 详见 [`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## Deployment Pin

部署期配置在 [`config/dispatcher.env`](config/dispatcher.env)：`GIT_ISSUER_AGENT`、`STATE_ROOT`、`STUCK_AFTER_MINUTES`、可选 `OPS_NOTIFY_CHANNEL` / `DEFAULT_ENTRY_LABEL`、跨 agent 原语连接参数（待对齐）。**group / project 不在此处**——随需求文本传入，由 git_issuer 解析。详见 [`config/README.md`](config/README.md)。

## acpx 衔接依赖（重要，记录在案）

req_dispatcher 的终点是"issue 已建且带 acpx 入口标签"，之后完全交给 `acpx_auto_tester` 既有 cron tick。**前提**：目标 project 必须有对应的 acpx campaign 在 cron 上跑，acpx 才能捞起该 issue。由于 project 由 git_issuer 按需求解析、acpx 是 per-project 部署，**全公司多 project 场景下，每个目标 project 都需有对应的 acpx campaign**——这属于 acpx/部署侧职责，不在 req_dispatcher 范围，但在此显式记录为依赖。

## 不在本机运行

与 `acpx_auto_tester` 一样，本工作区是 **OpenClaw agent 部署工件**，只在 server 上跑。本地开发只做静态检查（`bash -n`）与脚本功能冒烟（纯本地 state 操作可跑），不启动 agent。详见 [`CLAUDE.md`](CLAUDE.md)。
