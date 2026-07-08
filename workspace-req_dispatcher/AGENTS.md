# req_dispatcher Workspace Notes

本工作区实现 `req_dispatcher`：104 OpenClaw 上"企微需求 → 自动处理"链路的需求接入 + **端到端编排器**。它接收 114 转发来的需求消息；新主入口是智伴给出的蓝区 GitLab wiki URL，先用 `prepare_wiki_downstream_payloads.sh` 解析 wiki 所属 `group/project`、只读拉取 wiki Markdown、拆分需求并生成多条面向 `git_issuer` 的建单消息；旧自由文本入口仍兼容，使用 `prepare_downstream_payloads.sh` 剥离 114/origin 包装并要求文本里有明确 GitLab `group/project`。随后主动驱动整条链：通过 `scripts/run_agent_turn.sh` 调用蓝区 `git_issuer` 建 issue → 按 project 选择目标 `req_executor` 部署（所有合法 `group/project` 默认路由到 `DEFAULT_EXECUTOR_AGENT`，`routing.env` 只做专属覆盖）→ 把 issue 追加到 durable executor FIFO queue → 由 `drain_executor_queue.sh` 唯一启动队首 `RUN_SINGLE_ISSUE`（具体做 coding/测试/规格/其它由 issue 决定）→ 收执行器结果回调 → 清 active 并继续 drain 下一条 → 把结论推回发起需求的企微用户。

身份从"薄派发器"升级为"编排器"，但**仍不写 GitLab**（不建 issue、不打标签、不写 note、不跑 issue）。它仅可用 `WIKI_GITLAB_*` 只读配置拉取 wiki 内容；写操作仍全部归 `git_issuer` / `req_executor`。它只做受控入口分析和消息准备，不语义猜 project，issue 事实仍以 `git_issuer` 返回 JSON 为准。唯一 SKILL `requirement_dispatch`，flock 保护或 best-effort 的 shell 脚本（capture_origin / prepare_wiki_downstream_payloads / prepare_downstream_payloads / run_agent_turn / build_executor_payload / enqueue_executor_issue / drain_executor_queue / finish_executor_queue_active / record_pending / drain_pending / evict_stuck / route_project / notify_user / ops_notify），一张 `run_id` 主键的 pending 表（executor 段长期 pending，git_issuer 段同轮审计 record/drain）+ durable executor FIFO queue + append-only ledger。**没有** worktree / campaign_state / UI 账号 / 模型档位——这些 acpx/执行器专有概念在本 agent 不存在（执行器 token 归执行器侧）。

## Agent Identity

- Agent name: `req_dispatcher`
- 编排器 session: `agent:req_dispatcher:main`
- 下游目标 agent（均独立 agent，经 `run_agent_turn.sh` 调用，**非**本 agent 的子代理）：
  - `git_issuer`（固定，建 issue）；
  - `<req_executor 部署>`（按 project 路由动态选定，跑 `RUN_SINGLE_ISSUE` 单次 issue 执行；默认见 `DEFAULT_EXECUTOR_AGENT`，覆盖项见 `config/routing.env`）。

## Execution Model（三路径）

唯一 SKILL：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。编排器处理三类唤醒：需求接入、executor 结果回调、executor queue drain 恢复。

