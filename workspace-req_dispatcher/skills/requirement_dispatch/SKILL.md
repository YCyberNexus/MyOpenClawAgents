---
name: requirement_dispatch
description: "[SKILL_VERSION=2026-07-06.2] Orchestrate the ZhiBan/OpenClaw requirement → GitLab issue → req_executor pipeline from the 104 side. Intake supports either a blue-zone GitLab wiki URL or the legacy free-text requirement with explicit `group/project`: wiki intake uses `scripts/prepare_wiki_downstream_payloads.sh` to parse the wiki URL, fetch wiki Markdown with read-only `WIKI_GITLAB_*` pins when needed, split the document into requirement items, and compose one git_issuer payload per item; legacy intake uses `scripts/prepare_downstream_payloads.sh`. req_dispatcher then calls blue-zone `git_issuer` through `scripts/run_agent_turn.sh`, routes every returned `group/project` to `DEFAULT_EXECUTOR_AGENT` unless `routing.env` has a project-specific override, builds `RUN_SINGLE_ISSUE` with `scripts/build_executor_payload.sh`, records executor pending, receives `RUN_EXECUTOR_RESULT_CALLBACK`, and pushes conclusions back to the originating user without propagating executor Wiki evidence links. req_dispatcher may read GitLab wiki pages only; it must not create issues, write labels/notes, or run issue work directly. Main helpers: source_dispatcher_env.sh, capture_origin.sh, prepare_wiki_downstream_payloads.sh, prepare_downstream_payloads.sh, run_agent_turn.sh, build_executor_payload.sh, next_correlation_id.sh, find_pending.sh, record_pending.sh, drain_pending.sh, evict_stuck.sh, route_project.sh, notify_user.sh, ops_notify.sh."
allowed-tools: Bash, Read
---

# Requirement Dispatch Skill

这是一个 **端到端编排契约**。`req_dispatcher` 把 114 转发来的需求主动驱动整条「需求 → 自动处理」链路：入口现在优先支持智伴给出的蓝区 GitLab wiki URL，使用 `scripts/prepare_wiki_downstream_payloads.sh` 解析 wiki 对应的 `group/project`、只读拉取 wiki Markdown、拆分需求并生成一组适合 `git_issuer` 的建单消息；若消息不含 wiki URL，则沿用 `scripts/prepare_downstream_payloads.sh` 处理旧自由文本需求（要求文本里明确 GitLab `group/project`）。随后通过 `scripts/run_agent_turn.sh` 调用蓝区 `git_issuer` 建 GitLab issue；拿到最后一行 JSON 后按 project 选择执行器（所有合法 `group/project` 默认走 `DEFAULT_EXECUTOR_AGENT`，`routing.env` 只做专属覆盖）；再用 `scripts/build_executor_payload.sh` 生成 `RUN_SINGLE_ISSUE` 触发消息并调用目标执行器；最后收执行器结果回调、把结论推回发起需求的企微用户。所有确定性的 state 写入（pending 记录、drain、超时驱逐）、消息准备与本地决策（wiki 拆分、路由查表、推送留痕）都在 `scripts/` 下 flock 保护或 best-effort 的 shell 脚本里；LLM 只做脚本干不了的事：按脚本契约组织多条建单/执行器调用、读执行器回调、可选 ops 通知。

**职责边界（HARD）**：身份从「薄派发器」升级为「编排器」，但**仍不写 GitLab**——不得用任何 token 去建 issue、打标签、写 note、跑 issue；建 issue 是 `git_issuer` 的事，跑 issue 是 `req_executor` 的事。新 wiki 入口只允许用 `WIKI_GITLAB_*` 只读配置拉取 wiki 页面内容。编排器可以做受控入口分析：解析 wiki URL、拆分 wiki 文档、剥离 114/origin 包装、从旧自由文本中提取明确写出的 `group/project`、生成下游消息；但不能语义猜测项目，不能替代 `git_issuer` 的建单/校验职责，issue 事实仍以 `git_issuer` 返回 JSON 为准。编排器多做三步：入口分析并编辑下游消息；git_issuer 成功 → 路由 + 调用 executor；executor 回调 → 推用户结论。不去重；git_issuer / executor 返回失败均不自动重试业务（重试由用户重发需求）。详见 [`../../SOUL.md`](../../SOUL.md) §Global Rules 与下方 §No-Fallback。

state 与磁盘布局（executor pending、git_issuer 审计 stage、I3 entry）：[`references/state_schema.md`](references/state_schema.md)。`run_agent_turn.sh` 调用契约、git_issuer JSON 字段→drain env 映射、executor RUN_SINGLE_ISSUE(I1) 入参与 executor 结果回调(I2) 信封：[`references/trigger_command.md`](references/trigger_command.md)。git_issuer 的产出/变更规格（跨团队对接文档，orchestrator 运行时不必读）：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)。

