---
name: requirement_dispatch
description: "[SKILL_VERSION=2026-06-29.2] Orchestrate the WeChat-requirement → auto-test pipeline end to end from the 104 side: receive a free-text requirement forwarded from the 114 OpenClaw (via gateway `agent run --agent req_dispatcher --deliver`), chain-spawn `git_issuer` to create the GitLab issue, route the resulting project to the right `req_executor` deployment, spawn that executor's `RUN_SINGLE_ISSUE_TEST` driven single-issue test, then receive the executor's result callback and push the conclusion back to the originating user. req_dispatcher is now an ORCHESTRATOR but STILL does NOT touch GitLab: it holds no token, never calls glab, and never parses the requirement or extracts the project (git_issuer parses the project; the executor holds the GitLab token). THREE execution paths over flock-guarded shell helpers (record_pending.sh, drain_pending.sh, evict_stuck.sh, route_project.sh, notify_user.sh, ops_notify.sh): (A) intake path (capture origin metadata → evict_stuck backstop → cross-agent async spawn git_issuer with {requirement_text} → record pending stage=git_issuer keyed by run_id → minimal ack); (B) git_issuer callback path (parse {status,project,iid,url} → route_project to pick executor agent, __NO_ROUTE__ → notify user + ledger + ops + drain → spawn <executor> RUN_SINGLE_ISSUE_TEST(I1) → record pending stage=executor with project/iid/correlation_id → drain git_issuer stage; git_issuer failed → notify user failure + drain); (C) executor callback path (parse I2 {correlation_id,iid,project,status,mr_url,wiki_url,reason} → match pending stage=executor by run_id, correlation_id as secondary check → notify user result → drain). A requirement undergoes TWO async spawns (git_issuer, then executor), each keyed by its own run_id, each drained on its own callback. State is one run_id-keyed two-stage pending table plus an append-only ledger; no campaign_state, no worktree, no label machinery. spawn failures retry the identical payload up to 3 times with 2s backoff; pending past STUCK_AFTER_MINUTES with no callback (either stage) is synthesized as stuck_evicted, never silently dropped. Cross-agent spawn/callback primitives and the user-push channel are EXPLICITLY待对齐 placeholders (gated + ledger-traced, never silently dropped)."
allowed-tools: Bash, Read, sessions_spawn, subagents
---

# Requirement Dispatch Skill

这是一个 **端到端编排契约**。`req_dispatcher` 把 114 转发来的自由文本需求主动驱动整条「需求 → 自动测试」链路：跨 agent 异步派发给 `git_issuer`（由 git_issuer 解析 project、建 GitLab issue），拿到回调后按 project 查路由表选目标 `req_executor` 部署、spawn 其 `RUN_SINGLE_ISSUE_TEST` driven 单测，再收执行器结果回调、把结论推回发起需求的企微用户。所有确定性的 state 写入（pending 记录、drain、超时驱逐）与本地决策（路由查表、推送留痕）都在 `scripts/` 下 flock 保护或 best-effort 的 shell 脚本里；LLM 只做脚本干不了的事：调两段跨 agent spawn 原语、读两类回调、可选 ops 通知。

**职责边界（HARD）**：身份从「薄派发器」升级为「编排器」，但**仍不碰 GitLab**——不持 token、不调 glab/curl、不解析需求/不提取 project（git_issuer 解析 project，执行器持 GitLab token）。编排器只多做两步：git_issuer 回调成功 → 路由 + spawn executor；executor 回调 → 推用户结论。不去重；git_issuer / executor 回调报失败均不自动重试（重试由用户重发需求）。详见 [`../../SOUL.md`](../../SOUL.md) §Global Rules 与下方 §No-Fallback。

state 与磁盘布局（两段 pending、I3 entry）：[`references/state_schema.md`](references/state_schema.md)。两段跨 agent 原语与两类回调的确切形态、git_issuer 回调字段→drain env 运行时映射、executor spawn(I1) 入参与 executor 结果回调(I2) 信封（待对齐）：[`references/trigger_command.md`](references/trigger_command.md)。git_issuer 的产出/变更规格（跨团队对接文档，orchestrator 运行时不必读）：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)。

