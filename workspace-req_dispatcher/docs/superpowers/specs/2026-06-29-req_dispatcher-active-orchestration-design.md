# req_dispatcher 主动端到端编排设计（方案 B）

> 状态：**已与用户对齐方向，部分跨团队/部署项待对齐**。本设计把"企微需求 → 自动处理"链路从
> **被动标签衔接（req_dispatcher 建带标签 issue → 独立 cron 捞起）** 改为
> **req_dispatcher 主动端到端编排（链式 spawn git_issuer → req_executor，执行结果回流 req_dispatcher → 推回用户）**。
>
> 它**取代**早先的 [`2026-06-25-req_dispatcher-design.md`](2026-06-25-req_dispatcher-design.md) 的"薄派发器 + 被动衔接"定位，以及
> [`../../integration/result_notify_loop.md`](../../integration/result_notify_loop.md) 的"req_origin/req_result note 闭环"在**本链路**的适用性（执行器侧机器保留，driven 路径不依赖）。
>
> **更新（2026-06-30.3 落地）**：§4.5/§9.2 的"用户出站推送通道（`USER_NOTIFY_CHANNEL`）"已对齐并实现——`notify_user.sh` 经**反向网关**把状态信封推给 114 智伴 agent（`openclaw agent run`，连接 pin `ZHIBAN_GATEWAY_URL`/`ZHIBAN_GATEWAY_TOKEN`/`ZHIBAN_AGENT`，超时 pin `ZHIBAN_NOTIFY_TIMEOUT_SECONDS`，仓库留空、部署期填；任一空则 ledger 留痕），由智伴负责企微最后一跳。下文所有 `USER_NOTIFY_CHANNEL` / "出站推送通道待对齐" 字样就此条目而言均已被取代。§6 的"超时零回调不推用户"缺口因本次未搭车闭合，**仍开放**。

## 1. 背景与已定决策

旧设计里 req_dispatcher 是**薄派发器**：建好带入口标签的 issue 即终止，执行器（req_executor）靠**独立 cron** 被动捞起，结果靠 issue 上的 `req_result` note 回 114。用户决定改为 req_dispatcher **主动驱动**整条链，要同时达成三点：① issue 建好即时测；② 不再依赖独立 cron；③ 端到端单点管控、可追踪结果。

四个已定决策（brainstorming 对齐）：

| 决策点 | 选定 |
|---|---|
| 实现路线 | **方案 B：完整端到端编排**（链式 spawn + 结果回调） |
| 执行器 GitLab 配置归属 | **执行器自持 + 新加单次 issue 执行入口** `RUN_SINGLE_ISSUE`；req_dispatcher 永不持有 GitLab token |
| 项目范围 | **一开始就做多 project 路由**（`project → executor agent` 路由表） |
| 结果闭环 | 执行结果由执行器 Phase 6 **回调 req_dispatcher**，再由 req_dispatcher 推回 origin（用户） |

req_dispatcher 仍**不碰 GitLab**（不持 token、不调 glab、不解析需求 project），但身份从"薄派发器"升级为"**编排器**"。

## 2. 架构总览

```
企微用户 → 114 ──需求原文(含 origin 元数据)──→ req_dispatcher(编排器, 固定 session agent:req_dispatcher:main)
   │
   ① 受理 ack ←─────────────────────────────────────┘
   │
   ├─ A. 接入路径: capture origin → evict_stuck 兜底 → spawn git_issuer {requirement_text}
   │      → record_pending(stage=git_issuer, run_id, origin)
   │
   ├─ B. git_issuer 回调路径: {status, project, iid, issue_url}
   │      success → 按 project 查路由表选 req_executor agent
   │             → spawn <executor> RUN_SINGLE_ISSUE {project, iid, correlation_id, callback_target}
   │             → record_pending(stage=executor, run_id2, 携带 origin/project/iid)
   │             → drain git_issuer 段
   │      failed  → 推"建 issue 失败"给 origin → drain
   │
   └─ C. executor 回调路径(新): {correlation_id, iid, status: done|failed|timeout, mr_url, reason, wiki_url}
          → 按 run_id 匹配 executor 段 pending
          → 映射用户文案 → 推回 origin → drain

执行器内部(RUN_SINGLE_ISSUE 唤醒后):
   Phases 1-5(scope 单 IID) → 自己的匿名子代理跑 acpx claude exec → RUN_CHILD_COMPLETION_CALLBACK
   → 内部 Phase 6 终态 → 【新增】向 callback_target 发结果回调 {correlation_id, ...}
```

