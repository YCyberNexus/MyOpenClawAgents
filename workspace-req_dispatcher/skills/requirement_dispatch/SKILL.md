---
name: requirement_dispatch
description: "[SKILL_VERSION=2026-06-25.6] Receive a free-text product requirement forwarded from the 114 OpenClaw (via gateway `agent run --agent req_dispatcher --deliver`) and dispatch it to the downstream `git_issuer` agent as a cross-agent async spawn. req_dispatcher is a THIN passthrough: it does NOT touch GitLab/glab, does NOT parse the requirement or extract the project (git_issuer parses the project from the text and applies the acpx entry label), does NOT trigger acpx (acpx's existing cron campaign picks up the labeled issue passively), and does NOT report status back to the WeChat user (git_issuer/acpx notify via their own channels). Two execution paths over three flock-guarded shell helpers (record_pending.sh, drain_pending.sh, evict_stuck.sh): intake path (free-text requirement → evict_stuck backstop → cross-agent async spawn git_issuer with {requirement_text} → record pending keyed by run_id → minimal ack), and callback path (git_issuer completion → match pending by run_id → drain; success ends the flow, failure/launch_failed/stuck records to ledger + optional ops notify). State is one tiny run_id-keyed pending table plus an append-only ledger; no campaign_state, no worktree, no label machinery. spawn failures retry the identical payload up to 3 times with 2s backoff; pending past STUCK_AFTER_MINUTES with no callback is synthesized as stuck_evicted, never silently dropped."
allowed-tools: Bash, Read, sessions_spawn, subagents
---

# Requirement Dispatch Skill

这是一个 **薄编排契约**。`req_dispatcher` 把 114 转发来的自由文本需求，跨 agent 异步派发给 `git_issuer`，由 git_issuer 解析 project、建 GitLab issue、打 acpx 入口标签；之后被动交给 `acpx_auto_tester` 既有 cron 流程。所有确定性的 state 写入（pending 记录、drain、超时驱逐）都在 `scripts/` 下 flock 保护的 shell 脚本里；LLM 只做脚本干不了的事：调跨 agent spawn 原语、读回调、可选 ops 通知。

**职责边界（HARD）**：不碰 glab/GitLab、不解析需求/不提取 project、不触发 acpx、不追踪测试结果、不主动给企微用户回状态、不去重、git_issuer 失败不自动重试。详见 [`../../SOUL.md`](../../SOUL.md) §Global Rules 与下方 §No-Fallback。

state 与磁盘布局：[`references/state_schema.md`](references/state_schema.md)。跨 agent 原语与回调的确切形态、回调字段→drain env 运行时映射（待对齐）：[`references/trigger_command.md`](references/trigger_command.md)。git_issuer 的产出/变更规格（跨团队对接文档，orchestrator 运行时不必读）：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)。

## 路径判定

orchestrator（固定 session `agent:req_dispatcher:main`）每次被唤醒先判这次是哪一路：

- 收到**结构化跨 agent 完成回调**（git_issuer 终态，trigger 名见 trigger_command.md）→ **回调路径**。
- 否则（114 投来的自由文本需求消息）→ **接入路径**。

## 接入路径（自由文本需求进来）

1. **取需求原文**：114 经 `agent run --agent req_dispatcher "<需求原文>" --deliver` 投来。整段保留，**不解析、不改写**。
2. **stuck 兜底**（先跑，回收泄漏的 pending）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   bash scripts/evict_stuck.sh
   ```

3. **跨 agent 异步 spawn `git_issuer`**：用跨 agent spawn 原语（形态类 `sessions_spawn`、指定目标 `${GIT_ISSUER_AGENT}`、异步回调；确切工具名/参数见 trigger_command.md），payload 极简：`{requirement_text: <需求原文>}`。默认**不**附 `correlation_id`（匹配走 `run_id`）；回显模式是仅当对齐后确认回调不带 `run_id` 才启用的退化路径，其 `correlation_id` 生成机制尚未实现、列为待对齐（见 trigger_command.md §匹配），**未对齐前不要自行生成 token**。
   - **失败重试**（no-fallback）：同 payload 最多 3 次、2s 固定退避。三次仍失败 → 视为 `launch_failed`：调 `drain_pending.sh`（`OUTCOME=launch_failed`、`REASON=<最后一次原始错误>`、`RUN_ID="launch-fail-$(date -u +%s)"`——此处用时间戳作审计键是允许的，因为它**不进 pending、无匹配语义**）写 ledger + 可选 ops 通知，**不写 pending**，本路径结束。
4. **spawn 成功** → 拿到 runtime 返回的 `run_id`（+ `child_session_key`）。记 pending（主键 `run_id`）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   RUN_ID="<run_id>" CHILD_SESSION_KEY="<child_session_key>" REQ_DIGEST="<需求前80字>" \
   bash scripts/record_pending.sh
   ```

   （`CORRELATION_ID` 仅在回显模式下附带。）
5. **回最小受理 ack** 给 114（文案见 [`../../USER.md`](../../USER.md)，如"需求已受理，正在创建 issue；结果将由后续流程通知"），返回 `waiting_for_callback`。**不要**在此处同步等待 issue 创建结果——它经回调异步返回。

## 回调路径（git_issuer 完成）