## 路径判定

orchestrator（固定 session `agent:req_dispatcher:main`）每次被唤醒先判这次是哪一路（一条需求先后经历两段异步 spawn，各自 run_id 主键、各自回调）：

- 收到**结构化跨 agent 完成回调**且来自 **git_issuer**（终态带 `project`/`issue_iid`/`issue_url` 或失败 reason，trigger 名见 trigger_command.md）→ **git_issuer 回调路径**（路径 B）。
- 收到**结构化结果回调**且来自 **req_executor**（I2 信封带 `correlation_id`/`status`，trigger 名见 trigger_command.md）→ **executor 回调路径**（路径 C）。
- 否则（114 投来的自由文本需求消息）→ **接入路径**（路径 A）。

## 路径 A：接入路径（自由文本需求进来）

1. **取需求原文 + capture origin**：114 经 `agent run --agent req_dispatcher "<需求原文>" --deliver` 投来。整段保留，**不解析需求语义、不改写、不提取 project**。仅从文本约定行 capture **origin 元数据** `{channel,user,conversation}`——这是 req_dispatcher 自己回推结果用的，**不是**解析需求。约定格式待对齐（见 trigger_command.md §origin 元数据，⚠️）；拿不到则 origin 留空（`ORIGIN_JSON` 不传，entry 里为 `null`），不阻断主流程。合成紧凑 JSON 备用：`origin_json='{"channel":"..","user":"..","conversation":".."}'`。
2. **stuck 兜底**（先跑，回收泄漏的 pending；覆盖两段 git_issuer/executor）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   bash scripts/evict_stuck.sh
   ```

   其 stdout `evicted <N> stuck pending`：若 `N > 0`，**可选 ops 通知**（见 §可选 ops 通知，`EVENT=stuck_evicted COUNT=<N>`）。

3. **跨 agent 异步 spawn `git_issuer`**：用跨 agent spawn 原语（形态类 `sessions_spawn`、指定目标 `${GIT_ISSUER_AGENT}`、异步回调；确切工具名/参数见 trigger_command.md），payload 极简：`{requirement_text: <需求原文>}`。默认**不**附 `correlation_id`（git_issuer 段匹配走 `run_id`）；回显模式是仅当对齐后确认回调不带 `run_id` 才启用的退化路径，其 `correlation_id` 生成机制尚未实现、列为待对齐（见 trigger_command.md §匹配），**未对齐前不要自行生成 token**。
   - **失败重试**（no-fallback）：同 payload 最多 3 次、2s 固定退避。三次仍失败 → 视为 `launch_failed`：调 `drain_pending.sh`（`OUTCOME=launch_failed`、`STAGE=git_issuer`、`REASON=<最后一次原始错误>`、`RUN_ID="launch-fail-$(date -u +%s)"`——此处用时间戳作审计键是允许的，因为它**不进 pending、无匹配语义**）写 ledger，**不写 pending**；随后**可选 ops 通知**（`EVENT=launch_failed RUN_ID=<同上 launch-fail key> REASON=<最后错误>`）。issue 尚未建，**不推用户**（或推可选"受理失败"，由部署决定）。本路径结束。
4. **spawn 成功** → 拿到 runtime 返回的 `run_id`（+ `child_session_key`）。记 pending（主键 `run_id`、`STAGE=git_issuer`、携带 origin）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   RUN_ID="<run_id>" STAGE="git_issuer" \
   ORIGIN_JSON="<origin_json 或不传>" \
   CHILD_SESSION_KEY="<child_session_key>" REQ_DIGEST="<需求前80字>" \
   bash scripts/record_pending.sh
   ```

   （`PROJECT`/`IID`/`CORRELATION_ID` git_issuer 段不传，entry 里为 `null`；`CORRELATION_ID` 仅在回显模式下附带。）
5. **回最小受理 ack** 给 114（文案见 [`../../USER.md`](../../USER.md)，如"需求已受理，正在创建 issue 并自动测试，结果稍后通知"），返回 `waiting_for_callback`。**不要**在此处同步等待——issue 创建与测试结果都经各自回调异步返回。

