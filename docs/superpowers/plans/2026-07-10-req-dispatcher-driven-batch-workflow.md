# req_dispatcher 受驱动批次工作流实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `req_dispatcher` 接受单 IID、IID 范围、OPEN 未完成和 OPEN 指定标签请求，并由 `req_executor` 以可恢复、默认三并发、跨批次公平轮转的方式执行任意规模冻结快照，同时逐条回推用户结果。

**Architecture:** `req_dispatcher` 是控制面，负责自然语言选择器、origin、批次镜像和逐条通知；`req_executor` 新增项目外的 agent 级调度器，负责 GitLab 快照、三个物理槽位、公平轮转和持久 outbox。现有项目 campaign 增加 `driven_topup` 模式，只接收 agent 调度器 grant，继续复用 worktree、attempt、标签、MR 与 Phase 6。

**Tech Stack:** OpenClaw AgentSkill Markdown、GNU Bash 5.3、`jq`、`glab`、`flock`、fake `glab`/fake `openclaw` shell tests。

## Global Constraints

- 不得在仓库中运行 `rm`；临时文件使用现有 retire/move 方式或测试进程退出后由系统清理。
- `req_dispatcher` 不得持有或传递 GitLab token；所有 GitLab 查询只在 `req_executor` 内进行。
- tracked 蓝区默认必须保留 GitLab host/protocol、token 注入契约、`/data` clone/state 根、callback 目标和 `10.64.5.104` 部署语义。
- 本地路径只能通过进程环境或忽略的 `*.local.env` 注入。
- 所有选择器只纳入 OPEN Issue；范围是闭区间；标签模式不排除终态标签；未完成模式排除 `pr`、`timeout`、`blocked`/`blocked-*`、`failed`/`failed-*`。
- 普通处理跳过 `pr`；只有明确“重跑/重新处理/重新执行”才设置 `force_rerun_pr=true`；`continue` 续跑，其他显式终态 fresh。
- executor agent 默认并发 `3`；多批次严格轮转；`reserved/preparing/running` 都占槽。
- 每个终态逐条通知；回调至少一次投递，使用稳定 `event_id` 幂等去重。
- 修改 `workspace-req_dispatcher` 后 bump `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`。
- 修改 `workspace-req_executor` 后 bump `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/SKILL.md`。

---

## 文件结构

### req_dispatcher

- `scripts/prepare_executor_issue_payload.sh`：把自然语言解析成兼容旧 `.iid` 的结构化 selector。
- `scripts/build_executor_batch_payload.sh`：只把无 token 的结构化 I1 文本发给 executor。
- `scripts/record_executor_batch.sh`：创建/更新轻量批次镜像。
- `scripts/apply_executor_batch_event.sh`：按 `event_id` 幂等接收 I3，更新计数并写通知待办。
- `scripts/drain_executor_batch_notifications.sh`：重试逐条用户通知。
- `scripts/env_paths.sh`：初始化 batch mirror/event/notification 状态文件。
- `SKILL.md` 与 references：定义 intake、I1、I3 和恢复路径。

### req_executor

- `scripts/scheduler_env.sh`：加载 `/data` 默认 pin、校验并初始化 agent 级状态。
- `scripts/create_driven_batch.sh`：验证 I1、分页查询 GitLab、原子写不可变快照。
- `scripts/reserve_driven_batch_items.sh`：严格轮转、物理互斥、发放空槽 grant。
- `scripts/record_driven_batch_launch.sh`：写 spawned/launch_failed/重试状态。
- `scripts/resolve_driven_repo_path.sh`：使用完整 `group/project` 解析无碰撞 clone 路径。
- `scripts/dispatch_driven_topup.sh`：把 agent grant 转为项目 campaign 的受控补位。
- `scripts/import_driven_handoff.sh`：释放项目锁后把 Phase 6 handoff 导入 agent outbox。
- `scripts/drain_driven_outbox.sh`：回投 dispatcher，收到 accepted ack 后标记 delivered。
- `dispatch_prepare_tick.sh`、`dispatch_followup.sh`、`_dispatch_lib.sh`：增加 driven owner/topup 和 terminal handoff，不改变 scheduled 默认行为。
- `dispatch_single_issue.sh`：兼容 shim，内部创建单 item batch。

