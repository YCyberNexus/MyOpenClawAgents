# req_dispatcher 主动端到端编排 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐 task 实现。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 把"企微需求→自动测试"链路从"建带标签 issue + 独立 cron 被动捞起"改为"req_dispatcher 链式 spawn git_issuer→req_executor、测试结果回流 req_dispatcher 并推回用户"。

**Architecture:** req_dispatcher 升级为编排器（仍不碰 GitLab），两段异步 spawn 各按 run_id 记 pending/回调 drain；req_executor 新增 `RUN_SINGLE_ISSUE_TEST` driven 入口（配置自持）+ Phase 6 结果回调；多 project 走路由表。设计稿：[`../specs/2026-06-29-req_dispatcher-active-orchestration-design.md`](../specs/2026-06-29-req_dispatcher-active-orchestration-design.md)。

**Tech Stack:** OpenClaw agent 部署工件（bash + jq + flock state ops + LLM-orchestrated SKILL prose）。无 build/test runner。验证 = `/opt/homebrew/bin/bash -n` + 临时 `STATE_ROOT` 本地 state 冒烟 + `code-reviewer` 子代理审查闸门。

## Global Constraints

- 本机 bash 一律用 `/opt/homebrew/bin/bash`（系统 /bin/bash 3.2.57 会误判）。
- 跨 agent spawn/callback/用户推送原语属**待对齐**：脚本里以"显式 gated 占位 + 记 ledger 留痕"实现，**不臆造**工具名/字段名（沿用现有 git_issuer spawn 在 SKILL prose 描述、references/trigger_command.md 标 ⚠️待对齐 的做法）。
- No-Fallback：脚本非零退出→读输出/分类/记录/停；不自动重试（spawn 失败仅"同 payload 3 次 2s 退避"）。
- best-effort 通知脚本（notify_dispatcher/notify_user）：通道未配置或发送失败一律 `exit 0` + 记 ledger，绝不打断主流程；仅配置形态写错才非零退出。
- 每个非平凡改动走 `code-reviewer` 子代理循环至零问题；改 `workspace-X/` 下 SOUL/AGENTS/USER/config/skills 即 bump 该侧 SKILL.md 的 `SKILL_VERSION`（今天 `2026-06-29.N`，已是 `.1` 则递增）；完成后写两侧 `.claude/.review-done-sha` sentinel。
- DRY/YAGNI/频繁提交（按用户节奏，commit 仅在用户要求时）。

## 共享接口契约（两侧必须逐字一致 —— 锁定于此）

**(I1) req_dispatcher → req_executor 的 `RUN_SINGLE_ISSUE_TEST` trigger 入参**（多行 key=value）：
```
RUN_SINGLE_ISSUE_TEST
project=<group/project 全名，git_issuer 回调透传；executor 的 dispatch_single_issue.sh 内部拆成 group+slug>
iid=<正整数>
correlation_id=<req_dispatcher 生成的关联 token>
dispatcher_callback_target=<回调目标，待对齐占位>
group=<可选>
```

**(I2) req_executor → req_dispatcher 的结果回调信封**（执行器 Phase 6 终态发出，一行紧凑 JSON）：
```json
{"correlation_id":"<回显 I1 的值>","iid":<int>,"project":"<group/project>","status":"done|failed|timeout","mr_url":<string|null>,"wiki_url":<string|null>,"reason":<string|null>}
```
`status` 取执行器 `final_status`（`done`/`failed`/`timeout`；`blocked` 不回调）。承载该 JSON 的跨 agent 回调信封字段名 = 待对齐。

**(I3) req_dispatcher `pending.json` entry 字段**（run_id 主键）：
```json
{"run_id":"...","stage":"git_issuer|executor","origin":{"channel":"..","user":"..","conversation":".."},"req_digest":"..","project":"..|null","iid":<int|null>,"correlation_id":"..|null","child_session_key":"..|null","spawned_at":<epoch_seconds>}
```

