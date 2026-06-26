# Spec：req_dispatcher —— 企微需求接入与下游派发编排器

> 日期：2026-06-25
> 目标：在 104 OpenClaw 上新建一个独立 agent `req_dispatcher`，作为"企微需求 → 自动测试"链路在 104 侧的统一接入点与薄派发器：接收 114 转发来的需求，调度 `git_issuer` 建 GitLab issue，再由 `git_issuer` 打上 acpx 入口标签，从而被动衔接 `acpx_auto_tester` 既有的基于 issue 的流程。

## 1. 背景

公司多区安全架构（见 `openclaw_architecture.drawio`）：

- **绿区** 企业微信是员工入口。
- **蓝区 104** 部署本仓的 OpenClaw agent（`acpx_auto_tester` 等）。
- **蓝区 114** 部署另一套 OpenClaw，对接企微聊天机器人；用户在企微上和机器人对话发需求。

新链路：114 的 OpenClaw 通过跨区通信（gateway `agent run --agent <name> --deliver` / HTTP 桥接，即架构图"114 侧如何调用特定 agent"的方式 A/B）把用户需求转发到 104。104 上需要一个新 agent 接收需求、调度同在 104 的 `git_issuer`（同事构建，"根据需求构建 GitLab issue"），issue 建好后走 `acpx_auto_tester` 既有的基于 issue 的测试流程。

本 spec 定义这个新 agent：`req_dispatcher`。

## 2. 关键决定（已与用户确认）

1. **跨 agent 调用机制**：`req_dispatcher` 通过 OpenClaw **原生跨 agent 调用原语**（形态类 `sessions_spawn`、可指定目标 agent、**异步、结果经回调返回**）调起 `git_issuer`。不 shell out 网关 CLI。
2. **acpx 衔接方式**：**被动**。`git_issuer` 建 issue 时即打上 acpx 入口标签（如 `todo`/`new`），acpx 自己已在 cron 上跑的 `RUN_SCHEDULED_ISSUE_CAMPAIGN` 下一轮自动捞起。`req_dispatcher` **不主动触发 acpx**。
3. **入口标签由谁打**：**`git_issuer` 打**。`req_dispatcher` 完全不碰 GitLab/glab。
4. **职责边界**：**极简**。`req_dispatcher` 只把需求交给 `git_issuer` 并保留失败可见性，**不主动给企微用户回状态**（git_issuer/acpx 各自 channel 通知用户）。
5. **目标 group/project 来源**：**不在 config 写死**（全公司共用链路）。114 只发自由文本需求，project 信息夹在文本里；`req_dispatcher` **整段原样透传**给 `git_issuer`，由 `git_issuer` 自己从文本解析 project。`req_dispatcher` 不解析自然语言。
6. **构建方案**：新建独立瘦身 workspace，复用 `acpx_auto_tester` 已验证的"thick orchestrator + 两路径异步回调"骨架，但去掉所有重机械（无 worktree、无 glab、无 campaign_state 大套）。
7. **agent 名**：`req_dispatcher` → `workspace-req_dispatcher/`。

## 3. 范围与职责边界

**做**：
- 作为 114 调用的稳定具名入口（agent 名 `req_dispatcher`）。
- 接收自由文本需求，跨 agent 异步派发给 `git_issuer`，传 `{requirement_text: 需求原文}`（默认不附 token；`correlation_id` 仅在待对齐的回显模式下才附带，见 §10.1）。
- 记一张极小 pending 表，按回调 drain，保留失败可见性。
- spawn 失败重试、stuck/timeout 兜底、失败记录 + 可选 ops 通知。
- 给 114 回一条最小受理 ack。

**不做（明确）**：
- 不碰 glab / GitLab（不建 issue、不打标签）。
- 不解析需求文本、不提取 project（git_issuer 的事）。
- 不触发 acpx（被动等 cron）。
- 不追踪测试结果、不主动给企微用户回状态。
- 不对重复需求去重（透传语义；去重是 114/git_issuer 侧的事）。
- 不在 git_issuer 失败时自动重试建 issue（避免重复建 issue）。