## 路径判定

orchestrator（固定 session `agent:req_dispatcher:main`）每次被唤醒先判这次是哪一路：

- 收到**结构化结果回调**且来自 **req_executor**（I2 信封带 `correlation_id`/`status`，trigger 名见 trigger_command.md）→ **executor 回调路径**（路径 B）。
- 否则（114 投来的需求消息，可能含 wiki URL 或旧自由文本）→ **接入路径**（路径 A）。

## 路径 A：接入路径（需求消息进来）

1. **取需求原文 + capture origin**：114 经 `agent run --agent req_dispatcher "<需求原文>" --deliver` 投来。先保留原文供 origin 捕获和消息准备使用。调用 `capture_origin.sh` 只提取回推元数据：优先读 OpenClaw 网关/运行时提供的结构化来源（如 `OPENCLAW_DELIVER_ORIGIN_JSON`、`OPENCLAW_SOURCE_AGENT`、`OPENCLAW_SOURCE_SESSION` 等），其次才读需求文本里的显式 `[origin] ...` 行；这是 req_dispatcher 自己回推结果用的，**不是**业务需求解析。拿不到则 origin 留空（`ORIGIN_JSON` 不传，entry 里为 `null`），不阻断主流程；后续 `notify_user.sh` 会把空/null/非 object origin 视为手动入口，只留 ledger/log，不调用 114。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   MESSAGE="<需求原文>" \
   bash scripts/capture_origin.sh
   ```

   stdout 若非空即为紧凑 `origin_json`，形如 `{"channel":"..","user":"..","conversation":"..","reply_agent":".."}`；其中 `reply_agent` 是 114 上接收终态结果的 agent 名。只有该值是合法 JSON object 时，用户结果推送才允许出站到 114。

2. **准备下游消息（wiki 优先，旧自由文本回退）**：

   - 若需求文本包含 GitLab wiki URL（`http(s)://<host>/<group>/<project>/-/wikis/<slug>`），调用 `prepare_wiki_downstream_payloads.sh`。它会解析 wiki URL 对应的 project、用只读 `WIKI_GITLAB_*` 配置拉取 wiki Markdown（本地测试可用 `WIKI_CONTENT` 注入跳过网络）、按 Markdown 标题/编号块拆分需求，并输出一组 `git_issuer_payloads`。`status=failed` 表示 wiki URL、读取或拆分失败，**不要调用 git_issuer**；应推用户失败说明并结束本路径。

     ```bash
     cd "<SKILL_DIR 绝对路径>" && \
     source scripts/source_dispatcher_env.sh && \
     MESSAGE="<需求原文>" FETCH_WIKI=1 \
     bash scripts/prepare_wiki_downstream_payloads.sh
     ```

     成功输出形如：

     ```json
     {"status":"success","project":"claw_gitlab/px_ifp_hulat_test","wiki_url":"http://.../-/wikis/product/requirements","wiki_slug":"product/requirements","requirements":[{"ordinal":1,"title":"Login flow","body":"...","wiki_url":"...","wiki_section":"Login flow"}],"git_issuer_payloads":["CREATE_GITLAB_ISSUE\nrepo=claw_gitlab/px_ifp_hulat_test\nsource=req_dispatcher_wiki\n..."],"reason":null}
     ```

   - 若消息不含 wiki URL，调用 `prepare_downstream_payloads.sh` 对旧自由文本做受控入口分析：剥离 114 包装和 `[origin]`/`origin={...}` 行，要求文本里明确出现 GitLab `group/project`，并生成单条给 `git_issuer` 的标准化消息。`status=failed` 表示信息不足或形态不合格，**不要调用 git_issuer**；应推用户失败说明并结束本路径。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   MESSAGE="<需求原文>" \
   bash scripts/prepare_downstream_payloads.sh
   ```

   成功输出形如：

   ```json
   {"status":"success","project":"ai-infra/veqp_server_v3","requirement_text":"开发虚拟机台状态机...","git_issuer_payload":"CREATE_GITLAB_ISSUE\nrepo=ai-infra/veqp_server_v3\n...","reason":null}
   ```

   失败输出形如：

   ```json
   {"status":"failed","project":null,"requirement_text":"开发虚拟机台状态机...","git_issuer_payload":null,"reason":"需求文本未包含可识别的 GitLab project（格式 group/project）"}
   ```

   失败处置：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   EVENT="failure" ORIGIN_JSON="<origin_json 或空>" \
   REASON="<prepare_downstream_payloads.sh reason>" \
   bash scripts/notify_user.sh
   ```

   然后返回 `{path:"intake", outcome:"rejected", reason:"<reason>"}`。这不是下游失败，不写 pending。

   后续步骤统一按 payload 列表处理：wiki 成功时遍历 `.git_issuer_payloads[]`；旧自由文本成功时把 `.git_issuer_payload` 当成长度为 1 的列表。每个 payload 独立建 issue、路由并启动 executor。wiki 拆出的多个条目顺序处理，不并发建单。