1. **解析回调**里 git_issuer 的终态输出：成功（带 issue IID/URL）或失败（带原因）。字段→drain env 映射见 [`references/trigger_command.md`](references/trigger_command.md) §回调字段→drain_pending env（运行时契约）。
2. **匹配 pending（主键 = `run_id`）**：用回调携带的 `run_id` 定位 `pending[run_id]`。**不要求 git_issuer 回显我们的 token**（零侵入）。`child_session_key` 兜底匹配与 `correlation_id` 回显匹配都依赖回调字段名待对齐，且 `drain_pending.sh` 当前只按 `run_id` drain——这两条退化路径列为待对齐（见 trigger_command.md §匹配），**未对齐前只用 `run_id`**。
3. **drain**：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   RUN_ID="<run_id>" OUTCOME="<success|failed>" \
   ISSUE_IID="<iid 或空>" ISSUE_URL="<url 或空>" REASON="<失败原因 或空>" \
   bash scripts/drain_pending.sh
   ```

   - **匹配不到 pending**（`run_id` 不在 pending：迟到回调 / 已被 stuck 驱逐 / 重复回调）→ **仍照常调 `drain_pending.sh`**：它会写一条 `was_pending=false` 的审计行。这是**预期情形、非错误**，不要因此触发 No-Fallback 停下；记一条紧凑状态即可。
4. **成功** → 到此为止：issue 已带 acpx 入口标签，acpx cron 自己捞起，req_dispatcher 不再做任何事。
5. **失败** → 上面 drain 已写 `failed` ledger；若配置了 `OPS_NOTIFY_CHANNEL`，发一条失败通知给运维。**不回企微用户、不自动重试**（重试由用户重发需求）。
6. 返回单条紧凑状态。

## Working Directory（per-exec env 契约）

OpenClaw 每个 Bash tool call 是**全新 shell**，`export`/`cd` 不跨 exec 存活。每次调脚本都必须在**同一个** Bash exec 里：`cd "<SKILL_DIR 绝对路径>"` → `source ../../config/dispatcher.env`（拿 `STATE_ROOT`/`GIT_ISSUER_AGENT`/`STUCK_AFTER_MINUTES`/`OPS_NOTIFY_CHANNEL`）→ 前置最小 env → `bash scripts/<name>.sh`。脚本自身顶部 `source env_paths.sh` 从 `STATE_ROOT` 派生所有路径。不要把 `cd`/`source` 拆成单独的 exec。

脚本入参契约（env 变量名，须与脚本实际读取一致）：

| 脚本 | 必填 env | 可选 env |
|------|---------|---------|
| `evict_stuck.sh` | `STATE_ROOT`, `STUCK_AFTER_MINUTES` | — |
| `record_pending.sh` | `STATE_ROOT`, `RUN_ID` | `CHILD_SESSION_KEY`, `CORRELATION_ID`, `REQ_DIGEST` |
| `drain_pending.sh` | `STATE_ROOT`, `RUN_ID`, `OUTCOME` | `ISSUE_IID`, `ISSUE_URL`, `REASON` |

`STATE_ROOT` / `STUCK_AFTER_MINUTES` 来自 `config/dispatcher.env`（`source` 即得）。

## No-Fallback（HARD）

- 脚本非零退出 → 读 stdout/stderr、分类、记录、**stop**。不内联重写脚本逻辑、不"手动来一遍"、不换"更简单的命令"。
- **不碰 GitLab**：不调 glab/curl/任何 HTTP 库去建 issue 或打标签——那是 git_issuer 的事。
- **不解析需求 / 不提取 project**：整段透传，project 由 git_issuer 从文本解析。
- **不触发 acpx**：被动等 acpx cron tick。不追踪测试结果。
- **不去重**：透传语义；114 重发同需求会生成新 spawn/新 pending，可能重复建 issue（去重是 114/git_issuer 侧的事）。
- **git_issuer 回调报失败 → 不自动重试**（避免重复建 issue）。
- spawn 失败只允许"同 payload 3 次 2s 退避"这一种重试；耗尽即 `launch_failed`，不另寻他法。

若你发现自己要用一个 SKILL / 脚本 / references 里没列出的工具、命令、flag 或流程，那就是**停下并失败**的信号，而不是更努力地试。

## Chat Output Policy

orchestrator 每轮只回一条紧凑状态摘要：接入路径 → `{path:"intake", run_id, spawned|launch_failed}`；回调路径 → `{path:"callback", run_id, outcome, issue_iid?}`。详细证据只落 disk（`ledger.jsonl`），不进 chat。

## Where to look

- agent 灵魂、Global Rules、Session Policy：[`../../SOUL.md`](../../SOUL.md)。
- 工作区说明、agent 身份、执行模型、acpx 衔接依赖：[`../../AGENTS.md`](../../AGENTS.md)。
- 114 调用方式、ack 文案、配置项：[`../../USER.md`](../../USER.md)。
- state / ledger schema：[`references/state_schema.md`](references/state_schema.md)。
- 跨 agent 原语 + 回调字段（待对齐）：[`references/trigger_command.md`](references/trigger_command.md)。
- git_issuer 产出/变更对接文档（跨团队，运行时不必读）：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)、[`../../docs/integration/gitissuer_change_request.md`](../../docs/integration/gitissuer_change_request.md)。

存疑时 READ 对应 reference，不要凭记忆重构契约。