---

### Task 1: dispatcher 结构化选择器与无 token I1

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/prepare_executor_issue_payload.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/build_executor_batch_payload.sh`
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_executor_issue_payload.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_build_executor_batch_payload.sh`

**Interfaces:**
- Produces selector JSON；例如范围固定为
  `{"type":"range","iid_min":100,"iid_max":250}`，其他类型只带各自定义的字段。
- 保留旧 `.iid`：仅 `single` 为数字，其他类型为 `null`。
- Produces I1 text：`RUN_DRIVEN_ISSUE_BATCH` + `batch_id/correlation_id/project/selector_*` + optional `branch`。

- [ ] **Step 1: 添加失败测试**

在现有解析测试中加入：

```bash
range_json="$(MESSAGE='处理 ai-infra/veqp_server_v3 的 issue #100 到 #250' bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh")"
jq -e '.status == "success" and .selector == {type:"range",iid_min:100,iid_max:250} and .iid == null' <<<"${range_json}"

unfinished_json="$(MESSAGE='处理 ai-infra/veqp_server_v3 中未完成的 issue' bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh")"
jq -e '.selector.type == "open_unfinished"' <<<"${unfinished_json}"

label_json="$(MESSAGE='处理 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh")"
jq -e '.selector == {type:"open_label",label:"pr"} and .force_rerun_pr == false' <<<"${label_json}"

rerun_json="$(MESSAGE='重新执行 ai-infra/veqp_server_v3 中 label 为 pr 的 issue' bash "${SKILL_DIR}/scripts/prepare_executor_issue_payload.sh")"
jq -e '.selector.type == "open_label" and .force_rerun_pr == true' <<<"${rerun_json}"
```

新 builder 测试断言输出包含 `selector_type=range`、`iid_min=100`、`iid_max=250`，且全文不含 `token`、`GITLAB_TOKEN`。

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_executor_issue_payload.sh
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_build_executor_batch_payload.sh
```

Expected: 第一条在缺 IID 处返回 failed；第二条因脚本不存在失败。

- [ ] **Step 3: 实现最小解析与 builder**

解析器最终输出字段固定为：

```jq
{
  status: $status,
  project: $project,
  iid: (if $selector.type == "single" then $selector.iid else null end),
  selector: $selector,
  force_rerun_pr: $force_rerun_pr,
  target_branch: $target_branch,
  issue_url: $issue_url,
  request_text: $request_text,
  reason: $reason
}
```

builder 使用 `jq -e` 校验 selector 形态后按类型输出字段；`range` 强制
`iid_min <= iid_max`，`open_label` 拒绝空标签，所有值拒绝换行和控制字符。

- [ ] **Step 4: 运行新旧解析测试**

Run: 上述两条命令。
Expected: 两条均输出 `ok`，原单 IID/URL/branch/恶意输入断言仍通过。

- [ ] **Step 5: 提交**

```bash
git add workspace-req_dispatcher/skills/requirement_dispatch/scripts/prepare_executor_issue_payload.sh workspace-req_dispatcher/skills/requirement_dispatch/scripts/build_executor_batch_payload.sh workspace-req_dispatcher/skills/requirement_dispatch/tests/test_prepare_executor_issue_payload.sh workspace-req_dispatcher/skills/requirement_dispatch/tests/test_build_executor_batch_payload.sh
git commit -m "新增：解析批量 Issue 选择器"
```

### Task 2: executor agent 级配置与状态初始化

**Files:**
- Modify: `workspace-req_executor/config/campaign_defaults.env`
- Modify: `workspace-req_executor/config/campaign_defaults.local.env.example`
- Modify: `workspace-req_executor/config/README.md`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/scheduler_env.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_scheduler_env.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_blue_deploy_config_sanity.sh`