3. **stuck 兜底**（先跑，回收泄漏的 pending；覆盖两段 git_issuer/executor）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   bash scripts/evict_stuck.sh
   ```

   其 stdout `evicted <N> stuck pending`：若 `N > 0`，**可选 ops 通知**（见 §可选 ops 通知，`EVENT=stuck_evicted COUNT=<N>`）。

4. **调用蓝区 `git_issuer`**：用 `scripts/run_agent_turn.sh` 包装 `openclaw agent`。payload 是第 2 步生成的当前建单消息：wiki 入口为 `.git_issuer_payloads[n]`，旧自由文本入口为 `.git_issuer_payload`；不要把 114 原文直接发给 git_issuer。该脚本返回结构化 envelope：`{status,run_id,child_session_key,exit_code,worker_result_json,raw_output}`；`worker_result_json` 是 git_issuer 最后一行紧凑 JSON（成功时含 `project`/`issue_iid`/`issue_url`）。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   TARGET_AGENT="${GIT_ISSUER_AGENT}" \
   AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}" \
   bash scripts/run_agent_turn.sh <<'EOF'
   <当前 git_issuer payload>
   EOF
   ```

   默认 session key 由 `run_agent_turn.sh` 自动生成：`agent:${TARGET_AGENT}:main`。不要手写 `agent:…main`、`agent:<target>:main` 这类占位符；脚本会拒绝包含省略号或尖括号的 session key。
   `run_agent_turn.sh` 会在等待下游 OpenClaw agent 时定期向 stderr 输出 heartbeat，stdout 仍只保留最终 JSON envelope。若 tool 返回“仍在运行”，必须继续 poll 到进程完成并读取最终 stdout，不得因为暂时无新输出就 kill。

   - **失败重试**（no-fallback）：若 envelope `status=failed`，同 payload 最多 3 次、2s 固定退避。三次仍失败 → 视为 `launch_failed`：调 `drain_pending.sh`（`OUTCOME=launch_failed`、`STAGE=git_issuer`、`REASON=<最后一次 raw_output>`、`RUN_ID="<最后一次 envelope.run_id>"`）写 ledger，不写 pending；随后可选 ops 通知。本路径结束。
   - **成功但 `worker_result_json` 为空/非对象** → 视为 `failed`，推用户"建 issue 失败：git_issuer 未返回有效 JSON"并 drain git_issuer 审计行。

5. **记录 git_issuer 审计 stage**：拿 envelope 的 `run_id` / `child_session_key` 记一条 `STAGE=git_issuer`，随后在成功收尾时 drain。它是本轮审计键，不要求蓝区 git_issuer 回显任何 token。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   RUN_ID="<git_issuer envelope.run_id>" STAGE="git_issuer" \
   ORIGIN_JSON="<origin_json 或不传>" \
   CHILD_SESSION_KEY="<git_issuer envelope.child_session_key>" \
   REQ_DIGEST="<当前需求条目正文前80字>" \
   bash scripts/record_pending.sh
   ```

6. **解析 git_issuer 结果 JSON**：成功（`status=success`，带 `project`、`issue_iid`、`issue_url`）进入路由；失败（`status=failed`，带 reason）推用户"建 issue 失败" + drain git_issuer stage，本路径结束。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   EVENT="failure" ORIGIN_JSON="<取自 pending 的 origin 或空>" \
   REASON="<git_issuer 失败原因>" \
   bash scripts/notify_user.sh

   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   RUN_ID="<run_id>" OUTCOME="failed" STAGE="git_issuer" \
   REASON="<git_issuer 失败原因>" \
   bash scripts/drain_pending.sh
   ```

   随后**可选 ops 通知**（`EVENT=git_issuer_failed RUN_ID=<run_id> REASON=<失败原因>`）。**不自动重试**。