## 路径 B：git_issuer 回调路径（建 issue 完成 → 路由 + spawn executor）

1. **解析回调**里 git_issuer 的终态输出：成功（带 `status=success`、`project`、`issue_iid`、`issue_url`）或失败（`status=failed`、带 reason）。字段→drain env 映射见 [`references/trigger_command.md`](references/trigger_command.md) §回调字段→drain_pending env（运行时契约）。
2. **匹配 git_issuer 段 pending（主键 = `run_id`）**：用回调携带的 `run_id` 定位 `pending[run_id]`，取出其 `origin`。**不要求 git_issuer 回显我们的 token**（零侵入）。`child_session_key`/`correlation_id` 退化匹配列为待对齐（见 trigger_command.md §匹配），**未对齐前只用 `run_id`**。
3. **git_issuer 失败** → 推用户"建 issue 失败" + drain git_issuer 段，本路径结束：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   EVENT="failure" ORIGIN_JSON="<取自 pending 的 origin 或空>" \
   REASON="<git_issuer 失败原因>" \
   bash scripts/notify_user.sh

   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   RUN_ID="<run_id>" OUTCOME="failed" STAGE="git_issuer" \
   REASON="<git_issuer 失败原因>" \
   bash scripts/drain_pending.sh
   ```

   随后**可选 ops 通知**（`EVENT=git_issuer_failed RUN_ID=<run_id> REASON=<失败原因>`）。**不自动重试**。
4. **git_issuer 成功** → **按 project 路由选 executor**：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   PROJECT="<回调透传的 project>" ROUTING_FILE="${ROUTING_FILE}" \
   bash scripts/route_project.sh
   ```

   - stdout 是 executor agent 名 → 进第 5 步。
   - stdout 是 `__NO_ROUTE__` → **该 project 未接入执行器**：推用户 + ledger + ops 通知 + drain git_issuer 段，本路径结束。
     - 推用户：`EVENT="failure" ORIGIN_JSON="<origin>" IID="<issue_iid>" REASON="该 project 未接入执行器" bash scripts/notify_user.sh`。
     - drain：`RUN_ID="<run_id>" OUTCOME="failed" STAGE="git_issuer" PROJECT="<project>" IID="<issue_iid>" ISSUE_URL="<issue_url>" REASON="no_route" bash scripts/drain_pending.sh`。
     - 可选 ops 通知：`EVENT=git_issuer_failed RUN_ID=<run_id> REASON=no_route`（复用 ops 失败枚举留痕）。
   - 脚本 `exit 2`（`ROUTING_FILE` 缺失/格式错）→ **部署期配置写错**：按 No-Fallback 读 stderr、分类、记录、**停**（不当成 no-route，不臆造投递）。
5. **spawn `<executor>` RUN_SINGLE_ISSUE_TEST（I1）**：生成 `correlation_id`（待对齐生成机制——见 trigger_command.md §I1/§correlation_id，⚠️；未对齐前不臆造 token），用跨 agent spawn 原语（指定目标 = 第 4 步返回的 executor agent 名、异步回调），I1 入参：`project=<project>`、`iid=<issue_iid>`、`correlation_id=<correlation_id>`、`dispatcher_callback_target=${DISPATCHER_CALLBACK_TARGET}`（可选 `group`）。
   - **失败重试**（no-fallback）：同 payload 最多 3 次、2s 固定退避。三次仍失败 → `launch_failed`：推用户"已建 issue #<iid> 但未能启动测试"（`EVENT="failure" ORIGIN_JSON="<origin>" IID="<issue_iid>" REASON="启动测试失败"`）→ drain git_issuer 段（`OUTCOME=launch_failed STAGE=git_issuer PROJECT=<project> IID=<issue_iid>`）→ 可选 ops 通知。本路径结束（issue 已建，executor 段从未进 pending）。