**Interfaces:**
- Inputs: `EXECUTOR_SCHEDULER_ROOT`、`EXECUTOR_MAX_CONCURRENCY`。
- Defaults: `/data/req_executor/_scheduler` 与 `3`。
- Exports: `SCHEDULER_STATE_FILE`、`SCHEDULER_LOCK_FILE`、`BATCHES_ROOT`、`CALLBACK_INBOX`、`CALLBACK_OUTBOX`。

- [ ] **Step 1: 写失败测试**

```bash
out="$(CONFIG_DIR="${CONFIG_DIR}" bash "${SKILL_DIR}/scripts/scheduler_env.sh")"
jq -e '.max_concurrency == 3 and (.scheduler_root | endswith("/_scheduler"))' <<<"${out}"

if CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_MAX_CONCURRENCY=0 bash "${SKILL_DIR}/scripts/scheduler_env.sh"; then
  echo 'expected invalid concurrency to fail' >&2; exit 1
fi

jq -e '.max_concurrency == 7' <<<"$(CONFIG_DIR="${CONFIG_DIR}" EXECUTOR_MAX_CONCURRENCY=7 bash "${SKILL_DIR}/scripts/scheduler_env.sh")"
```

并断言初始化文件为：

```json
{"version":1,"round_robin_cursor":null,"active_jobs":{},"batch_order":[]}
```

- [ ] **Step 2: 运行确认失败**

Run: `/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_scheduler_env.sh`
Expected: `scheduler_env.sh` 不存在。

- [ ] **Step 3: 实现状态引导**

脚本只接受绝对路径、正整数并发；使用 `mkdir -p`、`flock` 和临时文件 + `mv`
初始化，绝不覆盖已有合法 state。stdout 只输出紧凑配置 JSON。

- [ ] **Step 4: 验证配置安全**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_scheduler_env.sh
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_blue_deploy_config_sanity.sh
```

Expected: 默认仍以 `/data` 开头，tracked 配置不含 `/Users/`、`/tmp/` 或测试 token。

- [ ] **Step 5: 提交**

```bash
git add workspace-req_executor/config workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/scheduler_env.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_scheduler_env.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_blue_deploy_config_sanity.sh
git commit -m "新增：初始化 executor 批次调度状态"
```

### Task 3: GitLab OPEN 快照与幂等建批

**Files:**
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/create_driven_batch.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_create_driven_batch_fake_glab.sh`

**Interfaces:**
- Consumes: I1 trigger on stdin；`scheduler_env.sh` exports；executor 自持 `GITLAB_TOKEN`。
- Produces: `{status,batch_id,matched_count,snapshot_digest,scheduler_status}`。
- Persists: `request.json`、不可变 `snapshot.json`、`state.json`。

- [ ] **Step 1: 写 fake glab 失败测试**

fake `glab` 按 `page=1/2/3` 返回两页 Issue 和一页空数组，数据至少覆盖：

```json
[
  {"iid":1,"state":"opened","labels":[]},
  {"iid":2,"state":"opened","labels":["pr"]},
  {"iid":3,"state":"opened","labels":["blocked-cc"]},
  {"iid":4,"state":"opened","labels":["smoke","timeout"]},
  {"iid":5,"state":"closed","labels":["smoke"]}
]
```

断言：

```bash
jq -e '.iids == [1]' "${BATCH_ROOT}/unfinished/snapshot.json"
jq -e '.iids == [2,4]' "${BATCH_ROOT}/label/snapshot.json"
jq -e '.iids == [2,3,4]' "${BATCH_ROOT}/range/snapshot.json"
```

同 batch ID 同 payload 返回相同 digest；改变 label 后重放必须失败。分页第二页
返回非零时不得出现可运行 `snapshot.json`。