7. **git_issuer 成功** → **按 project 路由选 executor**：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   PROJECT="<git_issuer JSON 的 project>" \
   ROUTING_FILE="${ROUTING_FILE:-}" \
   DEFAULT_EXECUTOR_AGENT="${DEFAULT_EXECUTOR_AGENT}" \
   bash scripts/route_project.sh
   ```

   - stdout 是 executor agent 名 → 进第 7 步。
   - stdout 是 `__NO_ROUTE__` → **默认执行器未配置且无覆盖路由**：推用户 + ledger + ops 通知 + drain git_issuer 段，本路径结束。蓝区默认配置下，所有合法 `group/project` 都应命中 `DEFAULT_EXECUTOR_AGENT`，不应走到此分支。
     - 推用户：`EVENT="failure" ORIGIN_JSON="<origin>" IID="<issue_iid>" REASON="该 project 未接入执行器" bash scripts/notify_user.sh`。
     - drain：`RUN_ID="<run_id>" OUTCOME="failed" STAGE="git_issuer" PROJECT="<project>" IID="<issue_iid>" ISSUE_URL="<issue_url>" REASON="no_route" bash scripts/drain_pending.sh`。
     - 可选 ops 通知：`EVENT=git_issuer_failed RUN_ID=<run_id> REASON=no_route`（复用 ops 失败枚举留痕）。
   - 脚本 `exit 2`（project 不是 `group/project`、`ROUTING_FILE` 缺失/格式错）→ **部署期或 git_issuer 返回形态错误**：按 No-Fallback 读 stderr、分类、记录、**停**（不当成 no-route，不臆造投递）。
8. **调用 `<executor>` RUN_SINGLE_ISSUE（I1）**：先生成 `correlation_id`，再用 `build_executor_payload.sh` 生成目标 executor 的触发文本，最后用 `run_agent_turn.sh` 调目标 executor。I1 入参：`project=<project>`、`iid=<issue_iid>`、`correlation_id=<correlation_id>`、`dispatcher_callback_target=${DISPATCHER_CALLBACK_TARGET}`（可选 `group`）。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   bash scripts/next_correlation_id.sh
   ```

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   PROJECT="<project>" IID="<issue_iid>" \
   CORRELATION_ID="<correlation_id>" \
   DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET}" \
   bash scripts/build_executor_payload.sh
   ```

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   TARGET_AGENT="<route_project.sh stdout>" \
   AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}" \
   bash scripts/run_agent_turn.sh <<EOF
   <build_executor_payload.sh stdout>
   EOF
   ```

   - **失败重试**（no-fallback）：若 envelope `status=failed`，同 payload 最多 3 次、2s 固定退避。三次仍失败 → `launch_failed`：推用户"已建 issue #<iid> 但未能启动处理"（`EVENT="failure" ORIGIN_JSON="<origin>" IID="<issue_iid>" REASON="启动执行失败"`）→ drain git_issuer 段（`OUTCOME=launch_failed STAGE=git_issuer PROJECT=<project> IID=<issue_iid>`）→ 可选 ops 通知。本路径结束（issue 已建，executor 段从未进 pending）。
9. **executor 调用成功** → 拿到 wrapper 返回的 `run_id2`（+ `child_session_key2`）。记 pending（**新 run_id2 主键**、`STAGE=executor`、携带 origin/project/iid/correlation_id），等待执行器后续 `RUN_EXECUTOR_RESULT_CALLBACK`。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   RUN_ID="<run_id2>" STAGE="executor" \
   ORIGIN_JSON="<取自 git_issuer 段 pending 的 origin 或空>" \
   PROJECT="<project>" IID="<issue_iid>" CORRELATION_ID="<correlation_id>" \
   CHILD_SESSION_KEY="<child_session_key2>" REQ_DIGEST="<当前需求条目正文前80字 或空>" \
   bash scripts/record_pending.sh
   ```

10. **drain git_issuer 段**（成功收尾该段；executor 段已另起新 pending）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   RUN_ID="<run_id>" OUTCOME="success" STAGE="git_issuer" \
   PROJECT="<project>" IID="<issue_iid>" ISSUE_URL="<issue_url>" \
   bash scripts/drain_pending.sh
   ```

11. **回最小受理 ack** 给 114（文案见 [`../../USER.md`](../../USER.md)，如"需求已受理，正在创建 issue 并自动处理，结果稍后通知"），返回 `waiting_for_executor_callback`。issue 创建和 executor 启动已经完成；处理结果仍经 executor 回调异步返回。

## 路径 B：executor 回调路径（执行结果回来 → 推用户）