6. **executor spawn 成功** → 拿到 runtime 返回的 `run_id2`（+ `child_session_key2`）。记 pending（**新 run_id2 主键**、`STAGE=executor`、携带 origin/project/iid/correlation_id）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   RUN_ID="<run_id2>" STAGE="executor" \
   ORIGIN_JSON="<取自 git_issuer 段 pending 的 origin 或空>" \
   PROJECT="<project>" IID="<issue_iid>" CORRELATION_ID="<correlation_id>" \
   CHILD_SESSION_KEY="<child_session_key2>" REQ_DIGEST="<需求前80字 或空>" \
   bash scripts/record_pending.sh
   ```

7. **drain git_issuer 段**（成功收尾该段；executor 段已另起新 pending）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   RUN_ID="<run_id>" OUTCOME="success" STAGE="git_issuer" \
   PROJECT="<project>" IID="<issue_iid>" ISSUE_URL="<issue_url>" \
   bash scripts/drain_pending.sh
   ```

   - **git_issuer 段匹配不到 pending**（迟到 / 已被 stuck 驱逐 / 重复回调）→ 仍照常调 `drain_pending.sh`（写 `was_pending=false` 审计行）。**但若已为此 run_id 起过 executor 段、又收到重复 git_issuer 回调**：drain 不会误删 executor 段（executor 段是另一 run_id2），不会重复 spawn——重复 spawn 由"先确认 git_issuer 段仍在 pending 才进第 5 步"避免；未在 pending 则只 drain、不再 spawn。
8. 返回单条紧凑状态。

## 路径 C：executor 回调路径（测试结果回来 → 推用户）

1. **解析 executor 结果回调（I2 信封）**：`{correlation_id, iid, project, status: done|failed|timeout, mr_url, wiki_url, reason}`。承载该 JSON 的回调信封字段名待对齐（见 trigger_command.md §I2，⚠️）。
2. **匹配 executor 段 pending（主键 = `run_id`）**：用回调 runtime 自带的 `run_id`（= 第 6 步记的 `run_id2`）定位 `pending[run_id]`；**`correlation_id` 作二次校验**（回调里的 `correlation_id` 须 = entry 的 `correlation_id`，防 run_id 错配；不一致则记一条紧凑告警并以 run_id 为准 drain，不臆造）。主匹配仍 `run_id`。
3. **按 status 推用户结论**（文案见 notify_user.sh，与设计稿 §4.3 逐字一致；done→"#<iid> 测试完成，MR：<mr_url>"，failed→"#<iid> 测试未通过：<reason>，证据见 <wiki_url>"，timeout→"#<iid> 测试超时未完成，已停放待人工处理"）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   EVENT="result" STATUS="<done|failed|timeout>" \
   ORIGIN_JSON="<取自 pending 的 origin 或空>" IID="<iid>" \
   MR_URL="<mr_url 或空>" WIKI_URL="<wiki_url 或空>" REASON="<reason 或空>" \
   bash scripts/notify_user.sh
   ```

4. **drain executor 段**：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   set -a && source ../../config/dispatcher.env && set +a && \
   RUN_ID="<run_id>" OUTCOME="<success|failed>" STAGE="executor" \
   PROJECT="<project 或空>" IID="<iid 或空>" \
   STATUS="<done|failed|timeout>" MR_URL="<mr_url 或空>" REASON="<reason 或空>" \
   bash scripts/drain_pending.sh
   ```

   - `OUTCOME` 映射：`status=done` → `OUTCOME=success`；`status=failed`/`timeout` → `OUTCOME=failed`（`STATUS` 仍透传精确终态供审计）。
   - **匹配不到 pending**（迟到 / 已被 stuck 驱逐 / 重复回调）→ 仍照常调 `drain_pending.sh`（写 `was_pending=false` 审计行）。这是**预期情形、非错误**，不触发 No-Fallback；记一条紧凑状态即可。
5. **不自动重试**（failed/timeout 不重投测试，重试由用户重发需求）。返回单条紧凑状态。

## 可选 ops 通知（best-effort）

失败事件在 drain / ledger 写入**之后**可选地推给运维 channel（`OPS_NOTIFY_CHANNEL`，部署期 pin；留空则整步 no-op）。三类事件同一脚本：