- [ ] **Step 2: 运行确认失败**

Run: `/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_create_driven_batch_fake_glab.sh`
Expected: create script 不存在。

- [ ] **Step 3: 实现分页与原子快照**

GitLab 请求固定为：

```bash
glab api "projects/${PROJECT_URI}/issues?state=opened&per_page=100&page=${page}"
```

每页必须是 JSON array；合并后用 `jq` 按 IID 排序去重。快照先写临时目录，所有页和
digest 成功后一次 `mv` 到 `batches/<batch_id>`；失败目录移入 scheduler 的
`failed-intake/` 留证，不生成 runnable state。

- [ ] **Step 4: 运行测试**

Run: 上述 fake glab 测试。
Expected: 输出 `ok create driven batch snapshot`。

- [ ] **Step 5: 提交**

```bash
git add workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/create_driven_batch.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_create_driven_batch_fake_glab.sh
git commit -m "新增：冻结 GitLab Issue 批次快照"
```

### Task 4: 默认三槽位与严格公平轮转

**Files:**
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/reserve_driven_batch_items.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/record_driven_batch_launch.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_scheduler_fairness.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_scheduler_dedup.sh`

**Interfaces:**
- `reserve_driven_batch_items.sh` 输出 `{status,grants[],active_count,available_slots}`。
- grant 字段：`job_id,batch_id,snapshot_index,project,iid,branch,entry_mode,force_rerun_pr`。
- `record_driven_batch_launch.sh` 接受 `JOB_ID`、`STATUS=preparing|spawned|launch_failed|terminal`。

- [ ] **Step 1: 写公平性失败测试**

构造 batch A `[1,2,3]`、batch B `[10,11]`，并发 3，首次 reserve 必须为：

```json
[
  {"batch_id":"A","iid":1},
  {"batch_id":"B","iid":10},
  {"batch_id":"A","iid":2}
]
```

终结 A/1 后再次 reserve 必须取 B/11；重启脚本后 round-robin cursor 不丢。

- [ ] **Step 2: 写物理互斥失败测试**

batch A 与 C 同时含 `group/repo#7`：相同 branch/mode 时 C membership 为
`attached`；branch 不同则 C 保持 pending，直到 A 的 job terminal。

- [ ] **Step 3: 运行确认失败**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_scheduler_fairness.sh
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_scheduler_dedup.sh
```

Expected: reserve/record scripts 不存在。

- [ ] **Step 4: 实现锁内纯状态转换**

`scheduler.lock` 内只读取/写回 JSON，不调用 GitLab、clone、项目 wrapper 或 OpenClaw。
job 物理锁键为完整 `project + iid`；共享判断额外比较 branch/entry_mode/force flag。

- [ ] **Step 5: 验证并提交**

运行两条测试，预期均输出 `ok`，随后提交：

```bash
git add workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/reserve_driven_batch_items.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/record_driven_batch_launch.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_scheduler_fairness.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_scheduler_dedup.sh
git commit -m "新增：实现批次三槽位公平调度"
```

### Task 5: 完整 project 的无碰撞 clone 路径

**Files:**
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/resolve_driven_repo_path.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_single_issue.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_repo_path.sh`

**Interfaces:**
- Input: `PROJECT_FULL=group/project`、`REPO_PARENT_PATH=/data`。
- Output: legacy origin 匹配时复用 `/data/project`；否则使用 `/data/group/project`。
- 禁止修改 origin 不匹配的已有 clone。

- [ ] **Step 1: 写失败测试**

```bash
path_a="$(PROJECT_FULL='group-a/repo' REPO_PARENT_PATH="${ROOT}" bash "${SCRIPT}")"
path_b="$(PROJECT_FULL='group-b/repo' REPO_PARENT_PATH="${ROOT}" bash "${SCRIPT}")"
[ "${path_a}" != "${path_b}" ]
[[ "${path_a}" == "${ROOT}/group-a/repo" ]]
[[ "${path_b}" == "${ROOT}/group-b/repo" ]]
```