1. **解析 executor 执行结果回调（I2 信封）**：`RUN_EXECUTOR_RESULT_CALLBACK` 消息里 `worker_result_json=<I2>`，I2 为 `{correlation_id, iid, project, status: done|failed|timeout, mr_url, reason}`；若旧 executor 仍携带 `wiki_url`，req_dispatcher 忽略它。如果运行时还带 executor `run_id`，优先使用该 `run_id`；本地 `openclaw agent` 回投形态不带 `run_id` 时，使用 I2 的 `correlation_id` 反查 pending。
2. **匹配 executor 段 pending（主键 = `run_id`，回调缺 `run_id` 时按 `correlation_id` 反查）**：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   RUN_ID="<runtime run_id 或空>" CORRELATION_ID="<I2 correlation_id>" \
   bash scripts/find_pending.sh
   ```

   找到 entry 后取其 `run_id` 作为 drain 的 `RUN_ID`。若同时有 runtime `run_id` 与 I2 `correlation_id`，**`correlation_id` 作二次校验**（回调里的 `correlation_id` 须 = entry 的 `correlation_id`，防 run_id 错配；不一致则记一条紧凑告警并以 run_id 为准 drain，不臆造）。
3. **按 status 推用户结论**（文案见 notify_user.sh；done→"#<iid> 已处理完成，MR：<mr_url>"，failed→"#<iid> 处理未通过：<reason>"，timeout→"#<iid> 处理超时未完成，已停放待人工处理"）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   EVENT="result" STATUS="<done|failed|timeout>" \
   ORIGIN_JSON="<取自 pending 的 origin 或空>" IID="<iid>" \
   MR_URL="<mr_url 或空>" REASON="<reason 或空>" \
   bash scripts/notify_user.sh
   ```