一条需求经历**两段异步 spawn**（git_issuer、req_executor），各自 run_id 主键、各自回调 drain。

## 3. req_executor 改动规格

### 3.1 新 trigger `RUN_SINGLE_ISSUE`（driven 入口）

发往同一 orchestrator session `agent:req_executor:main`。入参（多行 key=value，沿用现有 trigger 文本格式）：

| 字段 | 必填 | 含义 |
|---|---|---|
| `project` | 是 | GitLab project 全名 `<group>/<project>`（git_issuer 回调形态，req_dispatcher 原样透传、亦作路由键）；`dispatch_single_issue.sh` 内部拆成裸 slug + group 喂 `env_paths.sh`（直接喂 `group/project` 会让 group 翻倍、clone 路径错位） |
| `iid` | 是 | 要测的 issue IID（单个，正整数） |
| `correlation_id` | 是 | req_dispatcher 生成的关联 token，原样回显在结果回调里供 req_dispatcher 匹配 |
| `dispatcher_callback_target` | 是 | 结果回调的目标（req_dispatcher 的 agent/session 标识；确切形态待对齐，§9） |
| `group` | 否 | 缺省取 pin 配置 |

**其余字段一律不收**——`gitlab_token` / `branch` / `dev_branch` / `hourly_issue_quota` / `max_concurrent_subagents` / `max_accounts_per_issue` / `ui_accounts_relpath` / `acpx_timeout_seconds` / `run_timeout_seconds` / `stuck_after_minutes` / `result_basename` / `data_basename` 等全部从 §3.2 的 pin 配置取。

### 3.2 新增 pin 配置：`config/campaign_defaults.env`

把今天靠 scheduled trigger 一次性喂的 campaign 字段，挪成部署期 pin（per-project 部署各自一份）：

```
GITLAB_TOKEN_SOURCE=...        # token 注入方式(pin 值 / 读 env / 读文件)，§9 待定
BRANCH=master
DEV_BRANCH=dev
HOURLY_ISSUE_QUOTA=1           # driven 单次 issue 执行固定 1
MAX_CONCURRENT_SUBAGENTS=1     # driven 单次 issue 执行固定 1
MAX_ACCOUNTS_PER_ISSUE=14
UI_ACCOUNTS_RELPATH=           # 可选
ACPX_TIMEOUT_SECONDS=18000
RUN_TIMEOUT_SECONDS=18120
STUCK_AFTER_MINUTES=...        # 默认派生
RESULT_BASENAME=ifp-result
DATA_BASENAME=ifp-data
REPO_PARENT_PATH=/data
```

`RUN_SINGLE_ISSUE` 解析时：`source config/gitlab.env`（已有 host pin）+ `source config/campaign_defaults.env` → 合成等价的 campaign 配置 → 叠加 `issue_iids=[iid]`、`issue_min_iid=issue_max_iid=iid`。

### 3.3 内部执行：复用现有 campaign 机器

`RUN_SINGLE_ISSUE` 不另起炉灶——它内部就是一次 `issue_iids=[iid]`、quota=1、concurrency=1 的 campaign tick：照常 `dispatch_prepare_tick.sh`（reconcile → prep → 渲染 executor prompt）→ 匿名 `sessions_spawn` 一个 per-issue 子代理 → 子代理跑 Steps 0–10（`acpx claude exec` → stage/commit/push → wiki → MR → compact JSON）→ 内部 `RUN_CHILD_COMPLETION_CALLBACK` → `dispatch_followup.sh` Phase 6。**子代理与 Steps 0–10 完全不变。**