```bash
cd "<SKILL_DIR 绝对路径>" && \
set -a && source ../../config/dispatcher.env && set +a && \
EVENT="<launch_failed|git_issuer_failed|stuck_evicted>" \
RUN_ID="<相关 run_id 或空>" REASON="<原因摘要 或空>" COUNT="<stuck 驱逐数 或空>" \
bash scripts/ops_notify.sh
```

- `launch_failed`（git_issuer 段或 executor 段 spawn 三次仍败）：`EVENT=launch_failed RUN_ID=<launch-fail key> REASON=<最后错误>`。
- `git_issuer_failed`（git_issuer 回调报失败 / 路由 `no_route`）：`EVENT=git_issuer_failed RUN_ID=<run_id> REASON=<reason|no_route>`。
- `stuck_evicted`（接入路径开头 `evict_stuck` 驱逐到 `>0` 条；覆盖两段 pending）：`EVENT=stuck_evicted COUNT=<驱逐数>`。

退出码语义（**不**违反 No-Fallback）：脚本对"无 channel / 缺 curl / 网络失败 / webhook 非 2xx"一律 `exit 0`（best-effort——已尽力，需求本身由 ledger 兜底，绝不因发告警失败而回滚或停下）；仅当**部署配置形态写错**（`OPS_NOTIFY_CHANNEL` 非 http(s) URL、`EVENT` 非法）才 `exit 2`，此时按 No-Fallback 记一条 `ops-misconfig` 状态停下（失败需求此前已 drain，主流程不受影响）。

## Working Directory（per-exec env 契约）

OpenClaw 每个 Bash tool call 是**全新 shell**，`export`/`cd` 不跨 exec 存活。每次调脚本都必须在**同一个** Bash exec 里：`cd "<SKILL_DIR 绝对路径>"` → `set -a && source ../../config/dispatcher.env && set +a`（拿 `STATE_ROOT`/`GIT_ISSUER_AGENT`/`STUCK_AFTER_MINUTES`/`OPS_NOTIFY_CHANNEL`/`ROUTING_FILE`/`USER_NOTIFY_CHANNEL`/`DISPATCHER_CALLBACK_TARGET`）→ 前置最小 env → `bash scripts/<name>.sh`。脚本自身顶部 `source env_paths.sh` 从 `STATE_ROOT` 派生所有路径。不要把 `cd`/`source` 拆成单独的 exec。

脚本入参契约（env 变量名，须与脚本实际读取一致；I4）：

| 脚本 | 必填 env | 可选 env |
|------|---------|---------|
| `evict_stuck.sh` | `STATE_ROOT`, `STUCK_AFTER_MINUTES` | —（覆盖两段 git_issuer/executor） |
| `record_pending.sh` | `STATE_ROOT`, `RUN_ID`, `STAGE`(`git_issuer`\|`executor`) | `ORIGIN_JSON`, `PROJECT`, `IID`(正整数), `CORRELATION_ID`, `CHILD_SESSION_KEY`, `REQ_DIGEST` |
| `drain_pending.sh` | `STATE_ROOT`, `RUN_ID`, `OUTCOME` | `STAGE`, `PROJECT`, `IID`(或 `ISSUE_IID`), `ISSUE_URL`, `STATUS`(`done`\|`failed`\|`timeout`), `MR_URL`, `REASON` |
| `route_project.sh` | `PROJECT`, `ROUTING_FILE` | —（stdout：executor agent 名 或 `__NO_ROUTE__`；命中/未命中均 exit 0，文件缺失/格式错 exit 2） |
| `notify_user.sh` | `EVENT`(`result`\|`failure`) | `USER_NOTIFY_CHANNEL`(空则 no-op + ledger 留痕), `ORIGIN_JSON`, `STATUS`, `IID`, `MR_URL`, `WIKI_URL`, `REASON` |
| `ops_notify.sh` | `EVENT` | `OPS_NOTIFY_CHANNEL`(空则 no-op), `RUN_ID`, `REASON`, `COUNT` |