4. **drain executor 段**：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   RUN_ID="<run_id>" OUTCOME="<success|failed>" STAGE="executor" \
   PROJECT="<project 或空>" IID="<iid 或空>" \
   STATUS="<done|failed|timeout>" MR_URL="<mr_url 或空>" REASON="<reason 或空>" \
   bash scripts/drain_pending.sh
   ```

   - `OUTCOME` 映射：`status=done` → `OUTCOME=success`；`status=failed`/`timeout` → `OUTCOME=failed`（`STATUS` 仍透传精确终态供审计）。
   - **匹配不到 pending**（迟到 / 已被 stuck 驱逐 / 重复回调）→ 仍照常调 `drain_pending.sh`（写 `was_pending=false` 审计行）。这是**预期情形、非错误**，不触发 No-Fallback；记一条紧凑状态即可。
5. **不自动重试**（failed/timeout 不重投执行，重试由用户重发需求）。返回单条紧凑状态。

## 可选 ops 通知（best-effort）

失败事件在 drain / ledger 写入**之后**可选地推给运维 channel（`OPS_NOTIFY_CHANNEL`，部署期 pin；留空则整步 no-op）。三类事件同一脚本：

```bash
cd "<SKILL_DIR 绝对路径>" && \
source scripts/source_dispatcher_env.sh && \
EVENT="<launch_failed|git_issuer_failed|stuck_evicted>" \
RUN_ID="<相关 run_id 或空>" REASON="<原因摘要 或空>" COUNT="<stuck 驱逐数 或空>" \
bash scripts/ops_notify.sh
```

- `launch_failed`（git_issuer 段或 executor 段下游调用三次仍败）：`EVENT=launch_failed RUN_ID=<run_id> REASON=<最后错误>`。
- `git_issuer_failed`（git_issuer 返回失败 / 路由 `no_route`）：`EVENT=git_issuer_failed RUN_ID=<run_id> REASON=<reason|no_route>`。
- `stuck_evicted`（接入路径开头 `evict_stuck` 驱逐到 `>0` 条；覆盖两段 pending）：`EVENT=stuck_evicted COUNT=<驱逐数>`。

退出码语义（**不**违反 No-Fallback）：脚本对"无 channel / 缺 curl / 网络失败 / webhook 非 2xx"一律 `exit 0`（best-effort——已尽力，需求本身由 ledger 兜底，绝不因发告警失败而回滚或停下）；仅当**部署配置形态写错**（`OPS_NOTIFY_CHANNEL` 非 http(s) URL、`EVENT` 非法）才 `exit 2`，此时按 No-Fallback 记一条 `ops-misconfig` 状态停下（失败需求此前已 drain，主流程不受影响）。

## Working Directory（per-exec env 契约）

OpenClaw 每个 Bash tool call 是**全新 shell**，`export`/`cd` 不跨 exec 存活。每次调脚本都必须在**同一个** Bash exec 里：`cd "<SKILL_DIR 绝对路径>"` → `source scripts/source_dispatcher_env.sh`（拿 `STATE_ROOT`/`GIT_ISSUER_AGENT`/`DEFAULT_EXECUTOR_AGENT`/`DOWNSTREAM_AGENT_TIMEOUT_SECONDS`/`STUCK_AFTER_MINUTES`/`OPS_NOTIFY_CHANNEL`/`ROUTING_FILE`/`WIKI_GITLAB_HOST`/`WIKI_GITLAB_API_PROTOCOL`/`WIKI_GITLAB_TOKEN`/`WIKI_GLAB_BIN`/`REPLY_GATEWAY_URL`/`REPLY_GATEWAY_TOKEN`/`DEFAULT_REPLY_AGENT`/`REPLY_NOTIFY_TIMEOUT_SECONDS`/`DISPATCHER_CALLBACK_TARGET`）→ 前置最小 env → `bash scripts/<name>.sh`。脚本自身顶部 `source env_paths.sh` 从 `STATE_ROOT` 派生所有路径。不要把 `cd`/`source` 拆成单独的 exec。

脚本入参契约（env 变量名，须与脚本实际读取一致；I4）：

| 脚本 | 必填 env | 可选 env |
|------|---------|---------|
| `source_dispatcher_env.sh` | — | `DISPATCHER_CONFIG_DIR`（测试用；默认工作区 `config/`。必须用 `source` 调用；先加载 `dispatcher.env`，再加载被 git 忽略的 `dispatcher.local.env`） |
| `capture_origin.sh` | — | `MESSAGE` 或 `MESSAGE_FILE` 或 stdin；结构化运行时来源 env：`OPENCLAW_DELIVER_ORIGIN_JSON` / `OPENCLAW_DELIVER_ORIGIN` / `OPENCLAW_SOURCE_ORIGIN_JSON` / `OPENCLAW_SOURCE_ORIGIN` / `DELIVER_ORIGIN_JSON` / `DELIVER_ORIGIN` / `SOURCE_ORIGIN_JSON` / `SOURCE_ORIGIN`；离散运行时来源 env：`OPENCLAW_SOURCE_AGENT` / `OPENCLAW_SOURCE_SESSION` / `OPENCLAW_DELIVER_CHANNEL` / `OPENCLAW_DELIVER_USER` / `OPENCLAW_DELIVER_CONVERSATION` 等。stdout：有 origin 时输出紧凑 JSON；没有时输出空。优先级：结构化 JSON → 离散运行时 env → 文本 `[origin]` 行。 |
| `prepare_wiki_downstream_payloads.sh` | — | `MESSAGE` 或 `MESSAGE_FILE` 或 stdin；`FETCH_WIKI=1` 时读取 `WIKI_GITLAB_HOST`/`WIKI_GITLAB_API_PROTOCOL`/`WIKI_GITLAB_TOKEN`/`WIKI_GLAB_BIN`（也兼容同名 `GITLAB_*`/`GLAB_BIN` 测试覆盖）；`WIKI_CONTENT` 可用于本地测试跳过 glab。stdout：`{status,project,wiki_url,wiki_slug,requirements,git_issuer_payloads,reason}`；`status=success` 时 `git_issuer_payloads` 是一组顺序处理的建单消息；`status=failed` 时不调用 git_issuer。入参文件缺失 exit 2。 |
| `prepare_downstream_payloads.sh` | — | `MESSAGE` 或 `MESSAGE_FILE` 或 stdin。stdout：`{status,project,requirement_text,git_issuer_payload,reason}`；`status=success` 时 `project` 是从文本明确提取的 `group/project`，`git_issuer_payload` 是发给 git_issuer 的标准化消息；`status=failed` 时不调用 git_issuer，推用户失败说明后结束。入参文件缺失 exit 2。 |
| `run_agent_turn.sh` | `TARGET_AGENT` + (`MESSAGE` 或 `MESSAGE_FILE` 或 stdin) | `TARGET_SESSION_KEY`(默认 `agent:${TARGET_AGENT}:main`，传给 `openclaw --session-key`), `TARGET_SESSION_ID`(仅兼容显式非 `agent:*:*` 的 session id), `DOWNSTREAM_AGENT_TIMEOUT_SECONDS`(配置下限), `AGENT_TIMEOUT_SECONDS`(未传时默认取配置下限或 600；传入值低于配置下限时提升到配置下限), `RUN_AGENT_TURN_HEARTBEAT_SECONDS`(stderr heartbeat 间隔，默认 30), `OPENCLAW_BIN`(默认 `openclaw`), `RUN_ID`(测试/审计覆盖)。stdout：`{status,run_id,child_session_key,exit_code,worker_result_json,raw_output}`；入参形态错 exit 2；openclaw 调用失败返回 `status=failed` 且 exit 0 |
| `build_executor_payload.sh` | `PROJECT`, `IID`, `CORRELATION_ID` | `DISPATCHER_CALLBACK_TARGET`。stdout：完整 `RUN_SINGLE_ISSUE` 多行触发文本；project 形态错、IID 非正整数或缺必填项 exit 2。 |
| `evict_stuck.sh` | `STATE_ROOT`, `STUCK_AFTER_MINUTES` | `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / `DEFAULT_REPLY_AGENT` / `REPLY_NOTIFY_TIMEOUT_SECONDS`（仅 executor stuck 且带 origin 的 timeout 用户通知路径使用；覆盖两段 git_issuer/executor） |
| `next_correlation_id.sh` | `STATE_ROOT` | —（stdout：`reqd-<n>`，flock 保护 `${STATE_ROOT}/_dispatcher/seq`） |
| `find_pending.sh` | `STATE_ROOT` + (`RUN_ID` 或 `CORRELATION_ID`) | —（stdout：pending entry JSON；找不到 exit 1，参数缺失 exit 2） |
| `record_pending.sh` | `STATE_ROOT`, `RUN_ID`, `STAGE`(`git_issuer`\|`executor`) | `ORIGIN_JSON`, `PROJECT`, `IID`(正整数), `CORRELATION_ID`, `CHILD_SESSION_KEY`, `REQ_DIGEST` |
| `drain_pending.sh` | `STATE_ROOT`, `RUN_ID`, `OUTCOME` | `STAGE`, `PROJECT`, `IID`(或 `ISSUE_IID`), `ISSUE_URL`, `STATUS`(`done`\|`failed`\|`timeout`), `MR_URL`, `REASON` |
| `route_project.sh` | `PROJECT` | `ROUTING_FILE`, `DEFAULT_EXECUTOR_AGENT`（stdout：覆盖 executor、默认 executor 或 `__NO_ROUTE__`；合法 project 默认路由到 `DEFAULT_EXECUTOR_AGENT`；project 形态错/路由表文件缺失/格式错 exit 2） |
| `notify_user.sh` | `EVENT`(`result`\|`failure`) | `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / `DEFAULT_REPLY_AGENT`（仅当 `ORIGIN_JSON` 是合法 object 且缺 `reply_agent` 时兜底；空/null/非 object origin 不出站推 114）, `REPLY_NOTIFY_TIMEOUT_SECONDS`(默认 30), `ORIGIN_JSON`, `STATUS`, `IID`, `MR_URL`, `REASON` |
| `ops_notify.sh` | `EVENT` | `OPS_NOTIFY_CHANNEL`(空则 no-op), `RUN_ID`, `REASON`, `COUNT` |

`STATE_ROOT` / `GIT_ISSUER_AGENT` / `DEFAULT_EXECUTOR_AGENT` / `DOWNSTREAM_AGENT_TIMEOUT_SECONDS` / `STUCK_AFTER_MINUTES` / `OPS_NOTIFY_CHANNEL` / `ROUTING_FILE` / `WIKI_GITLAB_HOST` / `WIKI_GITLAB_API_PROTOCOL` / `WIKI_GITLAB_TOKEN` / `WIKI_GLAB_BIN` / `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / `DEFAULT_REPLY_AGENT` / `REPLY_NOTIFY_TIMEOUT_SECONDS` / `DISPATCHER_CALLBACK_TARGET` 由 `source scripts/source_dispatcher_env.sh` 注入：先读 tracked `config/dispatcher.env`，再读 ignored `config/dispatcher.local.env`（若存在，本机测试覆盖只写这里）。`capture_origin.sh` 只规范化来源元数据，不碰 state；`prepare_wiki_downstream_payloads.sh` 只读 wiki、拆分需求并准备消息，不写 GitLab、不碰 state；`prepare_downstream_payloads.sh` 只做旧自由文本入口分析与消息准备，不碰 state、不碰 GitLab；`build_executor_payload.sh` 只生成 executor trigger 文本；`run_agent_turn.sh` 只调用 `openclaw agent` 并输出 envelope，不碰 GitLab；`route_project.sh` / `ops_notify.sh` 不碰 state（不读写 pending/ledger/锁）：前者只做 project→executor 查表/默认路由，后者只发 best-effort 告警。`notify_user.sh` 不碰 GitLab、不建 issue、不打标签——只在 `ORIGIN_JSON` 是合法 object 时经反向网关把结果信封投给 114 接收 agent；目标 agent 优先取 `ORIGIN_JSON.reply_agent`，没有时才用默认 `DEFAULT_REPLY_AGENT`。`ORIGIN_JSON` 为空/null/非 object 时视为手动入口，只写 ledger 留痕；网关 pin 未配置、目标 agent 缺失、投递失败或超时也记 ledger 留痕、不静默丢。

