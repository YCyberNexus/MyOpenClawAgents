# req_dispatcher Workspace Notes

本工作区实现 `req_dispatcher`：104 OpenClaw 上"企微需求 → 自动测试"链路的需求接入 + **端到端编排器**。它接收 114 转发来的自由文本需求，主动驱动整条链：跨 agent 异步派发给 `git_issuer` 建 issue（git_issuer 解析 project）→ 按 project 查路由表选目标 `req_executor` 部署、spawn 其 `RUN_SINGLE_ISSUE_TEST` driven 单测 → 收执行器结果回调 → 把结论推回发起需求的企微用户。

身份从"薄派发器"升级为"编排器"，但**仍不碰 GitLab**（不持 token、不调 glab、不解析 project）：唯一 SKILL `requirement_dispatch`，flock 保护或 best-effort 的 shell 脚本（record_pending / drain_pending / evict_stuck / route_project / notify_user / ops_notify），一张 `run_id` 主键的**两段** pending 表（`stage=git_issuer|executor`）+ append-only ledger。**没有** worktree / glab / GitLab token / campaign_state / UI 账号 / 模型档位——这些 acpx/执行器专有概念在本 agent 不存在（token 归执行器侧）。

## Agent Identity

- Agent name: `req_dispatcher`
- 编排器 session: `agent:req_dispatcher:main`
- 下游目标 agent（均独立 agent，经跨 agent 原语调用，**非**本 agent 的子代理）：
  - `git_issuer`（固定，建 issue）；
  - `<req_executor 部署>`（按 project 路由动态选定，跑 `RUN_SINGLE_ISSUE_TEST` 单测；映射见 `config/routing.env`）。

## Execution Model（三路径）

唯一 SKILL：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。编排器处理三类唤醒（一条需求经历**两段异步 spawn**：git_issuer 段、executor 段，各自 `run_id` 主键、各自回调 drain）：

- **接入路径（A）**（114 投来自由文本需求，经 `agent run --agent req_dispatcher --deliver`）：capture origin → `evict_stuck.sh` 兜底（覆盖两段）→ 跨 agent 异步 spawn `git_issuer`（payload `{requirement_text}`）→ `record_pending.sh` 记 pending（`stage=git_issuer`、主键 `run_id`、携带 origin）→ 回最小受理 ack → `waiting_for_callback`。
- **git_issuer 回调路径（B）**（trigger 名待对齐，占位 `RUN_GITISSUER_CALLBACK`）：解析 `{status,project,iid,url}` → 成功则 `route_project.sh` 选 executor（`__NO_ROUTE__` → 推用户 + ledger + ops + drain）→ spawn `<executor> RUN_SINGLE_ISSUE_TEST`(I1) → `record_pending.sh` 记 `stage=executor`/新 `run_id2` → drain git_issuer 段；失败则推用户 + drain。
- **executor 回调路径（C）**（trigger 名待对齐，占位 `RUN_EXECUTOR_RESULT_CALLBACK`）：解析结果信封(I2) → 按 `run_id2` 匹配 executor 段（`correlation_id` 二次校验）→ `notify_user.sh` 推回 origin → drain executor 段。

完整算法、精确 env 行、脚本入参契约：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。

## 跨 agent 原语依赖（待对齐）

req_dispatcher 经 OpenClaw **原生跨 agent spawn 原语**（形态类 `sessions_spawn`、可指定目标 agent、异步回调）做**两段 spawn**：→ `git_issuer`（固定目标）与 → 按路由选定的 `<req_executor 部署>`（动态目标）。两类回调（git_issuer 完成、executor 结果 I2）的确切工具名、参数、信封字段**待与 OpenClaw 维护者/同事对齐**——契约、I1 入参、I2 信封与对齐清单见 [`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)。

**两段匹配各以自己的 `run_id` 为主**，故即便对齐前也能推进；不要求下游 agent 回显 token 作主匹配（零侵入），executor 段额外用 `correlation_id` 作二次校验。用户出站推送通道、`correlation_id` 生成、origin 约定亦为待对齐占位（脚本 gated + 留痕）。

## State 布局

全部由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生：

```
${STATE_ROOT}/_dispatcher/
    pending.json     ← 唯一可变状态（run_id 主键，两段 stage=git_issuer|executor）；flock(pending.lock) 保护
    ledger.jsonl     ← append-only 终态审计（含 user_notify_skipped 留痕）
    seq              ← 可选序号（仅回显/correlation_id 生成模式用，待对齐）
    pending.lock     ← flock 目标
    log/             ← best-effort 通知留痕（notify_user 的 user_notify.jsonl 等）
```

schema 详见 [`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## Deployment Pin

部署期配置在 [`config/dispatcher.env`](config/dispatcher.env)：`GIT_ISSUER_AGENT`、`STATE_ROOT`、`STUCK_AFTER_MINUTES`、`ROUTING_FILE`（多 project 路由表路径）、可选 `OPS_NOTIFY_CHANNEL` / `DEFAULT_ENTRY_LABEL`、待对齐占位 `USER_NOTIFY_CHANNEL`（用户出站推送通道）/ `DISPATCHER_CALLBACK_TARGET`（executor 结果回调目标）、跨 agent 原语连接参数（待对齐）。多 project 路由表本体在 [`config/routing.env`](config/routing.env)（`PROJECT=AGENT` 行）。**group / project 不在此处**——随需求文本传入，由 git_issuer 解析；project→executor 映射由路由表维护。**GitLab token 不在此处**——归执行器侧 pin。详见 [`config/README.md`](config/README.md)。

## req_executor 衔接依赖（重要，记录在案）

req_dispatcher 不再止步于"issue 已建"——它在 git_issuer 回调成功后**主动 spawn 目标 req_executor 部署的 `RUN_SINGLE_ISSUE_TEST`** 即时驱动单测（不再依赖独立 cron 被动捞起）。**前提**：目标 project 必须在 [`config/routing.env`](config/routing.env) 里有 `PROJECT=AGENT` 映射、且该 `AGENT`（per-project req_executor 部署，token/branch/`campaign_defaults.env` 在各自 executor 侧 pin）已就绪可被 spawn。由于 project 由 git_issuer 按需求解析、req_executor 是 per-project 部署，**全公司多 project 场景下，每个目标 project 都需有一行路由 + 对应 req_executor 部署**——这属于 req_executor/部署侧职责，不在 req_dispatcher 范围，但在此显式记录为依赖。路由查不到（`__NO_ROUTE__`）= 明确失败：推用户"未接入执行器" + ledger + ops + drain，不臆造乱投。

**测试结果闭环**（已改为主动编排）：req_executor Phase 6 终态把结果回调（I2 信封）回投 req_dispatcher，req_dispatcher 据 `run_id2` 匹配 executor 段 pending、取出全程携带的 origin，经 `notify_user.sh` 把结论推回发起需求的企微用户——**这条闭环现在经过 req_dispatcher**（与旧设计的 `req_origin`/`req_result` note 闭环不同；driven 路径不再依赖那套 note 机器，执行器侧机器保留供 cron 路径）。端到端契约见 [`docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md)；旧 [`docs/integration/result_notify_loop.md`](docs/integration/result_notify_loop.md) 仅适用于保留的 cron 路径。

## 不在本机运行

与 `acpx_auto_tester` 一样，本工作区是 **OpenClaw agent 部署工件**，只在 server 上跑。本地开发只做静态检查（`bash -n`）与脚本功能冒烟（纯本地 state 操作可跑），不启动 agent。详见 [`CLAUDE.md`](CLAUDE.md)。