## 4. 架构总览

```
114(企微转发) ──agent run --agent req_dispatcher "<需求原文>" --deliver──▶ req_dispatcher
                                                                              │
                                              接入路径：生成 correlation_id    │
                                              跨 agent 异步 spawn(传需求原文)   ▼
                                                                          git_issuer
                                                                              │ 解析 project / 建 issue / 打 acpx 入口标签
                                                                              ▼
                                                                          GitLab issue (带 todo/new)
                                                                              │
                          异步完成回调(run_id + 成功 IID/URL 或失败) ──────────┘
                                              │
              回调路径：按 run_id 匹配 pending │
              成功→drain 收尾 / 失败→记录+可选 ops 通知，drain
                                              │
                  （issue 已带标签，req_dispatcher 到此为止）
                                              ▼
                         acpx_auto_tester 的 cron tick 自动捞起 → 原有 acpx 流程
```

两路径沿用 acpx 的 thick-orchestrator + 异步回调模型，但极简。

## 5. 目录结构

```
workspace-req_dispatcher/
  SOUL.md            ← agent 灵魂：两路径职责、no-fallback、回调匹配、极简回状态策略
  AGENTS.md          ← 工作区说明、agent 身份(agent:req_dispatcher:main)、执行模型
  USER.md            ← 使用契约：114 怎么调、git_issuer 契约、配置项、ack 文案
  CLAUDE.md          ← 给 Claude Code 的工作区指南 + 自包含的 SKILL_VERSION bump 规则
  config/
    README.md
    dispatcher.env   ← 部署期 pin：git_issuer agent 名、跨 agent 原语连接参数、可选 ops 通知 channel、可选默认入口标签
  skills/
    requirement_dispatch/
      SKILL.md            ← 唯一 SKILL：接入 + 回调两路径算法（含 SKILL_VERSION=YYYY-MM-DD.N）
      references/                 ← orchestrator 运行时读的契约（仅这些）
        trigger_command.md    ← 两条 trigger 字段契约 + 回调字段→drain env 运行时映射（占位待补）
        state_schema.md       ← pending map / state 文件 schema
  docs/integration/             ← 跨团队对接文档（orchestrator 运行时不读，给 git_issuer/114 作者）
    gitissuer_contract.md       ← git_issuer 创建契约 + 回传模板（占位，与同事对齐）
    gitissuer_change_request.md ← 需求变更（update/close/supersede）对接契约
      scripts/
        env_paths.sh          ← 路径自举（极简版，每脚本顶部 source）
        record_pending.sh     ← 接入路径：记一条 pending
        drain_pending.sh      ← 回调路径：匹配 + drain + 失败分类
        evict_stuck.sh        ← stuck/timeout 兜底：扫描超时 pending，合成失败并 drain
  .claude/
    settings.json
    settings.local.json
    hooks/require-workspace-review.sh   ← 复用 acpx 的 Stop-hook review 闸（适配本 workspace 路径）
```

> 注：scripts 清单是设计意图；实现阶段如发现某脚本可并入 SKILL 内联步骤则可精简，但 pending 的 flock 写入/读取/drain 必须落在脚本里以保证原子性。

## 6. 编排算法

### 路径判定
orchestrator 每次被唤醒先判这次是哪一路：
- 收到**结构化跨 agent 完成回调**（回调 trigger）→ 回调路径。
- 否则（自由文本需求消息）→ 接入路径。

### 接入路径（自由文本需求进来）
1. 取需求原文（114 经 `agent run --deliver` 投来）。
2. （可选）生成一个 `correlation_id` 回显 token（不使用 `Date.now()`/随机；用 disk 单调递增序号 `${STATE_ROOT}/_dispatcher/seq`，flock 保护）。**仅当 §10.1 对齐后确认回调不携带 `run_id`、需靠 git_issuer 回显才能匹配时才需要**；默认匹配走 `run_id`，无需此 token。
3. 跨 agent **异步** spawn `git_issuer`，payload 极简：`{requirement_text 原文}`（如启用回显则附 `correlation_id`）。
   - spawn 失败按 no-fallback 重试：同 payload 3 次、2s 固定退避（沿用 acpx）。仍失败 → 合成 `launch_failed`，记 disk + 可选 ops 通知，**不写 pending**，结束本路径。