**(I4) 脚本入参 env 契约**（新增/变更，须与脚本实际读取一致）：
| 脚本 | 必填 env | 可选 env |
|---|---|---|
| `record_pending.sh`（改） | `STATE_ROOT`,`RUN_ID`,`STAGE` | `ORIGIN_JSON`,`PROJECT`,`IID`,`CORRELATION_ID`,`CHILD_SESSION_KEY`,`REQ_DIGEST` |
| `drain_pending.sh`（改） | `STATE_ROOT`,`RUN_ID` | `STAGE`,`OUTCOME`,`PROJECT`,`IID`,`ISSUE_URL`,`STATUS`,`MR_URL`,`REASON` |
| `evict_stuck.sh`（改） | `STATE_ROOT`,`STUCK_AFTER_MINUTES` | —（覆盖两 stage） |
| `route_project.sh`（新） | `PROJECT`,`ROUTING_FILE` | — →stdout 输出 executor agent 名或 `__NO_ROUTE__` |
| `notify_user.sh`（新） | `EVENT`(`result`/`failure`) | `USER_NOTIFY_CHANNEL`(空则 no-op),`ORIGIN_JSON`,`IID`,`STATUS`,`MR_URL`,`REASON` |
| `notify_dispatcher.sh`（新, req_executor 侧） | `CORRELATION_ID`,`IID`,`STATUS` | `DISPATCHER_CALLBACK_TARGET`(空则 no-op),`PROJECT`,`MR_URL`,`WIKI_URL`,`REASON` |

---

## 阶段 A：req_executor driven 入口（先做 —— 定下 I1/I2 信封形状）

### Task A1: `config/campaign_defaults.env`（pin 配置）

**Files:** Create `workspace-req_executor/config/campaign_defaults.env`；Modify `workspace-req_executor/config/README.md`。

**Produces:** 一份可 `source` 的 pin 配置，供 `dispatch_single_issue.sh`（A2）合成 campaign 字段。

- [ ] 写 `campaign_defaults.env`：`BRANCH=master` / `DEV_BRANCH=dev` / `HOURLY_ISSUE_QUOTA=1` / `MAX_CONCURRENT_SUBAGENTS=1` / `MAX_ACCOUNTS_PER_ISSUE=14` / `UI_ACCOUNTS_RELPATH=` / `ACPX_TIMEOUT_SECONDS=18000` / `RUN_TIMEOUT_SECONDS=18120` / `RESULT_BASENAME=ifp-result` / `DATA_BASENAME=ifp-data` / `REPO_PARENT_PATH=/data`，每项带注释；token 注入方式留显式注释块标 `待对齐`（pin 值 vs env 注入）。
- [ ] `config/README.md` 加一节说明 `campaign_defaults.env` 各字段与"driven 单测固定 quota=1/concurrency=1"。
- [ ] 验证：`/opt/homebrew/bin/bash -n` 不适用于 env，改用 `set -a && source config/campaign_defaults.env && set +a` 在临时 shell 跑通、echo 关键变量非空。
- [ ] Gate：code-review（trivial 可由主 agent 酌情）。

### Task A2: `dispatch_single_issue.sh`（解析 driven trigger + 合成 + 持久化关联）

**Files:** Create `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_single_issue.sh`。

**Consumes:** I1 入参；`config/gitlab.env`+`campaign_defaults.env`。
**Produces:** 合成出与 `RUN_SCHEDULED_ISSUE_CAMPAIGN`（`issue_iids=[iid]`、quota=1、concurrency=1）等价的 campaign env，把 `correlation_id`+`dispatcher_callback_target` 写进该 issue 的 `state.json`，再 `exec`/调既有 `dispatch_prepare_tick.sh` 主体。