再创建 legacy `${ROOT}/repo/.git` 并 fake `git remote get-url origin`：目标匹配时返回
legacy；不匹配时返回新路径且 remote 日志无 `set-url`。

- [ ] **Step 2: 运行确认失败**

Run: `/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_repo_path.sh`
Expected: resolver 不存在。

- [ ] **Step 3: 实现安全路径解析**

校验完整 project 每段仅含 `[A-Za-z0-9._-]`；先检查 legacy origin，只有规范化后的
`<protocol>://<host>/<group>/<project>.git` 完全匹配才复用，否则返回嵌套新路径。

- [ ] **Step 4: 运行路径与旧 single 测试**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_repo_path.sh
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_dispatch_single_issue_issue_url.sh
```

Expected: 两者通过。

- [ ] **Step 5: 提交**

```bash
git add workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/resolve_driven_repo_path.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_single_issue.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_repo_path.sh
git commit -m "修复：按完整 project 隔离执行仓库"
```

### Task 6: 项目 campaign driven_topup 与 owner lease

**Files:**
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_driven_topup.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_prepare_tick.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_dispatch_driven_topup.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_campaign_owner_lease.sh`

**Interfaces:**
- Consumes one or more scheduler grants；reads current project pending。
- Produces existing `dispatch_entries[]` envelope plus `job_id/batch_id` metadata。
- `campaign_state.dispatch_owner={mode:"driven|scheduled",owner_id,leased_at}`。

- [ ] **Step 1: 写 pending 补位失败测试**

预置项目 state：pending IID 1；grant IID 2；`max_concurrent_subagents=2`。断言 topup
返回 IID 2 的一个 dispatch entry，且 state 仍保留 IID 1，不产生
`scope_evicted_outside_trigger_range`。

- [ ] **Step 2: 写 owner 失败测试**

预置 `dispatch_owner.mode=driven` 且仍有 pending，调用 scheduled tick 应返回
`busy_owned_by_driven`，state/digest 不变；反向同理。

- [ ] **Step 3: 运行确认失败**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_dispatch_driven_topup.sh
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_campaign_owner_lease.sh
```

Expected: topup 脚本不存在或旧 waiting gate 返回 `waiting_for_callbacks`。

- [ ] **Step 4: 实现显式模式分支**

旧 scheduled 路径保持字节级默认；仅当 `dispatch_mode=driven_topup` 时：

```jq
.issue_iids_whitelist = (($current_pending + $grant_iids) | unique | sort)
| .dispatch_owner = {mode:"driven",owner_id:$owner_id,leased_at:$now}
```

waiting gate 改为比较当前 pending 数与 grant 后容量，只准备 grant IID；锁外不做
agent scheduler 写操作。

- [ ] **Step 5: 运行回归并提交**

除两条新测试外运行现有 `test_dispatch_single_issue_minimal_config.sh` 和
`test_phase6_cleanup_preserves_terminal_sessions.sh`；全部通过后提交：

```bash
git add workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_driven_topup.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_prepare_tick.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_dispatch_driven_topup.sh workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_campaign_owner_lease.sh
git commit -m "新增：支持项目 campaign 安全补位"
```

### Task 7: Phase 6 handoff 与持久 outbox

**Files:**
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_followup.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/import_driven_handoff.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/drain_driven_outbox.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_callback_outbox.sh`

**Interfaces:**
- Project handoff: `{event_id,job_id,memberships[],project,iid,status,mr_url,reason}`。
- Outbox entry per membership：稳定 `event_id/batch_id/snapshot_index`。
- Dispatcher accepted ack：
  `{"status":"accepted","event_id":"reqd-batch-1:snapshot-0:terminal-1"}`。

- [ ] **Step 1: 写发送失败恢复测试**