4. spawn 成功 → 拿到 runtime 返回的 `run_id` + `child_session_key`。`record_pending.sh` 以 **`run_id` 为主键**落一条：`pending[run_id] = {child_session_key, correlation_id?, spawned_at, req_digest}`。
5. 给 114 回**最小受理 ack**（文案见 USER.md），返回 `waiting_for_callback`。

### 回调路径（git_issuer 完成）
1. 解析回调里 git_issuer 的终态输出：成功（带 issue IID/URL）或失败（带原因）。
2. **匹配 pending（主键 = `run_id`）**：用回调携带的 `run_id`（兜底 `child_session_key`）直接查 `pending[run_id]`——**不要求 git_issuer 回显任何我们的 token**，对同事的 agent 零侵入。仅当回调确实不带 `run_id` 时，才回退到用回显的 `correlation_id` 匹配（§10.1 对齐时二选一确认其一可行）。
3. 成功 → `drain_pending.sh` drain `pending[run_id]`，记一条成功日志。**到此为止**（issue 已带标签，acpx cron 自己捞）。
4. 失败 → drain + 记失败到 disk + 可选 ops 通知（**不回企微用户**）。
5. 返回单条紧凑状态。

## 7. 状态与并发

- **state 极小**：disk 上一个 `pending.json`（在 `${STATE_ROOT}/_dispatcher/` 下），以 `run_id` 为主键，flock 保护，每次从 disk 重建，**不靠 chat 记忆**。**没有** campaign_state / worktree / glab / 标签机。
- **并发**：多条需求可并发在飞，每条一条 pending（key=`run_id`）；回调按 `run_id` 各自 drain，互不串。无单批次限制（无 UI 账号约束，git_issuer 侧自己控并发）。
- **stuck/timeout 兜底**：每次接入路径（或可选的独立兜底 trigger）开头跑 `evict_stuck.sh`，把超 `stuck_after_minutes`（git_issuer 预期最大运行时长 + 余量）仍没等到回调的 pending 合成失败、记录、drain，避免 pending 永久泄漏。沿用 acpx"超时停放、不静默丢"。

## 8. 错误处理与 no-fallback

- **spawn 失败**：同 payload 3 次退避重试 → 仍失败合成 `launch_failed`，记 disk + 可选 ops 通知，不写 pending。**不静默丢**。
- **git_issuer 回调报失败**：记 disk + 可选 ops 通知，**不回企微用户、不自动重试**（避免重复建 issue；重试由用户重发需求）。
- **stuck/timeout**：见 §7 兜底。
- **不越界**：`req_dispatcher` 不替 git_issuer 建 issue、不碰 glab、不猜 project。任何超出契约的步骤 → stop-and-record，不即兴。
- **去重边界**：透传语义，默认不去重；114 重发同需求会生成新 `correlation_id`、可能重复建 issue。

## 9. 配置（dispatcher.env，部署期 pin）

```
GIT_ISSUER_AGENT=git_issuer          # 下游目标 agent 名
# 跨 agent 原语连接参数（如需要；具体字段待 §10.1 对齐后补）
# OPS_NOTIFY_CHANNEL=...              # 可选：失败通知 channel
# DEFAULT_ENTRY_LABEL=todo           # 可选：若将来需要 req_dispatcher 向 git_issuer 显式指定入口标签
```

**不含** group / project / 具体 target —— 这些随需求文本走，由 git_issuer 解析。

## 10. 待对齐契约（占位，不阻塞架构）

### 10.1 跨 agent 调用原语（→ references/trigger_command.md）
待补：确切工具名 + 调用参数（如何指定 target=git_issuer、如何传 payload、如何拿到 `run_id`/`child_session_key`）；回调 trigger 的确切名字与字段（`run_id` / `worker_result_json` 等在哪个字段、git_issuer 终态输出如何承载）。**匹配策略以 run_id 为主**，故即便 git_issuer 不回显 correlation_id 也能工作。