- [ ] Step1 写脚本：`set -euo pipefail` → 校验 `project`/`iid`/`correlation_id` 必填（iid 正整数校验，仿 post_result_note.sh）→ `source gitlab.env`+`campaign_defaults.env` → 导出合成 env（`PROJECT/GROUP/GITLAB_TOKEN/BRANCH/DEV_BRANCH/ISSUE_IIDS=$iid/ISSUE_MIN_IID=$iid/ISSUE_MAX_IID=$iid/HOURLY_ISSUE_QUOTA=1/...`）→ 把 `{correlation_id,dispatcher_callback_target}` 经 jq 写入 `${ISSUE_ROOT}/issue-<iid>/dispatch_origin.json`（Phase 6 读）→ 调 `bash dispatch_prepare_tick.sh`。
- [ ] Step2 验证：`/opt/homebrew/bin/bash -n scripts/dispatch_single_issue.sh`。
- [ ] Step3 冒烟：临时 `STATE_ROOT`，桩掉 `dispatch_prepare_tick.sh`（PATH 前置假脚本只 echo env），断言合成 env 正确、`dispatch_origin.json` 内容 = 入参；缺 iid/非整数 iid 时非零退出。
- [ ] Gate：code-review。

### Task A3: `notify_dispatcher.sh`（Phase 6 结果回调，gated 占位）

**Files:** Create `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/notify_dispatcher.sh`。

**Consumes:** I4 env。**Produces:** I2 信封；best-effort 发往 `DISPATCHER_CALLBACK_TARGET`。

- [ ] Step1 写脚本：校验 `CORRELATION_ID`/`IID`/`STATUS`（status∈done/failed/timeout）→ `DISPATCHER_CALLBACK_TARGET` 空则 `echo no target; exit 0` → jq 拼 I2 JSON → **跨 agent send 占位**：以 `# TODO(待对齐): 实际跨 agent send 原语` 注释 + 当前实现把 JSON 追加到 `${STATE...}/log/dispatcher_callbacks.jsonl` 并 `exit 0`（留痕、不静默丢）；发送形态写错才 `exit 2`。
- [ ] Step2 验证：`bash -n`。
- [ ] Step3 冒烟：target 空 → no-op exit0；target 非空 → 落一行正确 JSON 到 log；status 非法 → 非零。
- [ ] Gate：code-review。

### Task A4: `dispatch_followup.sh` Phase 6 增结果回调

**Files:** Modify `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_followup.sh`（终态处，post_result_note 调用附近）。

**Consumes:** A3 的 `notify_dispatcher.sh`；A2 写的 `dispatch_origin.json`。

- [ ] Step1 在 Phase 6 终态（`final_status∈done/failed/timeout`）、drain/label/kill 之后，加：若 `dispatch_origin.json` 存在且含 `correlation_id`+`dispatcher_callback_target`，`set +e` 隔离、stdout→/dev/null 调 `notify_dispatcher.sh`（传 I4 env）；driven 路径下默认**跳过** `post_result_note.sh`（开关：有 dispatch_origin 即视为 driven）。
- [ ] Step2 验证：`bash -n scripts/dispatch_followup.sh`。
- [ ] Step3 冒烟：构造带/不带 `dispatch_origin.json` 两种 issue state，断言带 origin 时调用 notify_dispatcher（log 落行）、不带时不调用；notify_dispatcher 故意失败不影响 followup 退出码。
- [ ] Gate：code-review。

### Task A5: req_executor 契约同步（SKILL/references/SOUL/AGENTS/USAGE/config）+ bump

**Files:** Modify `skills/.../SKILL.md`、`references/trigger_command.md`、`references/state_schema.md`、`SOUL.md`、`AGENTS.md`、`docs/REQ_EXECUTOR_USAGE.md`、`config/README.md`。

