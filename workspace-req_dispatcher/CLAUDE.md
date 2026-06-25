# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this workspace is

这**不是**应用仓库——它是名为 `req_dispatcher` 的 **OpenClaw agent 部署工件**。它包含 agent 的提示契约（`SOUL.md`、`AGENTS.md`、`USER.md`）、一个 SKILL（`requirement_dispatch`）、该 SKILL 调用的 bash 脚本，以及部署期配置（`config/`）。没有 build、没有 test runner、没有包清单。改动通过把本工作区同步到 runner 来部署。

agent 本身在 OpenClaw runner 上运行。**不要尝试在本机启动这个 agent**——它只在 server 上跑。本机开发只做两件事：脚本静态检查（`/opt/homebrew/bin/bash -n scripts/foo.sh`），以及脚本功能冒烟（这些脚本是纯本地 state 操作，不碰网络/glab/acpx，可用临时 `STATE_ROOT` 跑通 record→drain→evict 验证）。本机 `/bin/bash` 是 3.2.57，会误判语法且缺 `mapfile`，所以**一律用 `/opt/homebrew/bin/bash`**。

## 它做什么 / 不做什么

`req_dispatcher` 是"企微需求 → 自动测试"链路在 104 侧的**统一接入点 + 薄派发器**：接收 114 转发的自由文本需求，跨 agent 异步派发给 `git_issuer` 建 issue（git_issuer 解析 project、打 acpx 入口标签），之后被动交给 `acpx_auto_tester` 既有 cron 流程。

**明确不做**：不碰 glab/GitLab、不解析需求/不提取 project、不触发 acpx、不追踪测试结果、不主动给企微用户回状态、不去重、git_issuer 失败不自动重试。

> 注意：本 agent **没有** acpx 的那套 worktree / UI 账号 / campaign_state / 模型档位 / GitLab 标签机。若你在改动里引入了这些概念，几乎一定是搞错了 agent。

## Single-skill, two-path execution model

唯一 SKILL：`skills/requirement_dispatch/`，编排器固定 session `agent:req_dispatcher:main`。两路径：

- **接入路径**（114 投来自由文本需求）：`evict_stuck.sh` 兜底 → 跨 agent 异步 spawn `git_issuer`（payload `{requirement_text}`，同 payload 失败 3 次 2s 退避）→ `record_pending.sh` 记 pending（主键 `run_id`）→ 回最小 ack → `waiting_for_callback`。
- **回调路径**（git_issuer 完成回调）：解析终态 → 按 `run_id` `drain_pending.sh` → 成功收尾 / 失败记 ledger + 可选 ops 通知。

完整算法见 [`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。

## State 布局

由 `scripts/env_paths.sh` 从 `STATE_ROOT` 派生：`${STATE_ROOT}/_dispatcher/` 下 `pending.json`（run_id 主键，flock 保护）/ `ledger.jsonl`（append-only 审计）/ `pending.lock` / `seq` / `log/`。schema：[`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。

## Strict no-fallback policy

- 脚本非零退出 → 读 stdout/stderr、分类、记录、**stop**。不内联重写脚本逻辑、不"手动来一遍"、不换"更简单的命令"。
- 不碰 GitLab（不 glab/curl/HTTP 库建 issue 或打标签）；不解析需求/不提取 project；不触发 acpx；不去重；git_issuer 回调失败不自动重试。
- spawn 失败只允许"同 payload 3 次 2s 退避"；耗尽即 `launch_failed`（写 ledger + 可选 ops 通知，不写 pending）。

若你要用 SKILL / `scripts/` / `references/` 没列出的工具、命令、flag 或流程，那就是**停下并失败**的信号。详见 [`SOUL.md`](SOUL.md) §No-Fallback。

## Per-exec environment contract

OpenClaw 每个 Bash tool call 是全新 shell，`export`/`cd` 不跨 exec 存活。每次调脚本都在**同一个** Bash exec 里：`cd "<SKILL_DIR 绝对路径>" && source ../../config/dispatcher.env && <最小 env> bash scripts/<name>.sh`。脚本顶部 `source env_paths.sh` 从 `STATE_ROOT` 派生路径。脚本入参契约见 SKILL §Working Directory 的表。

## Sanity-checking shell changes

改任何脚本后跑 `/opt/homebrew/bin/bash -n scripts/foo.sh`。能跑通的本地功能冒烟（临时 `STATE_ROOT`，record→drain→evict）也鼓励做——它比纯 `bash -n` 强得多。

## Bumping SKILL_VERSION on workspace edits

改动 `workspace-req_dispatcher/` 下任何文件（`SOUL.md`/`AGENTS.md`/`USER.md`/`config/`/`skills/requirement_dispatch/` 下的 SKILL、`scripts/`、`references/`）后，bump [`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md) `description:` 字段里的 `[SKILL_VERSION=...]` token。

格式 `YYYY-MM-DD.N`：日期是改动当天；`N` 是当天序号。若现有版本日期不是今天 → 整体替换成 `<今天>.1`；若已是今天 → `N` 加 1。**同一次编辑/提交里 bump**，不留到后续。改动**本** `CLAUDE.md`、repo 根文件、`.claude/` 不触发 bump。

## Code review workflow

每个非平凡改动在视为完成前必须走 review 循环。reviewer 是 Claude Code `code-reviewer` 子代理（`Agent(subagent_type="code-reviewer")`）。

1. **Edit** → 2. **Review**（spawn `code-reviewer`，prompt 里点明 diff 范围，如"review `workspace-req_dispatcher/` 下未提交的 diff"）→ 3. **Address**（无可执行发现即结束）→ 4. **Repeat**（最多 3 轮；满 3 轮仍有问题则把报告交用户裁决，不擅自继续改）。

适用于 `workspace-req_dispatcher/` 下所有改动。trivial 改动（typo、版本 bump、单行修）可由主 agent 酌情跳过。

项目级 Stop hook（[`.claude/hooks/require-workspace-review.sh`](.claude/hooks/require-workspace-review.sh)，注册于 [`.claude/settings.json`](.claude/settings.json)）强制此约定：turn 结束时若 `workspace-req_dispatcher/` 有未提交改动，返回 `decision:"block"` 并喂回 review 指令。循环完成（或改动确属 trivial）后，把当前 diff 指纹写入 sentinel `workspace-req_dispatcher/.claude/.review-done-sha` 解除阻断——hook 的 reason 文本里给出了要执行的精确 `printf %s '<hash>' > <sentinel>` 行。

## Where to look for full details

- agent 契约：[`SOUL.md`](SOUL.md)（两路径、Global Rules、No-Fallback、匹配策略、Session Policy、Tooling）。
- 工作区说明 + acpx 衔接依赖：[`AGENTS.md`](AGENTS.md)。
- 使用方式 + ack 文案：[`USER.md`](USER.md)。
- 两路径算法 + 脚本入参 + 精确 env 行：[`skills/requirement_dispatch/SKILL.md`](skills/requirement_dispatch/SKILL.md)。
- state/ledger schema：[`skills/requirement_dispatch/references/state_schema.md`](skills/requirement_dispatch/references/state_schema.md)。
- 跨 agent 原语 + 回调字段（待对齐）：[`skills/requirement_dispatch/references/trigger_command.md`](skills/requirement_dispatch/references/trigger_command.md)。
- git_issuer I/O 契约（待对齐）：[`skills/requirement_dispatch/references/gitissuer_contract.md`](skills/requirement_dispatch/references/gitissuer_contract.md)。

存疑时 READ 对应文件，不要凭记忆重构契约。