## No-Fallback（HARD）

- 脚本非零退出 → 读 stdout/stderr、分类、记录、**stop**。不内联重写脚本逻辑、不"手动来一遍"、不换"更简单的命令"。
- **不写 GitLab**：不得用任何 token 建 issue / 打标签 / 写 note / 跑 issue——建 issue 是 git_issuer 的事、跑 issue 是 req_executor 的事。唯一允许的 GitLab 访问是 `prepare_wiki_downstream_payloads.sh` 使用 `glab api` 只读拉取 wiki 页面内容。
- **只做受控入口分析**：wiki 入口必须先用 `prepare_wiki_downstream_payloads.sh` 生成 `git_issuer_payloads`；旧自由文本入口必须先用 `prepare_downstream_payloads.sh` 生成 `git_issuer_payload`。若 wiki URL/读取/拆分失败，或旧文本没有明确 `group/project`，推用户失败说明并停止，不调用 git_issuer。不语义猜 project、不补写 project、不把 114/origin 包装原样发给 git_issuer。最终 issue 事实仍以 git_issuer 返回的 `project`/`issue_iid`/`issue_url` 为准。
- **所有合法 GitLab project 默认可路由**：`route_project.sh` 先查覆盖表，未命中时返回 `DEFAULT_EXECUTOR_AGENT`。`__NO_ROUTE__` 只表示默认执行器未配置且无覆盖；project 形态错、路由表文件缺失/格式错（exit 2）才是部署/回调形态错误，按 No-Fallback 停。
- **不去重**：透传语义；114 重发同需求会生成新两段下游调用/新 pending，可能重复建 issue + 重复测（去重是 114/git_issuer 侧的事）。
- **git_issuer / executor 业务结果失败 → 不自动重试**（避免重复建 issue / 重复测；重试由用户重发需求）。
- 下游调用失败（`run_agent_turn.sh` envelope `status=failed`）只允许"同 payload 3 次 2s 退避"这一种重试；耗尽即 `launch_failed`，不另寻他法。
- origin 捕获固定使用 `capture_origin.sh`：优先读取 OpenClaw 网关/运行时来源元数据，才 fallback 到文本 `[origin]` 行；跨 agent 调用固定使用 `run_agent_turn.sh` 包装 `openclaw agent`，executor 结果回调使用 `RUN_EXECUTOR_RESULT_CALLBACK` + `worker_result_json`，`correlation_id` 由 `next_correlation_id.sh` 生成。用户出站推送已对齐：`notify_user.sh` 仅在 origin 为合法 object 时反向网关推 114 接收 agent，连接 pin 为 `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN`，目标 agent 优先取 `origin.reply_agent`、否则取默认 `DEFAULT_REPLY_AGENT`；空/null/非 object origin 视为手动入口不推 114。