fake `openclaw` 第一次退出 23，第二次返回 accepted ack。第一次 drain 后 outbox 文件仍
存在且 `delivered_at=null`；第二次后 `delivered_at` 为 epoch，两个请求 body 的
`event_id` 完全相同。

- [ ] **Step 2: 写锁边界测试**

fake importer 在 `dispatch_followup.sh` 项目锁释放前被调用时主动失败；断言实际调用只
发生在 followup 完成项目 state 写入之后。

- [ ] **Step 3: 运行确认失败**

Run: `/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_callback_outbox.sh`
Expected: importer/outbox scripts 不存在。

- [ ] **Step 4: 实现 handoff/outbox**

Phase 6 只在项目目录原子写 handoff；外层 orchestrator 随后调用 importer。outbox
发送脚本严格解析 `run_agent_turn`/OpenClaw 结果，只有 accepted ack 匹配 event_id
才标记 delivered；失败只记录 attempts/last_error。

- [ ] **Step 5: 运行回调回归并提交**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_driven_callback_outbox.sh
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_notify_dispatcher_openclaw.sh
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_phase6_cleanup_preserves_terminal_sessions.sh
```

Expected: 全部通过。随后提交相关文件，消息为 `新增：持久化 executor 批次结果回调`。

### Task 8: dispatcher 批次镜像、I3 去重与通知待办

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/env_paths.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/record_executor_batch.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/apply_executor_batch_event.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/scripts/drain_executor_batch_notifications.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_batch_state.sh`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_batch_event_notifications.sh`

**Interfaces:**
- Batch mirror 不含 IID 数组：`batch_id,executor_agent,origin,matched_count,terminal_count,status`。
- Event apply stdout：`accepted|duplicate|unknown_batch` + same event_id。
- Notification item：`event_id,origin,project,iid,status,mr_url,reason,attempts,delivered_at`。

- [ ] **Step 1: 写状态失败测试**

记录 matched_count=250 后断言 mirror 文件不含 `snapshot` 或 `.iids`；同 batch ID
相同 digest 幂等，不同 digest 失败。

- [ ] **Step 2: 写事件/通知失败测试**

同一 event JSON apply 两次：第一次 accepted 并 terminal_count=1，第二次 duplicate 且
terminal_count 仍为 1。fake notify 首次失败时通知待办保留，第二次成功后标 delivered。

- [ ] **Step 3: 运行确认失败**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_batch_state.sh
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_batch_event_notifications.sh
```

Expected: 新脚本不存在。

- [ ] **Step 4: 实现小状态与通知重试**

所有写入与旧 pending/queue 共用现有 `${LOCK_FILE}`；事件 ledger append 和 mirror 更新在
同一临界区。notify 调用在锁外；成功后重新加锁按 event_id 标记 delivered。

- [ ] **Step 5: 运行并提交**

新测试与 `test_notify_user_reply_agent.sh` 全部通过后提交，消息为
`新增：记录批次结果并逐条通知用户`。

### Task 9: OpenClaw 编排契约、single shim 与端到端流

