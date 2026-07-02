# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this workspace is

这**不是**应用仓库——它是名为 `req_dispatcher` 的 **OpenClaw agent 部署工件**。它包含 agent 的提示契约（`SOUL.md`、`AGENTS.md`、`USER.md`）、一个 SKILL（`requirement_dispatch`）、该 SKILL 调用的 bash 脚本，以及部署期配置（`config/`）。没有 build、没有 test runner、没有包清单。改动通过把本工作区同步到 runner 来部署。

agent 本身在 OpenClaw runner 上运行。**不要尝试在本机启动这个 agent**——它只在 server 上跑。本机开发只做两件事：脚本静态检查（`/opt/homebrew/bin/bash -n scripts/foo.sh`），以及脚本功能冒烟（这些脚本是纯本地 state 操作，不碰网络/glab/acpx，可用临时 `STATE_ROOT` 跑通 record→drain→evict 验证）。本机 `/bin/bash` 是 3.2.57，会误判语法且缺 `mapfile`，所以**一律用 `/opt/homebrew/bin/bash`**。

## 它做什么 / 不做什么

`req_dispatcher` 是"企微需求 → 自动处理"链路在 104 侧的**统一接入点 + 端到端编排器**：接收 114 转发的自由文本需求，通过 `scripts/run_agent_turn.sh` 调用蓝区 `git_issuer` 建 issue（git_issuer 解析 project）→ 按 project 选择目标 `req_executor` 部署（所有合法 `group/project` 默认路由到 `DEFAULT_EXECUTOR_AGENT`，`routing.env` 只做覆盖）→ 通过同一包装脚本调用其 `RUN_SINGLE_ISSUE` driven 单次 issue 执行即时执行（具体做 coding/测试/规格/其它由 issue 决定）→ 收执行器结果回调 → 把结论推回发起需求的企微用户。身份从"薄派发器"升级为"编排器"。

**仍明确不做**：不持 GitLab token、不碰 glab/GitLab、不解析需求/不提取 project（只在拿到 git_issuer 返回的 project 后 `route_project.sh` 选 executor）、不自己跑 issue、不去重、git_issuer/executor 业务失败不自动重试。**新增会做**：两段下游 agent 调用（git_issuer + 按路由选定的 executor）、按 project 路由、终态把处理结论推回企微用户（仅一次）。

> 注意：本 agent **没有** acpx/执行器的那套 worktree / UI 账号 / campaign_state / 模型档位 / GitLab token / 标签机（token 归执行器侧）。若你在改动里引入了这些概念，几乎一定是搞错了 agent。

## Single-skill execution model

唯一 SKILL：`skills/requirement_dispatch/`，编排器固定 session `agent:req_dispatcher:main`。一条需求经历两段下游 agent 调用：git_issuer 段同轮 record/drain 作审计，executor 段记录 pending 等待后续结果回调。

- **接入路径（A）**（114 投来自由文本需求）：`capture_origin.sh` 捕获 origin（优先 OpenClaw 网关/运行时来源元数据，其次正文 `[origin]` 行；含回推目标 `reply_agent`）→ `evict_stuck.sh` 兜底 → `run_agent_turn.sh` 调用蓝区 `git_issuer`（payload 为需求原文，同 payload 失败 3 次 2s 退避）→ `record_pending.sh` 记 git_issuer 审计 stage → 解析 `{status,project,iid,url}` → 成功则 `route_project.sh` 选 executor（默认执行器覆盖所有合法 project）→ `run_agent_turn.sh` 调 `<executor> RUN_SINGLE_ISSUE`(I1) → `record_pending.sh` 记 `stage=executor`/新 `run_id2` → drain git_issuer 段 → 回最小 ack → `waiting_for_executor_callback`。
- **executor 回调路径（C）**：解析结果信封(I2) → 按 `run_id2` 匹配 executor 段，回调缺 `run_id` 时按 `correlation_id` 反查（`correlation_id` 二次校验）→ `notify_user.sh` 把结论推回 origin → drain executor 段。