落地形态：新增 `dispatch_single_issue.sh`（或在 `dispatch_prepare_tick.sh` 加 `TRIGGER=RUN_SINGLE_ISSUE` 分支）做"读 pin 配置 + 合成 campaign 字段 + 写入 `correlation_id`/`dispatcher_callback_target` 到该 issue 的 `state.json`"，再走既有 Phase 1–5。

### 3.4 Phase 6 结果回调（新增一步）

`dispatch_followup.sh` 终态处，若该 issue 的 state 带 `correlation_id`+`dispatcher_callback_target`（即 driven 调用），在现有 drain/label/kill 之后 **best-effort** 发一条跨 agent 结果回调给 req_dispatcher：

```
{ correlation_id, iid, project, status: done|failed|timeout, mr_url, wiki_url, reason }
```

- 仿现有 `post_result_note.sh` 的隔离语义：`set +e`、stdout→/dev/null、失败只记 wrapper.log、绝不打断 Phase 6。
- `status` 取 Phase 6 的 `final_status`（`done`/`failed`/`timeout`；`blocked` 是可重试态、**不**回调——等下一 attempt 或停放）。
- 落地：新增 `notify_dispatcher.sh`（跨 agent send 原语，工具名待对齐 §9）。**保留** `post_result_note.sh`，但 driven 路径默认不发 req_result note（避免与回调重复；由开关控制）。

### 3.5 GitLab token 归属

token 归执行器侧（每个 per-project 部署各自 pin / env 注入）。req_dispatcher 永不持有、不传 token。注入方式与轮换 §9 待定。

### 3.6 保留既有 `RUN_SCHEDULED_ISSUE_CAMPAIGN` + cron

不动，供非本链路（批量 backfill / 其它来源 issue）使用。本链路只走 `RUN_SINGLE_ISSUE`。

## 4. req_dispatcher 改动规格（薄派发器 → 编排器）

### 4.1 接入路径

1. 取需求原文；**capture origin 元数据**（channel/user/conversation，从文本约定行解析——仅供 req_dispatcher 自己回推结果用，不解析需求语义）。
2. `evict_stuck.sh` 兜底（覆盖两段 pending）。
3. spawn `git_issuer {requirement_text}`（同 payload 失败 3 次 2s 退避）。
4. `record_pending.sh`（`stage=git_issuer`、`run_id` 主键、携带 `origin`）。
5. 回最小受理 ack（"需求已受理，正在创建 issue 并自动处理，结果稍后通知"）。

### 4.2 git_issuer 回调路径

1. 解析 git_issuer 终态 JSON（沿用 [`gitissuer_contract.md`](../../integration/gitissuer_contract.md)：`status`/`project`/`issue_iid`/`issue_url`）。
2. 按 `run_id` 定位 `pending[git_issuer 段]`，取出 `origin`。
3. **success**：
   - 按 `project` 查**路由表**（§4.4）→ 选 req_executor agent；查不到 → 记 ledger + 推"该 project 未接入执行器"给 origin + ops 通知 + drain，结束。
   - 生成 `correlation_id`；spawn `<executor> RUN_SINGLE_ISSUE {project, iid, correlation_id, dispatcher_callback_target}`（同 payload 失败 3 次 2s 退避；耗尽 → `launch_failed` 推用户 + ledger）。
   - `record_pending.sh`（`stage=executor`、新 `run_id2` 主键、携带 `origin`/`project`/`iid`/`correlation_id`）。
   - drain git_issuer 段。
4. **failed**：推"建 issue 失败：<reason>"给 origin → drain git_issuer 段。

### 4.3 executor 回调路径（新）

1. 解析执行器结果回调 `{correlation_id, iid, status, mr_url, reason, wiki_url}`。
2. 按 `run_id`（回调 runtime 自带）匹配 `pending[executor 段]`；`correlation_id` 作二次校验。
3. 按 `status` 映射用户文案：
   - `done` → "#<iid> 已处理完成，MR：<mr_url>"
   - `failed` → "#<iid> 处理未通过：<reason>"（wiki_url 非空时追加"，详情见 <wiki_url>"）
   - `timeout` → "#<iid> 处理超时未完成，已停放待人工处理"