### 10.2 git_issuer I/O 契约（→ docs/integration/gitissuer_contract.md，跨团队对接文档非运行时 reference）
待与同事对齐：入参字段（除 requirement_text 外是否还需别的）；回调里成功/失败如何表达；issue IID/URL 在哪个字段；git_issuer 是否确实负责打 acpx 入口标签、打哪个标签、按什么规则解析 project。

### 10.3 ack 投递（→ USER.md）
待确认：`--deliver` 是否把 ack 投回企微；ack 文案。

## 11. 与 acpx 的衔接（被动）

- `req_dispatcher` 的终点是"issue 已建且带 acpx 入口标签"。之后完全交给 acpx 既有 cron tick。
- **前提（协调点，需部署确认）**：issue 必须落在 acpx 配置的扫描范围内（acpx 的 project + IID 范围/`require_labels`），acpx 才能捞起。由于 project 由 git_issuer 按需求解析、acpx 是 per-project 部署，**全公司多 project 场景下，目标 project 必须有对应的 acpx campaign 在跑**——这属于 acpx/部署侧职责，不在 req_dispatcher 范围，但在本 spec 显式记录为依赖。

## 12. 测试与运维约定（沿用本仓既有规矩）

- 脚本改动用 `/opt/homebrew/bin/bash -n <script>` 静态检查（本机 /bin/bash 3.2.57 会误判语法）。
- **不在本机跑 agent**（agent 只在 server 跑），本地只做静态检查。
- 所有 `workspace-req_dispatcher/` 改动走 **code-review 子代理循环**（`Agent(subagent_type="code-reviewer")`，≤3 轮），收尾把 diff 指纹写入 `.claude/.review-done-sha` 解除 Stop hook。
- SKILL 自带 `SKILL_VERSION=YYYY-MM-DD.N`；workspace 内任何改动同提交 bump（规则自包含写进 `req_dispatcher/CLAUDE.md`）。根 `AGENTS.md` 现只点名 acpx，是否纳入 req_dispatcher 由用户定，默认不动根文件。

## 13. 非目标 / 风险

**非目标**：
- 不实现 PRD 生成 / 语义建模 / Issue 拆分（那是架构图蓝区其它 agent 的事；本链路里 git_issuer 直接"需求→issue"）。
- 不实现测试结果回流企微 **（已变更）**：后续决定走"按用户闭环"，但**不经过 req_dispatcher**——由 git_issuer 写 `req_origin` 标记、acpx 终态读出后通知发起人。req_dispatcher 在该闭环里保持不变。端到端契约见 [`../../integration/result_notify_loop.md`](../../integration/result_notify_loop.md)。
- 不实现需求去重。

**风险**：
- **跨 agent 原语形态未最终确认**（§10.1）：若回调不携带 `run_id`，则需 git_issuer 回显 correlation_id，对同事 agent 有侵入——需在对齐时确认其一可行。
- **多 project 衔接**（§11）：目标 project 无对应 acpx campaign 时，issue 建好却无人测；需部署侧保证。
- **极简回状态**：用户在企微只收到 git_issuer/acpx 的通知；若两者通知缺失，用户体验上"需求石沉大海"——需确认 git_issuer/acpx 的 channel 通知到位。

## 14. 实现阶段（便于分段 review）

1. **骨架**：workspace 目录 + SOUL/AGENTS/USER/CLAUDE + dispatcher.env + .claude(settings/hook)。
2. **状态底座**：env_paths.sh + state_schema.md + record_pending.sh / drain_pending.sh / evict_stuck.sh（含 flock）。
3. **编排逻辑**：SKILL.md 两路径算法 + trigger_command.md + gitissuer_contract.md 占位。
4. **文档收口 + 版本**：USER.md ack 文案、CLAUDE.md bump 规则、SKILL_VERSION，README。

每个非平凡脚本 `/opt/homebrew/bin/bash -n` 检查；workspace 改动走 code-review 子代理循环。