`STATE_ROOT` / `STUCK_AFTER_MINUTES` / `OPS_NOTIFY_CHANNEL` / `ROUTING_FILE` / `USER_NOTIFY_CHANNEL` / `DISPATCHER_CALLBACK_TARGET` 来自 `config/dispatcher.env`（`source` 即得）。`route_project.sh` / `ops_notify.sh` 不碰 state（不读写 pending/ledger/锁）：前者只读路由表查表，后者只发 best-effort 告警。`notify_user.sh` 不碰 GitLab、不建 issue、不打标签——只经出站通道把一句人读文案投回 origin（通道未配置则记 ledger 留痕、不静默丢）。

## No-Fallback（HARD）

- 脚本非零退出 → 读 stdout/stderr、分类、记录、**stop**。不内联重写脚本逻辑、不"手动来一遍"、不换"更简单的命令"。
- **不碰 GitLab**：不持 GitLab token，不调 glab/curl/任何 HTTP 库去建 issue / 打标签 / 跑测试——建 issue 是 git_issuer 的事、跑测试是 req_executor 的事。
- **不解析需求 / 不提取 project**：整段透传，project 由 git_issuer 从文本解析；编排器只在拿到回调透传的 project 后做一次 `route_project.sh` 精确表查。
- **route_project `__NO_ROUTE__` ≠ 脚本错误**：未命中是正常分支（推用户"未接入执行器"+ledger+ops+drain）；仅 `ROUTING_FILE` 缺失/格式错（exit 2）才是部署期配置写错，按 No-Fallback 停。
- **不去重**：透传语义；114 重发同需求会生成新两段 spawn/新 pending，可能重复建 issue + 重复测（去重是 114/git_issuer 侧的事）。
- **git_issuer / executor 回调报失败 → 不自动重试**（避免重复建 issue / 重复测；重试由用户重发需求）。
- spawn 失败（git_issuer 段或 executor 段）只允许"同 payload 3 次 2s 退避"这一种重试；耗尽即 `launch_failed`，不另寻他法。
- 跨 agent spawn/回调原语、用户出站推送通道、`correlation_id` 生成机制、origin 元数据约定均为**待对齐占位**：未对齐前不臆造工具名/字段名/token；脚本以 gated 占位 + ledger/log 留痕落地（绝不静默丢）。

若你发现自己要用一个 SKILL / 脚本 / references 里没列出的工具、命令、flag 或流程，那就是**停下并失败**的信号，而不是更努力地试。

## Chat Output Policy

orchestrator 每轮只回一条紧凑状态摘要：接入路径 → `{path:"intake", run_id, spawned|launch_failed}`；git_issuer 回调路径 → `{path:"gitissuer_cb", run_id, outcome, project?, iid?, routed_executor?|no_route, executor_run_id?}`；executor 回调路径 → `{path:"executor_cb", run_id, status, iid?, notified}`。详细证据只落 disk（`ledger.jsonl`），不进 chat。

## Where to look

- agent 灵魂、Global Rules、Session Policy：[`../../SOUL.md`](../../SOUL.md)。
- 工作区说明、agent 身份、执行模型、req_executor 衔接依赖：[`../../AGENTS.md`](../../AGENTS.md)。
- 114 调用方式、ack 文案、配置项：[`../../USER.md`](../../USER.md)。
- state / ledger schema（两段 pending、I3）：[`references/state_schema.md`](references/state_schema.md)。
- 两段跨 agent 原语 + 两类回调字段 + executor spawn(I1)/结果回调(I2) 信封（待对齐）：[`references/trigger_command.md`](references/trigger_command.md)。
- 多 project 路由表与 no-route 语义、用户出站推送通道配置：[`../../config/README.md`](../../config/README.md)、[`../../config/routing.env`](../../config/routing.env)。
- git_issuer 产出/变更对接文档（跨团队，运行时不必读）：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)、[`../../docs/integration/gitissuer_change_request.md`](../../docs/integration/gitissuer_change_request.md)。

存疑时 READ 对应 reference，不要凭记忆重构契约。