- [ ] SKILL.md：description 增"三 trigger（scheduled/callback/single-issue）"；新增 §`RUN_SINGLE_ISSUE_TEST`（I1）与 §Phase6 dispatcher 回调（I2）；`allowed-tools` 视需要加跨 agent send 原语（占位）。bump `SKILL_VERSION` 到 `2026-06-29.2`（A 阶段同日二次，因前面 rename 已用 `.1`）。
- [ ] trigger_command.md：RUN_SINGLE_ISSUE_TEST 入参 + I2 回调信封，待对齐处标 ⚠️。
- [ ] state_schema.md：issue state 增 `dispatch_origin.json`（correlation_id/dispatcher_callback_target）；Phase6 回调步骤。
- [ ] SOUL.md/AGENTS.md：在已加的 "Pipeline role" 小节补"driven 单测入口 + 结果回调 req_dispatcher"。
- [ ] REQ_EXECUTOR_USAGE.md：新增 `RUN_SINGLE_ISSUE_TEST` 用法节。
- [ ] config/README.md：已在 A1 改，确认一致。
- [ ] Gate：code-review（契约一致性重点）。

---

## 阶段 B：req_dispatcher 编排器

### Task B1: pending 两段 state（record/drain/evict 改）

**Files:** Modify `workspace-req_dispatcher/skills/requirement_dispatch/scripts/{record_pending,drain_pending,evict_stuck}.sh`；`references/state_schema.md`。

**Produces:** I3 pending schema + I4 env。

- [ ] Step1 `record_pending.sh`：增 `STAGE`（必填，git_issuer/executor 校验）、`ORIGIN_JSON`/`PROJECT`/`IID`/`CORRELATION_ID`（可选）写入 entry（jq）。
- [ ] Step2 `drain_pending.sh`：增 `STAGE`/`PROJECT`/`IID`/`STATUS`/`MR_URL` 写 ledger；匹配不到仍写 `was_pending=false`。
- [ ] Step3 `evict_stuck.sh`：遍历两 stage 的 pending，超时各自合成 stuck、记 ledger、drain。
- [ ] Step4 验证：三脚本 `bash -n`。
- [ ] Step5 冒烟：临时 STATE_ROOT 跑 `record(git_issuer)→record(executor)→drain(executor)→evict`，jq 断言 pending/ledger 的 stage/origin/correlation 正确；缺 STAGE 非零。
- [ ] Step6 `references/state_schema.md` 同步 I3。
- [ ] Gate：code-review。

### Task B2: `route_project.sh` + `config/routing.env` + README

**Files:** Create `scripts/route_project.sh`、`config/routing.env`；Modify `config/README.md`、`config/dispatcher.env`。

- [ ] Step1 `routing.env`：注释 + 示例 `claw_gitlab/px_ifp_hulat_test=req_executor_ifp`；`dispatcher.env` 增 `ROUTING_FILE`/`USER_NOTIFY_CHANNEL`/`DISPATCHER_CALLBACK_TARGET`（后两者待对齐占位）。
- [ ] Step2 `route_project.sh`：读 `ROUTING_FILE`，按 `PROJECT` 精确查 → 命中输出 agent 名 exit0；未命中输出 `__NO_ROUTE__` exit0（由 SKILL 判 no-route 失败，脚本本身不报错）；文件缺失/格式错 exit2。
- [ ] Step3 验证：`bash -n`。
- [ ] Step4 冒烟：命中/未命中/文件缺失三例。
- [ ] Step5 README 记 routing 表与 no-route 语义。
- [ ] Gate：code-review。

### Task B3: `notify_user.sh`（推结果给 origin，gated 占位）

**Files:** Create `scripts/notify_user.sh`；Modify `config/README.md`。

- [ ] Step1 写脚本：`EVENT∈result/failure` 校验 → `USER_NOTIFY_CHANNEL` 空则 `exit 0`（记 ledger 留痕）→ 按 STATUS 拼用户文案（done/failed/timeout，文案同设计稿 §4.3）→ **推送占位**：`# TODO(待对齐): 企微回投/经114` + 当前落 `${STATE...}/log/user_notify.jsonl` exit0；通道形态写错 exit2。
- [ ] Step2 验证：`bash -n`。
- [ ] Step3 冒烟：channel 空 no-op、非空落行、EVENT 非法非零。
- [ ] Step4 README 记 `USER_NOTIFY_CHANNEL`。
- [ ] Gate：code-review。

