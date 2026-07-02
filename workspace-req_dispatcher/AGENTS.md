# req_dispatcher Workspace Notes

本工作区实现 `req_dispatcher`：104 OpenClaw 上"企微需求 → 自动处理"链路的需求接入 + **端到端编排器**。它接收 114 转发来的自由文本需求，主动驱动整条链：通过 `scripts/run_agent_turn.sh` 调用蓝区 `git_issuer` 建 issue（git_issuer 解析 project）→ 按 project 选择目标 `req_executor` 部署（所有合法 `group/project` 默认路由到 `DEFAULT_EXECUTOR_AGENT`，`routing.env` 只做专属覆盖）→ 通过同一包装脚本调用其 `RUN_SINGLE_ISSUE` driven 单次 issue 执行（具体做 coding/测试/规格/其它由 issue 决定）→ 收执行器结果回调 → 把结论推回发起需求的企微用户。

身份从"薄派发器"升级为"编排器"，但**仍不碰 GitLab**（不持 token、不调 glab、不解析 project）：唯一 SKILL `requirement_dispatch`，flock 保护或 best-effort 的 shell 脚本（run_agent_turn / record_pending / drain_pending / evict_stuck / route_project / notify_user / ops_notify），一张 `run_id` 主键的 pending 表（executor 段长期 pending，git_issuer 段同轮审计 record/drain）+ append-only ledger。**没有** worktree / glab / GitLab token / campaign_state / UI 账号 / 模型档位——这些 acpx/执行器专有概念在本 agent 不存在（token 归执行器侧）。

## Agent Identity

- Agent name: `req_dispatcher`
- 编排器 session: `agent:req_dispatcher:main`
- 下游目标 agent（均独立 agent，经 `run_agent_turn.sh` 调用，**非**本 agent 的子代理）：
  - `git_issuer`（固定，建 issue）；
  - `<req_executor 部署>`（按 project 路由动态选定，跑 `RUN_SINGLE_ISSUE` 单次 issue 执行；默认见 `DEFAULT_EXECUTOR_AGENT`，覆盖项见 `config/routing.env`）。

## Execution Model（双路径）

唯一 SKILL：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。编排器处理两类唤醒：自由文本接入，以及 executor 结果回调。

- **接入路径（A）**（114 投来自由文本需求，经 `agent run --agent req_dispatcher --deliver`）：capture origin（含回推目标 `reply_agent`）→ `evict_stuck.sh` 兜底 → `run_agent_turn.sh` 调用蓝区 `git_issuer`（payload 为需求原文）→ 记录并 drain git_issuer 审计 stage → 解析 `{status,project,iid,url}` → 成功则 `route_project.sh` 选 executor（默认执行器覆盖所有合法 project）→ `run_agent_turn.sh` 调 `<executor> RUN_SINGLE_ISSUE`(I1) → `record_pending.sh` 记 `stage=executor`/新 `run_id2` → 回最小受理 ack → `waiting_for_executor_callback`；失败则推用户 + drain。
- **executor 回调路径（B）**（trigger 名 `RUN_EXECUTOR_RESULT_CALLBACK`）：解析结果信封(I2) → 按 `run_id2` 匹配 executor 段，回调缺 `run_id` 时按 `correlation_id` 反查（`correlation_id` 二次校验）→ `notify_user.sh` 推回 origin → drain executor 段。

完整算法、精确 env 行、脚本入参契约：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。

## 跨 agent 调用契约

req_dispatcher 经 `scripts/run_agent_turn.sh` 调用下游 agent。脚本内部固定执行：

```bash
openclaw agent --agent <target> --session-key <session> --message <payload> --timeout <seconds>
```