- **接入路径（A）**（114 投来需求，经 `agent run --agent req_dispatcher --deliver`）：`capture_origin.sh` 捕获 origin（优先 OpenClaw 网关/运行时来源元数据，其次正文 `[origin]` 行；含回推目标 `reply_agent`）→ 若消息含 GitLab wiki URL，则 `prepare_wiki_downstream_payloads.sh` 只读拉取 wiki 并生成 `git_issuer_payloads[]`；否则 `prepare_downstream_payloads.sh` 准备旧自由文本的单条 `git_issuer_payload` → `evict_stuck.sh` 兜底 → 对每个 payload 顺序调用蓝区 `git_issuer` → 记录并 drain git_issuer 审计 stage → 解析 `{status,project,iid,url}` → 成功则 `route_project.sh` 选 executor（默认执行器覆盖所有合法 project）→ `enqueue_executor_issue.sh` 追加 durable FIFO → `drain_executor_queue.sh` 尝试启动队首 → 回最小受理 ack；失败则推用户 + drain。
- **executor 回调路径（B）**（trigger 名 `RUN_EXECUTOR_RESULT_CALLBACK`）：解析结果信封(I2) → 按 executor `run_id` 匹配 pending，回调缺 `run_id` 时按 `correlation_id` 反查（`correlation_id` 二次校验）→ `notify_user.sh` 推回 origin → drain executor 段 → `finish_executor_queue_active.sh` 清 active → `drain_executor_queue.sh` 继续推进下一条。
- **executor 队列恢复路径（C）**（trigger 名 `RUN_EXECUTOR_QUEUE_DRAIN`）：先调用 `evict_stuck.sh`，再幂等调用 `drain_executor_queue.sh`。过期 executor pending 会清匹配 active；active 已 launched 且未过期时返回 busy；active stuck 在 launching、launch_failed 到期、或无 active 且 queue 非空时继续推进。

完整算法、精确 env 行、脚本入参契约：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。

## 跨 agent 调用契约

req_dispatcher 经 `scripts/run_agent_turn.sh` 调用下游 agent。脚本内部固定执行：

```bash
openclaw agent --agent <target> --session-id <session-id> --message <payload> --timeout <seconds>
```

脚本 stdout 固定为 `{status,run_id,child_session_key,exit_code,worker_result_json,raw_output}`；默认 session 由脚本自动生成并走 `--session-id`：普通下游调用用 `agent:<target>:main`，executor 的 `RUN_SINGLE_ISSUE` 用 payload 的 `project`/`iid` 生成 `agent:<target>:issue-<sanitized-project>-<iid>`，避免多个 issue 堆在 executor main session；普通下游调用不要手写 `TARGET_SESSION_ID`；历史 `TARGET_SESSION_KEY` 输入仅作兼容且同样转为 `--session-id`，但 `RUN_SINGLE_ISSUE` 若显式传了 `agent:<target>:main` 会改投 issue 级 session；openclaw 调用失败返回 `status=failed` 且脚本 exit 0，供 orchestrator 做 3 次固定退避；入参形态错误才 exit 2。下游 agent turn 可能超过本地 shell tool 的短轮询窗口，若进程仍在运行必须继续 poll 到最终 stdout，不得因暂时无输出而 kill。executor 结果回调已固定为 `RUN_EXECUTOR_RESULT_CALLBACK` + `worker_result_json=<I2>`。用户出站推送通道**已对齐**：`notify_user.sh` 仅在 `ORIGIN_JSON` 是合法 object 时反向网关推 114 接收 agent（`openclaw agent run`，连接 pin `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN`，目标 agent 优先取 `origin.reply_agent`、否则取默认 `DEFAULT_REPLY_AGENT`；`origin.reply_agent` 由 `capture_origin.sh` 优先从运行时来源元数据推导；空/null/非 object origin 视为手动入口不推 114；缺少网关 pin 或目标 agent 则留痕；`REPLY_NOTIFY_TIMEOUT_SECONDS` 控制超时）。

## State 布局

全部由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生：

```
${STATE_ROOT}/_dispatcher/
    pending.json     ← 下游结果 pending 表（run_id 主键，executor stage 长期 pending，git_issuer stage 同轮审计）；flock(pending.lock) 保护
    executor_queue.json ← executor durable FIFO（active + queue）；复用 pending.lock 保护
    ledger.jsonl     ← append-only 终态审计（含 user_notify_skipped 留痕）
    seq              ← correlation_id 单调序号
    pending.lock     ← flock 目标
    log/             ← best-effort 通知留痕（notify_user 的 user_notify.jsonl 等）
```