若你发现自己要用一个 SKILL / 脚本 / references 里没列出的工具、命令、flag 或流程，那就是**停下并失败**的信号，而不是更努力地试。

## Chat Output Policy

orchestrator 每轮只回一条紧凑状态摘要：接入路径 → `{path:"intake", git_issuer_run_id, outcome, project?, iid?, routed_executor?, executor_run_id?}`；executor 回调路径 → `{path:"executor_cb", run_id, status, iid?, notified}`。详细证据只落 disk（`ledger.jsonl`），不进 chat。

## Where to look

- agent 灵魂、Global Rules、Session Policy：[`../../SOUL.md`](../../SOUL.md)。
- 工作区说明、agent 身份、执行模型、req_executor 衔接依赖：[`../../AGENTS.md`](../../AGENTS.md)。
- 114 调用方式、ack 文案、配置项：[`../../USER.md`](../../USER.md)。
- state / ledger schema（两段 pending、I3）：[`references/state_schema.md`](references/state_schema.md)。
- `run_agent_turn.sh` 调用契约 + executor RUN_SINGLE_ISSUE(I1)/结果回调(I2) 信封：[`references/trigger_command.md`](references/trigger_command.md)。
- 默认执行器路由、覆盖路由表与用户结果推送 pin 配置（`REPLY_*`）：[`../../config/README.md`](../../config/README.md)、[`../../config/routing.env`](../../config/routing.env)。
- git_issuer 产出/变更对接文档（跨团队，运行时不必读）：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)、[`../../docs/integration/gitissuer_change_request.md`](../../docs/integration/gitissuer_change_request.md)。

存疑时 READ 对应 reference，不要凭记忆重构契约。