4. **推回 origin**（§4.5）→ drain executor 段。
5. 匹配不到（迟到/已驱逐/重复）→ 仍 drain 写 `was_pending=false` 审计行，不触发 No-Fallback。

### 4.4 多 project 路由表（新 config）

`config/` 新增 `routing.env`（或 `routing.json`）：`project → { executor_agent }`。例：

```
claw_gitlab/px_ifp_hulat_test = req_executor_ifp
claw_gitlab/px_xxx           = req_executor_xxx
```

git_issuer 回调拿到 `project` 后查表选目标 executor agent。每个 project 对应一个 req_executor 部署（token/branch 在各自 executor 侧 pin）。查不到 = 明确失败（不臆造、不默认乱投）。

### 4.5 用户推送通道（B 方案关键新依赖）

req_dispatcher 首次需要**主动给用户推实质结论**（受理 ack 之外）。用 `origin` 经出站通道把结果投回企微发起人。机制 §9 待对齐（企微 webhook / 经 114 回投）。落地：新增 `notify_user.sh`（仿 `ops_notify.sh` best-effort 语义，但目标是 origin 而非运维 channel；通道未配置则记 ledger 留痕、不静默丢）。

### 4.6 State / pending 两段模型

`pending.json`（run_id 主键，flock 保护）每条 entry 加：

```
{ run_id, stage: "git_issuer"|"executor", origin: {...},
  project?, iid?, correlation_id?, req_digest, spawned_at, child_session_key }
```

一条需求先后有两条 pending（git_issuer 段 drain 后再起 executor 段；不强制重叠）。`drain_pending.sh` 增 `STAGE` 入参写 ledger。`record_pending.sh` 增 `STAGE`/`ORIGIN`/`PROJECT`/`IID`/`CORRELATION_ID`。匹配仍按 run_id，对 git_issuer 与 executor 两个下游 agent 都**零侵入**（不要求回显我们的 token；correlation_id 仅作二次校验）。

## 5. 数据流与匹配

- 每段 spawn 各拿 runtime `run_id`，记一条 pending，回调按 run_id drain。
- `correlation_id`：req_dispatcher 在 spawn executor 时生成并随 payload 传，执行器原样回显——**作 executor 回调的二次校验**（防 run_id 错配）；主匹配仍 run_id。
- `origin` 全程随 pending 携带，executor 回调时取出用于推送。

## 6. 失败处理（无自动重试，沿用 No-Fallback）

| 失败点 | 处置 |
|---|---|
| git_issuer spawn 3 次仍败 | `launch_failed` 记 ledger + 可选 ops 通知；不推用户（issue 还没建）或推"受理失败"（可选） |
| git_issuer 回调 failed | 推"建 issue 失败：<reason>"给 origin + drain |
| project 路由查不到 | 推"该 project 未接入执行器" + ledger + ops 通知 + drain |
| executor spawn 3 次仍败 | `launch_failed` 推"已建 issue #<iid> 但未能启动处理" + ledger + ops 通知 |
| executor 回调 failed/timeout | 推对应文案给 origin + drain |
| 任一段 pending 超 `STUCK_AFTER_MINUTES` 无回调 | `evict_stuck.sh` 合成 stuck、记 ledger（含 stage）、drain。见下方"已知缺口"。 |

> **已知缺口（driven 超时的用户通知）**：执行器的*正常*超时——runtime 投来空/无 status 的 `worker_result_json` 合成回调——走 `dispatch_followup.sh` → I2 → req_dispatcher executor 回调 → `notify_user.sh`，用户**会**收到"处理超时未完成"。仅"子代理彻底死亡、一个回调都不来"这一子情形落到 `evict_stuck.sh`：它当前只把 executor 段 pending 合成 `stuck_evicted` 写 ledger 留痕（含 origin 已随 pending 携带），**不**主动推用户。出站推送通道已于 `2026-06-30.3` 落地为反向网关推 114 智伴；但本次未搭车修改 `evict_stuck.sh`，故该零回调缺口仍开放。闭合方式：在 `evict_stuck.sh` 对 `stage=executor` 且带 origin 的驱逐条目 best-effort 调 `notify_user.sh`(`STATUS=timeout`)。