### Task B4: req_dispatcher 契约（SKILL 三路径 + SOUL/AGENTS/USER/CLAUDE + references）+ bump

**Files:** Modify `skills/requirement_dispatch/SKILL.md`、`SOUL.md`、`AGENTS.md`、`USER.md`、`CLAUDE.md`、`references/trigger_command.md`、`references/state_schema.md`。

- [ ] SKILL.md：三路径——①接入（capture origin→spawn git_issuer→record stage=git_issuer→ack）；②git_issuer 回调（route_project→spawn executor RUN_SINGLE_ISSUE_TEST→record stage=executor→drain git_issuer；no-route/failed 推用户）；③executor 回调（按 run_id 匹配→notify_user→drain）。精确 env 行 + I1/I2/I4。bump `SKILL_VERSION` 到 `2026-06-29.2`。
- [ ] SOUL.md/AGENTS.md/USER.md/CLAUDE.md：身份从"薄派发器"改述为"编排器（仍不碰 GitLab）"；两段 spawn + 路由 + 推用户;明确"驱动 req_executor、收结果"。
- [ ] trigger_command.md：executor spawn（I1）+ executor 回调（I2）信封，待对齐 ⚠️。
- [ ] state_schema.md：已在 B1 改，确认一致。
- [ ] Gate：code-review（跨文件契约一致性重点）。

### Task B5: 集成对接文档更新

**Files:** Modify `docs/integration/result_notify_loop.md`、`docs/integration/gitissuer_contract.md`、`docs/integration/gitissuer_change_request.md`。

- [ ] result_notify_loop.md：顶部加状态横幅"本链路已改为主动编排（见 active-orchestration 设计稿），req_origin/req_result note 闭环在 driven 路径**不再使用**；执行器侧机器保留供 cron 路径"。不删正文（cron 路径仍可用）。
- [ ] gitissuer_contract.md：注明 driven 路径不再依赖 git_issuer 写 req_origin / 通知用户；继续复用其回调 `project`/`issue_iid`/`issue_url`。
- [ ] gitissuer_change_request.md：注明变更流程在主动编排下仍由 req_dispatcher 透传（基本不变），指向新设计稿。
- [ ] Gate：code-review。

---

## 阶段 C：整体验证

### Task C1: 全量静态检查 + 联合冒烟 + 对抗式审查 + 解除 sentinel

- [ ] `/opt/homebrew/bin/bash -n` 扫两侧所有改动/新增 `*.sh`。
- [ ] 联合冒烟：模拟一条需求的两段流（record git_issuer→drain→route→record executor→drain；executor 侧 single_issue 合成→followup 触发 notify_dispatcher），jq 断言 ledger 串得起来、correlation 全程一致。
- [ ] 对抗式 code-review 工作流（多视角：契约一致性 / no-fallback / flock 原子性 / 占位是否留痕不静默丢 / 两侧字段信封逐字一致 I1-I4 / SKILL_VERSION）。修至零阻断。
- [ ] 两侧各 bump 后 SKILL_VERSION 核对为 `2026-06-29.2`；写 `workspace-req_dispatcher/.claude/.review-done-sha` 与 `workspace-req_executor/.claude/.review-done-sha`。

---

## Self-Review（计划 vs 设计稿）

- **覆盖**：设计稿 §3（执行器改动）→A1-A5；§4（dispatcher 改动）→B1-B4；§4.4 路由→B2；§4.5 推送→B3；§6 失败→落在 SKILL prose（B4）+ 各脚本退出码；§7 取舍→B5；§9 待对齐→各脚本 gated 占位。无缺口。
- **占位扫描**：跨 agent 原语/推送通道为设计层"待对齐"，计划里以 gated-占位+留痕落地，非计划级 TBD。
- **类型/字段一致**：I1-I4 在头部锁定，A2/A3/A4/B1/B4 引用同名字段；executor 回调 `status`、pending `stage`、`correlation_id` 全链一致。