完整算法见 [`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。

## State 布局

由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生：`${STATE_ROOT}/_dispatcher/` 下 `pending.json`（run_id 主键，flock 保护）/ `ledger.jsonl`（append-only 审计）/ `pending.lock` / `seq` / `log/`。schema：[`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## Strict no-fallback policy

- 脚本非零退出 → 读 stdout/stderr、分类、记录、**stop**。不内联重写脚本逻辑、不"手动来一遍"、不换"更简单的命令"。
- 不持 GitLab token、不碰 GitLab（不 glab/curl/HTTP 库建 issue / 打标签 / 跑 issue）；不解析需求/不提取 project（只 `route_project.sh` 选 executor）；不自己跑 issue；不去重；git_issuer/executor 业务失败不自动重试。
- 下游调用失败（`run_agent_turn.sh` envelope `status=failed`）只允许"同 payload 3 次 2s 退避"；耗尽即 `launch_failed`（写 ledger + 推用户 + 可选 ops 通知，不写 pending）。
- `route_project.sh` 未命中覆盖表时必须返回 `DEFAULT_EXECUTOR_AGENT`；只有默认执行器未配置时才输出 `__NO_ROUTE__`。project 形态错、`ROUTING_FILE` 缺失/格式错才按 no-fallback 停。
- 跨 agent 调用固定为 `run_agent_turn.sh` 包装 `openclaw agent --agent <target> --session-key <session> --message <payload> --timeout <seconds>`。origin 捕获固定为 `capture_origin.sh`，优先 OpenClaw 网关/运行时来源元数据，正文 `[origin]` 只是 fallback。用户出站推送已对齐：`notify_user.sh` 反向网关推 114 接收 agent，连接 pin 为 `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN`，目标 agent 优先取 `origin.reply_agent`、否则取默认 `DEFAULT_REPLY_AGENT`；缺少网关 pin 或目标 agent 则留痕；`REPLY_NOTIFY_TIMEOUT_SECONDS` 控制 best-effort 调用超时。

若你要用 SKILL / `scripts/` / `references/` 没列出的工具、命令、flag 或流程，那就是**停下并失败**的信号。详见 [`SOUL.md`](SOUL.md) §No-Fallback。

## Per-exec environment contract

OpenClaw 每个 Bash tool call 是全新 shell，`export`/`cd` 不跨 exec 存活。每次调脚本都在**同一个** Bash exec 里：`cd "<SKILL_DIR 绝对路径>" && source scripts/source_dispatcher_env.sh && <最小 env> bash scripts/<name>.sh`。该 helper 先加载 tracked `config/dispatcher.env`，再加载 ignored `config/dispatcher.local.env`（若存在）；脚本顶部 `source env_paths.sh` 从 `STATE_ROOT` 派生路径。脚本入参契约见 SKILL §Working Directory 的表。

## Sanity-checking shell changes

改任何脚本后跑 `/opt/homebrew/bin/bash -n scripts/foo.sh`。能跑通的本地功能冒烟（临时 `STATE_ROOT`，record→drain→evict）也鼓励做——它比纯 `bash -n` 强得多。

## Bumping SKILL_VERSION on workspace edits

改动 `workspace-req_dispatcher/` 下任何文件（`SOUL.md`/`AGENTS.md`/`USER.md`/`config/`/`skills/requirement_dispatch/` 下的 SKILL、`scripts/`、`references/`）后，bump [`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md) `description:` 字段里的 `[SKILL_VERSION=...]` token。

格式 `YYYY-MM-DD.N`：日期是改动当天；`N` 是当天序号。若现有版本日期不是今天 → 整体替换成 `<今天>.1`；若已是今天 → `N` 加 1。**同一次编辑/提交里 bump**，不留到后续。改动**本** `CLAUDE.md`、repo 根文件、`.claude/` 不触发 bump。

## Code review workflow

每个非平凡改动在视为完成前必须走 review 循环。reviewer 是 Claude Code `code-reviewer` 子代理（`Agent(subagent_type="code-reviewer")`）。

1. **Edit** → 2. **Review**（调用 `code-reviewer`，prompt 里点明 diff 范围，如"review `workspace-req_dispatcher/` 下未提交的 diff"）→ 3. **Address**（无可执行发现即结束）→ 4. **Repeat**（最多 3 轮；满 3 轮仍有问题则把报告交用户裁决，不擅自继续改）。

适用于 `workspace-req_dispatcher/` 下所有改动。trivial 改动（typo、版本 bump、单行修）可由主 agent 酌情跳过。

项目级 Stop hook（[`.claude/hooks/require-workspace-review.sh`](.claude/hooks/require-workspace-review.sh)，注册于 [`.claude/settings.json`](.claude/settings.json)）强制此约定：turn 结束时若 `workspace-req_dispatcher/` 有未提交改动，返回 `decision:"block"` 并喂回 review 指令。循环完成（或改动确属 trivial）后，把当前 diff 指纹写入 sentinel `workspace-req_dispatcher/.claude/.review-done-sha` 解除阻断——hook 的 reason 文本里给出了要执行的精确 `printf %s '<hash>' > <sentinel>` 行。

## Where to look for full details

- agent 契约：[`SOUL.md`](SOUL.md)（双路径、Global Rules、No-Fallback、两段匹配策略、Session Policy、Tooling）。
- 工作区说明 + req_executor 衔接依赖（主动编排）：[`AGENTS.md`](AGENTS.md)。
- 使用方式 + ack 文案 + 终态结论文案：[`USER.md`](USER.md)。
- 双路径算法 + 脚本入参（含 route_project/notify_user）+ 精确 env 行：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。
- state/ledger schema（两段 pending、I3）：[`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。
- `run_agent_turn.sh` 调用契约 + executor RUN_SINGLE_ISSUE(I1)/结果回调(I2) 信封：[`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)。
- 主动编排设计稿与实施计划：[`docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md)、[`docs/superpowers/plans/2026-06-29-req_dispatcher-active-orchestration.md`](docs/superpowers/plans/2026-06-29-req_dispatcher-active-orchestration.md)。
- git_issuer 对接文档（跨团队交接，orchestrator 运行时不读）：[`docs/integration/gitissuer_contract.md`](docs/integration/gitissuer_contract.md)（创建契约 + 回传模板）、[`docs/integration/gitissuer_change_request.md`](docs/integration/gitissuer_change_request.md)（变更请求契约）。

存疑时 READ 对应文件，不要凭记忆重构契约。