一律**不自动重试**；重试靠用户重发需求。

## 7. 取舍（相对旧设计）

| 项 | 处置 |
|---|---|
| 独立 cron（本链路） | **去掉**，改 req_dispatcher 即时驱动；`RUN_SCHEDULED_ISSUE_CAMPAIGN`+cron 保留供他用 |
| `req_origin`/`req_result` note 闭环 | 本链路**不再依赖**（结果走回调）；执行器侧机器保留，driven 路径默认不发 req_result（开关控制） |
| git_issuer | **基本不改**：复用现有回调的 `project`/`issue_iid`/`issue_url`；driven 路径不再要它写 req_origin、不再要它通知用户 |
| req_dispatcher 身份 | 仍**不碰 GitLab**（不持 token、不调 glab、不解析 project），但从"薄派发器"升级为"编排器"：多了 git_issuer 回调→spawn executor、executor 回调→推用户两步 |

## 8. 各组件职责一览（新链路）

| 组件 | 职责 | 改动 |
|---|---|---|
| 企微用户 | 发需求（带 origin 元数据）/ 收结果 | — |
| 114 | 转发需求带 origin；投递 req_dispatcher 的 ack 与结果推送 | 需对齐推送通道 |
| **req_dispatcher** | 编排：spawn git_issuer → 路由 → spawn executor → 收结果 → 推用户 | **大改**（本设计核心） |
| git_issuer | 需求→建 issue→回调 {project,iid,url} | **基本不改**（复用现有回调） |
| **req_executor** | `RUN_SINGLE_ISSUE` 单次 issue 执行 + Phase 6 回调 req_dispatcher；配置自持 | **改**（新入口 + pin 配置 + Phase6 回调） |

## 9. 待对齐 / 开放项（与同事 / OpenClaw 维护者 / 部署）

1. **跨 agent spawn + 回调原语**：req_dispatcher→executor 的 spawn 工具名/参数、executor→req_dispatcher 的结果回调信封字段（`dispatcher_callback_target` 形态）——与现有 git_issuer spawn 同一待对齐项，见 [`../../../skills/requirement_dispatch/references/trigger_command.md`](../../../skills/requirement_dispatch/references/trigger_command.md)。
2. **req_dispatcher → 用户出站推送通道**（§4.5）：用 origin 把结果投回企微的确切机制。**B 方案最关键的新依赖**。
3. **执行器 GitLab token 注入方式**（§3.5）：pin 进 config vs 部署 env 注入；轮换策略。
4. **origin 元数据格式**：114 在需求文本里放 origin 的确切约定（沿用 result_notify_loop §3 设想）。
5. **路由表来源**（§4.4）：静态 config vs 动态发现；project→executor 映射的维护方。

未对齐前，脚本里这些点用占位 + 显式 `待对齐` 标注，不臆造工具名/字段名（沿用旧 spec 做法）。

## 10. 测试 / 验证

无 build / test runner。改动后：
- 所有 `*.sh` 过 `/opt/homebrew/bin/bash -n`。
- req_dispatcher 脚本（纯本地 state 操作）做本地冒烟：临时 `STATE_ROOT` 跑通 两段 record→drain→evict（含 stage 字段、origin 携带、二次匹配）。
- req_executor 的 `RUN_SINGLE_ISSUE` 配置合成做 `bash -n` + 字段合成单测（不跑 acpx，本机跑不了）。
- 每个非平凡改动走 `code-reviewer` 子代理审查循环至零问题；两侧各 bump SKILL_VERSION；两侧 Stop-hook sentinel。

## 11. 不做（YAGNI）

- 不做执行器中途取消/打断正在跑的 attempt（沿用：变更只在下一次 attempt 生效）。
- 不做 req_dispatcher 侧处理进度播报（只在终态推一次结果）。
- 不做自动重试。
- 不在第一版做"一个 executor 服务任意 project"（多 project 走路由表 + per-project 部署）。