**Files:**
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`
- Modify: `workspace-req_dispatcher/SOUL.md`
- Modify: `workspace-req_dispatcher/AGENTS.md`
- Modify: `workspace-req_dispatcher/USER.md`
- Modify: `workspace-req_dispatcher/CLAUDE.md`
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/references/trigger_command.md`
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/references/state_schema.md`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/SKILL.md`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_single_issue.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_driven_batch_simulated_flow.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_single_issue_batch_shim.sh`

**Interfaces:**
- Dispatcher path A batch：parse -> route -> record mirror -> `RUN_DRIVEN_ISSUE_BATCH`。
- Executor path D：create batch -> reserve/topup/spawn -> record -> outbox drain。
- Dispatcher I3：apply event -> accepted ack -> notification drain。
- Recovery：`RUN_EXECUTOR_BATCH_TICK`；旧 queue 非空时新 batch 为 waiting_for_legacy_drain。

- [ ] **Step 1: 写模拟流失败测试**

fake executor 返回 matched_count=3；fake 三条 I3 含 done/skipped/timeout；断言 dispatcher
发送无 token I1、记录 3、逐条通知 3 次、重复 done event 不产生第四次通知。

- [ ] **Step 2: 写 single shim 失败测试**

旧 `RUN_SINGLE_ISSUE project=group/repo iid=42` 必须生成稳定单 item batch request，
并进入 agent scheduler，而不是合成独立 `max_concurrent_subagents=1` campaign。

- [ ] **Step 3: 运行确认失败**

Run:

```bash
/opt/homebrew/bin/bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_driven_batch_simulated_flow.sh
/opt/homebrew/bin/bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_single_issue_batch_shim.sh
```

Expected: 新路径未定义。

- [ ] **Step 4: 更新薄 orchestrator 契约**

SKILL 必须只列固定 wrapper 调用和 JSON 分支；不得让 LLM 自己查询 GitLab、展开 IID、
手改 scheduler state 或并发调用多个 `RUN_SINGLE_ISSUE`。executor 的
`sessions_spawn` 仍逐个等待 ack，并使用 wrapper 返回的 `payload_path`。

- [ ] **Step 5: 运行端到端与旧协议回归后提交**

额外运行 dispatcher queue/run_agent tests 与 executor single/notify tests。全部通过后
提交，消息为 `重构：接入受驱动 Issue 批次协议`。

### Task 10: 版本、全量验证与部署文档

**Files:**
- Modify: `workspace-req_dispatcher/config/README.md`
- Modify: `workspace-req_executor/config/README.md`
- Modify: `workspace-req_executor/docs/REQ_EXECUTOR_USAGE.md`
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`（版本）
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/SKILL.md`（版本）

**Interfaces:**
- Dispatcher 版本按当日已有 N 递增。
- Executor 版本按当日已有 N 递增。
- 部署周期触发固定为 `RUN_EXECUTOR_BATCH_TICK`，建议一分钟。

- [ ] **Step 1: 更新部署说明和版本**

记录默认 `EXECUTOR_MAX_CONCURRENCY=3`、`EXECUTOR_SCHEDULER_ROOT=/data/req_executor/_scheduler`、
local env 覆盖方法、旧 queue 排空顺序、周期 tick 与 rollback 注意事项。

- [ ] **Step 2: Shell 语法验证**

Run:

```bash
find workspace-req_dispatcher/skills/requirement_dispatch/scripts workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts -type f -name '*.sh' -print0 | xargs -0 -n1 /opt/homebrew/bin/bash -n
```

Expected: exit 0，无输出。

- [ ] **Step 3: 运行两个工作区全部 shell 测试**

Run:

```bash
for t in workspace-req_dispatcher/skills/requirement_dispatch/tests/test_*.sh; do /opt/homebrew/bin/bash "$t" || exit 1; done
for t in workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_*.sh; do /opt/homebrew/bin/bash "$t" || exit 1; done
```

Expected: 每个测试输出 `ok`，总退出码 0。

- [ ] **Step 4: 配置与泄漏检查**

Run:

```bash
git diff --check
git diff --cached --check
rg -n '/Users/|/private/tmp|gitlab\.example|test-token|local-session' workspace-req_dispatcher workspace-req_executor --glob '!*.local.env' --glob '!tests/**'
```

Expected: diff check 通过；`rg` 不出现本机路径、测试 token 或临时 endpoint。已存在的
文档示例域名须人工确认不是本次新增。

- [ ] **Step 5: 最终提交**

```bash
git add workspace-req_dispatcher workspace-req_executor docs/superpowers/plans/2026-07-10-req-dispatcher-driven-batch-workflow.md
git commit -m "新增：支持超长 Issue 批次公平执行"
```

提交前再次确认 `.superpowers/`、任何 `*.local.env`、运行时 snapshot/state 和测试临时目录
均未 staged。