脚本 stdout 固定为 `{status,run_id,child_session_key,exit_code,worker_result_json,raw_output}`；openclaw 调用失败返回 `status=failed` 且脚本 exit 0，供 orchestrator 做 3 次固定退避；入参形态错误才 exit 2。executor 结果回调已固定为 `RUN_EXECUTOR_RESULT_CALLBACK` + `worker_result_json=<I2>`。用户出站推送通道**已对齐**：`notify_user.sh` 反向网关推 114 接收 agent（`openclaw agent run`，连接 pin `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN`，目标 agent 优先取 `origin.reply_agent`、否则取默认 `DEFAULT_REPLY_AGENT`；缺少网关 pin 或目标 agent 则留痕；`REPLY_NOTIFY_TIMEOUT_SECONDS` 控制超时）。

## State 布局

全部由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生：

```
${STATE_ROOT}/_dispatcher/
    pending.json     ← 唯一可变状态（run_id 主键，executor stage 长期 pending，git_issuer stage 同轮审计）；flock(pending.lock) 保护
    ledger.jsonl     ← append-only 终态审计（含 user_notify_skipped 留痕）
    seq              ← correlation_id 单调序号
    pending.lock     ← flock 目标
    log/             ← best-effort 通知留痕（notify_user 的 user_notify.jsonl 等）
```

schema 详见 [`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## Deployment Pin

部署期配置在 [`config/dispatcher.env`](config/dispatcher.env)：`GIT_ISSUER_AGENT`、`DEFAULT_EXECUTOR_AGENT`、`DOWNSTREAM_AGENT_TIMEOUT_SECONDS`、`STATE_ROOT`、`STUCK_AFTER_MINUTES`、`ROUTING_FILE`（project 覆盖路由表路径）、可选 `OPS_NOTIFY_CHANNEL` / `DEFAULT_ENTRY_LABEL`、用户结果推送 pin `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / 默认 `DEFAULT_REPLY_AGENT` / `REPLY_NOTIFY_TIMEOUT_SECONDS`、`DISPATCHER_CALLBACK_TARGET`（executor 结果回调目标）。project 覆盖路由表本体在 [`config/routing.env`](config/routing.env)（`PROJECT=AGENT` 行）。**group / project 不在此处**——随需求文本传入，由 git_issuer 解析；未命中覆盖表的合法 project 统一走 `DEFAULT_EXECUTOR_AGENT`。**GitLab token 不在此处**——归执行器侧 pin。详见 [`config/README.md`](config/README.md)。

## req_executor 衔接依赖（重要，记录在案）

req_dispatcher 不再止步于"issue 已建"——它在 git_issuer 成功后**主动调用目标 req_executor 部署的 `RUN_SINGLE_ISSUE`** 即时驱动单次 issue 执行（不再依赖独立 cron 被动捞起）。**前提**：`DEFAULT_EXECUTOR_AGENT` 对应的 req_executor 部署已就绪，且其 GitLab token/branch pin 能覆盖蓝区目标项目；少数需要专属 executor 的 project 可在 [`config/routing.env`](config/routing.env) 写覆盖行。合法 `group/project` 未命中覆盖表时不得失败，应路由到默认执行器。

**执行结果闭环**（已改为主动编排）：req_executor Phase 6 终态把结果回调（I2 信封）回投 req_dispatcher，req_dispatcher 据 `run_id2` 匹配 executor 段 pending、取出全程携带的 origin，经 `notify_user.sh` 把结论推回发起需求的企微用户；`origin.reply_agent` 指定 114 上接收结果的 agent，缺省才用默认 `DEFAULT_REPLY_AGENT`。**这条闭环现在经过 req_dispatcher**（与旧设计的 `req_origin`/`req_result` note 闭环不同；driven 路径不再依赖那套 note 机器，执行器侧机器保留供 cron 路径）。端到端契约见 [`docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md)；旧 [`docs/integration/result_notify_loop.md`](docs/integration/result_notify_loop.md) 仅适用于保留的 cron 路径。

## 不在本机运行

与 `acpx_auto_tester` 一样，本工作区是 **OpenClaw agent 部署工件**，只在 server 上跑。本地开发只做静态检查（`bash -n`）与脚本功能冒烟（纯本地 state 操作可跑），不启动 agent。详见 [`CLAUDE.md`](CLAUDE.md)。