schema 详见 [`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## Deployment Pin

部署期配置在 [`config/dispatcher.env`](config/dispatcher.env)：`GIT_ISSUER_AGENT`、`DEFAULT_EXECUTOR_AGENT`、`DOWNSTREAM_AGENT_TIMEOUT_SECONDS`（git_issuer 等通用下游默认）、`EXECUTOR_AGENT_TIMEOUT_SECONDS`（executor 专用，默认 10800 秒）、`STATE_ROOT`、`STUCK_AFTER_MINUTES`、`ROUTING_FILE`（project 覆盖路由表路径）、wiki 只读 pin `WIKI_GITLAB_HOST` / `WIKI_GITLAB_API_PROTOCOL` / `WIKI_GITLAB_TOKEN` / `WIKI_GLAB_BIN`、可选 `OPS_NOTIFY_CHANNEL` / `DEFAULT_ENTRY_LABEL`、用户结果推送 pin `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / 默认 `DEFAULT_REPLY_AGENT` / `REPLY_NOTIFY_TIMEOUT_SECONDS`、`DISPATCHER_CALLBACK_TARGET`（executor 结果回调目标）、`EXECUTOR_QUEUE_*`（队列启动恢复与重试窗口）。project 覆盖路由表本体在 [`config/routing.env`](config/routing.env)（`PROJECT=AGENT` 行）。**group / project 不在此处**——wiki 入口从 URL 解析，旧自由文本随需求文本传入，由 git_issuer 校验；未命中覆盖表的合法 project 统一走 `DEFAULT_EXECUTOR_AGENT`。**执行器 GitLab token 不在此处**——归执行器侧 pin。详见 [`config/README.md`](config/README.md)。

## req_executor 衔接依赖（重要，记录在案）

req_dispatcher 不再止步于"issue 已建"——它在 git_issuer 成功后**把目标 req_executor 的单次 issue 执行放入 durable FIFO queue**，再由 `drain_executor_queue.sh` 主动调用队首 `RUN_SINGLE_ISSUE`（不再依赖独立 cron 被动捞起，也不依赖 executor main chat 自己记队列）。**前提**：`DEFAULT_EXECUTOR_AGENT` 对应的 req_executor 部署已就绪，且其 GitLab token/branch pin 能覆盖蓝区目标项目；少数需要专属 executor 的 project 可在 [`config/routing.env`](config/routing.env) 写覆盖行。合法 `group/project` 未命中覆盖表时不得失败，应路由到默认执行器。

**执行结果闭环**（已改为主动编排）：req_executor Phase 6 终态把结果回调（I2 信封）回投 req_dispatcher，req_dispatcher 据 executor `run_id` 或 `correlation_id` 匹配 executor 段 pending、取出全程携带的 origin，经 `notify_user.sh` 在 origin 为合法 object 时把结论推回发起需求的企微用户；随后清 queue active 并 drain 下一条，保证 #11 完成后 #12 不依赖人工追问。`origin.reply_agent` 指定 114 上接收结果的 agent，缺省才用默认 `DEFAULT_REPLY_AGENT`。手动 WebUI 入口没有 origin 时只留 ledger/log，不给 114 或企微发消息。**这条闭环现在经过 req_dispatcher**（与旧设计的 `req_origin`/`req_result` note 闭环不同；driven 路径不再依赖那套 note 机器，执行器侧机器保留供 cron 路径）。端到端契约见 [`docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md)；旧 [`docs/integration/result_notify_loop.md`](docs/integration/result_notify_loop.md) 仅适用于保留的 cron 路径。

## 不在本机运行

与 `acpx_auto_tester` 一样，本工作区是 **OpenClaw agent 部署工件**，只在 server 上跑。本地开发只做静态检查（`bash -n`）与脚本功能冒烟（纯本地 state 操作可跑），不启动 agent。详见 [`CLAUDE.md`](CLAUDE.md)。
