---
name: requirement_dispatch
description: "[SKILL_VERSION=2026-07-09.4] Route WebUI/ZhiBan prompts to the correct req pipeline action from the 104 side. req_dispatcher no longer automatically runs the full requirement → issue → executor chain for every intake message: the LLM first decides from the prompt whether to create/change GitLab issues through git_issuer, execute an existing issue through req_executor, explicitly create then execute, or ask for missing information. Issue creation intake supports a blue-zone GitLab wiki URL or free-text requirements with deterministic project locators (`group/project`, GitLab repository/Wiki URL, or `glab api projects/<encoded-group%2Fproject>/...` snippet) via prepare_wiki_downstream_payloads.sh / prepare_downstream_payloads.sh. Existing issue execution uses prepare_executor_issue_payload.sh to extract project/iid/target_branch from GitLab issue URLs or explicit project + issue IID text, routes the project, appends to durable executor_queue.json, and lets drain_executor_queue.sh call RUN_SINGLE_ISSUE. req_dispatcher may read GitLab wiki pages only; it must not create issues, write labels/notes, or run issue work directly. Main helpers: source_dispatcher_env.sh, capture_origin.sh, prepare_wiki_downstream_payloads.sh, prepare_downstream_payloads.sh, prepare_executor_issue_payload.sh, run_agent_turn.sh, build_executor_payload.sh, enqueue_executor_issue.sh, drain_executor_queue.sh, finish_executor_queue_active.sh, next_correlation_id.sh, find_pending.sh, record_pending.sh, drain_pending.sh, evict_stuck.sh, route_project.sh, notify_user.sh, ops_notify.sh."
allowed-tools: Bash, Read
---

# Requirement Dispatch Skill

这是一个 **prompt 路由 + 下游编排契约**。`req_dispatcher` 接收 WebUI 对话框或智伴/114 转发来的自然语言 prompt 后，先由 LLM 判断用户要做什么，再选择唯一合适动作：只分析/创建/变更 issue 时调用 `git_issuer`；明确要求处理既有 issue 时调用 `req_executor`；明确要求"建 issue 并处理"时才允许先建单再进入执行队列；信息不足时直接说明缺少哪些 `project` / `iid` / GitLab URL。它不再把每个需求入口都自动推进到 executor。

确定性消息准备仍由脚本完成：创建 issue 时，wiki URL 用 `scripts/prepare_wiki_downstream_payloads.sh` 解析 `group/project`、只读拉取 wiki Markdown、拆分需求并生成一组 `git_issuer` 建单消息；自由文本用 `scripts/prepare_downstream_payloads.sh` 从 `group/project`、GitLab 仓库/Wiki URL，或 `glab api projects/<encoded-group%2Fproject>/...` 片段确定性提取 project 并生成单条建单消息。执行既有 issue 时，用 `scripts/prepare_executor_issue_payload.sh` 从 GitLab issue URL 或显式 `group/project` + issue IID 文本提取 `project`、`iid`、可选 `target_branch`，再按 project 路由并写入 durable executor FIFO queue。`target_branch` 是从用户 prompt 明确分支语义提取出的本次执行分支，最终只作为 executor `branch=` 下发；`req_dispatcher` 自身没有固定分支配置。所有确定性的 state 写入（pending 记录、queue 入队/drain、超时驱逐）、消息准备与本地决策（wiki 拆分、路由查表、推送留痕）都在 `scripts/` 下 flock 保护或 best-effort 的 shell 脚本里；LLM 只做脚本干不了的事：理解 prompt 意图、选择动作、按脚本契约组织下游调用、读执行器回调、可选 ops 通知。

**职责边界（HARD）**：身份是「prompt 路由器 + 编排器」，但**仍不写 GitLab**——不得用任何 token 去建 issue、打标签、写 note、跑 issue；建 issue 是 `git_issuer` 的事，跑 issue 是 `req_executor` 的事。wiki 入口只允许用 `WIKI_GITLAB_*` 只读配置拉取 wiki 页面内容。编排器可以做受控入口分析：解析 wiki/issue URL、拆分 wiki 文档、剥离 114/origin 包装、从入口自然语言中提取安全执行分支 `target_branch`、从自由文本中的显式 locator 确定 project/iid、生成下游消息；但不能语义猜测项目，不能替代 `git_issuer` 的建单/校验职责。只建单动作以 `git_issuer` 返回的 issue JSON 为终点；只有用户明确要求执行时，才按 project 路由并把 issue 入 executor durable FIFO queue。详见 [`../../SOUL.md`](../../SOUL.md) §Global Rules 与下方 §No-Fallback。

state 与磁盘布局（executor pending、git_issuer 审计 stage、I3 entry）：[`references/state_schema.md`](references/state_schema.md)。`run_agent_turn.sh` 调用契约、git_issuer JSON 字段→drain env 映射、executor RUN_SINGLE_ISSUE(I1) 入参与 executor 结果回调(I2) 信封：[`references/trigger_command.md`](references/trigger_command.md)。git_issuer 的产出/变更规格（跨团队对接文档，orchestrator 运行时不必读）：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)。

## 路径判定

orchestrator（固定 session `agent:req_dispatcher:main`）每次被唤醒先判这次是哪一路：

- 收到**结构化结果回调**且来自 **req_executor**（I2 信封带 `correlation_id`/`status`，trigger 名见 trigger_command.md）→ **executor 回调路径**（路径 B）。
- 收到 `RUN_EXECUTOR_QUEUE_DRAIN` → **executor 队列 drain 路径**（路径 C）。
- 否则（114 投来的需求消息，可能含 wiki URL 或自由文本）→ **接入路径**（路径 A）。

## Executor FIFO Queue（HARD）

`req_dispatcher` 是 executor 待执行 issue 队列的唯一 owner。只有当用户 prompt
明确要求处理 issue（既有 issue，或显式"创建后处理"）时，issue 才能写入
`${STATE_ROOT}/_dispatcher/executor_queue.json`，再调用
`scripts/drain_executor_queue.sh` 尝试启动队首。只创建/分析 issue 的请求不得入队。
队列文件由
`scripts/env_paths.sh` 初始化，和 `pending.json` 共用 `${LOCK_FILE}`。

队列规则：

- 显式"创建后处理"请求中，wiki 拆出的每个 issue 依建单完成顺序追加到队尾。
- 任意时刻最多一个 `active` executor issue。
- `drain_executor_queue.sh` 是唯一启动 executor 的脚本。它会把队首持久化
  为 `active.launch_state="launching"` 并预写同 `run_id` 的 executor pending
  占位后再调用 `run_agent_turn.sh`，因此 OpenClaw 会话被用户或运行时中断后，
  下一次 drain 可以从 disk 恢复，且 executor 很快回调时也能按 pending 匹配。
  启动成功的判定不只看外层 `openclaw agent` 退出成功，还要求 executor
  `worker_result_json.status="waiting_for_callbacks"`，或兼容现有 req_executor
  纯文本摘要里出现 `waiting_for_callbacks`；否则视为未接单，删除 pending
  占位，active 进入 `launch_failed` 等后续 drain 重试。
- executor 回调路径在 drain pending 后必须调用
  `finish_executor_queue_active.sh`；只有 `correlation_id` 匹配当前 active 时
  才清空 active。随后必须再次调用 `drain_executor_queue.sh`，让下一条 issue
  自动启动。
- `evict_stuck.sh` 驱逐 executor pending 时，如果该 pending 匹配当前 queue active
  的 `run_id` 或 `correlation_id`，必须同步清空 active，避免超时后 FIFO 永久卡住。
- 部署侧必须周期性唤醒 `agent:req_dispatcher:main` 并发送
  `RUN_EXECUTOR_QUEUE_DRAIN`。这个触发是幂等的：active 正在执行时返回
  `busy`，队列为空时返回 `idle`；实现时先跑 `evict_stuck.sh`，再跑
  `drain_executor_queue.sh`。

## 路径 A：接入路径（需求消息进来）

1. **取需求原文 + capture origin**：114 经 `agent run --agent req_dispatcher "<需求原文>" --deliver` 投来。先保留原文供 origin 捕获和消息准备使用。调用 `capture_origin.sh` 只提取回推元数据：优先读 OpenClaw 网关/运行时提供的结构化来源（如 `OPENCLAW_DELIVER_ORIGIN_JSON`、`OPENCLAW_SOURCE_AGENT`、`OPENCLAW_SOURCE_SESSION` 等），其次才读需求文本里的显式 `[origin] ...` 行；这是 req_dispatcher 自己回推结果用的，**不是**业务需求解析。拿不到则 origin 留空（`ORIGIN_JSON` 不传，entry 里为 `null`），不阻断主流程；后续 `notify_user.sh` 会把空/null/非 object origin 视为手动入口，只留 ledger/log，不调用 114。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   MESSAGE="<需求原文>" \
   bash scripts/capture_origin.sh
   ```

   stdout 若非空即为紧凑 `origin_json`，形如 `{"channel":"..","user":"..","conversation":"..","reply_agent":".."}`；其中 `reply_agent` 是 114 上接收终态结果的 agent 名。只有该值是合法 JSON object 时，用户结果推送才允许出站到 114。

2. **AI 动作判定（HARD）**：根据用户 prompt 选择一个动作，不要因输入里有 wiki URL 或需求文本就默认执行。

   - `create_issue`：用户要分析需求、拆分需求、创建/变更 GitLab issue、整理需求为 issue，但没有明确要求实现/处理/执行该 issue。只调用 `git_issuer`，成功后停止，不入 executor queue。
   - `execute_issue`：用户明确要求处理/实现/执行/重跑一个既有 GitLab issue，且 prompt 含 GitLab issue URL，或含显式 `group/project` + issue IID。只调用 `req_executor`，不调用 `git_issuer`。
   - `create_and_execute`：用户明确要求先创建 issue 再处理，或明确要求把 wiki/需求拆成 issue 后立即执行。先调用 `git_issuer`，成功返回的 issue 再入 executor queue；这是唯一允许的自动串联。
   - `clarify_or_reject`：无法判断用户是要建单还是执行，或执行请求缺 project / iid，或建单请求缺 project locator。推用户失败/补充说明或直接简短答复，不调用下游 agent。

   边际场景按保守规则处理：只说"分析/整理/创建 issue"不执行；只给 wiki URL 不执行，除非 prompt 明确说"处理/实现/执行"；"处理这个需求"但没有 issue IID 时按建单请求处理，除非用户明确说已有 issue；"处理 #12"但缺 project 时要求补充 project 或 issue URL；同时出现多个 issue URL 可逐个入队，但不能把 issue URL 当成建单需求；分支指令只作为 executor `branch=`，不得传给 git_issuer 需求正文。分支指令可以是 `branch=release/x`、`target_branch=release/x`、`目标分支：release/x`、`合到 release/x`，也可以是“基于 release/x 分支开发”。

3. **为所选动作准备下游消息**：

   - `create_issue` / `create_and_execute`：wiki URL 调 `prepare_wiki_downstream_payloads.sh`；非 wiki 文本调 `prepare_downstream_payloads.sh`。脚本失败表示入口信息不足，推用户失败说明并停止，不调用 `git_issuer`。

     ```bash
     cd "<SKILL_DIR 绝对路径>" && \
     source scripts/source_dispatcher_env.sh && \
     MESSAGE="<含 GitLab wiki URL 的需求原文>" FETCH_WIKI=1 \
     bash scripts/prepare_wiki_downstream_payloads.sh
     ```

     ```bash
     cd "<SKILL_DIR 绝对路径>" && \
     MESSAGE="<需求原文>" \
     bash scripts/prepare_downstream_payloads.sh
     ```

     成功输出分别含 `git_issuer_payloads[]` 或 `git_issuer_payload`。wiki 成功时按数组顺序逐条处理；自由文本成功时把单条 payload 当作长度为 1 的列表。入口准备输出的 `.target_branch` 只在 `create_and_execute` 中随 executor queue 入队。

   - `execute_issue`：调用 `prepare_executor_issue_payload.sh`。它只解析既有 issue 执行所需的 `project` / `iid` / `target_branch` / `issue_url`，不建 payload、不碰 GitLab、不启动 executor。`status=failed` 时推用户失败说明并停止。

     ```bash
     cd "<SKILL_DIR 绝对路径>" && \
     MESSAGE="<用户要求处理既有 issue 的原文>" \
     bash scripts/prepare_executor_issue_payload.sh
     ```

     成功输出形如：

     ```json
     {"status":"success","project":"ai-infra/veqp_server_v3","iid":312,"target_branch":"release/2026.07","issue_url":"http://.../-/issues/312","request_text":"请处理 ...","reason":null}
     ```

   - 任一准备脚本失败时：

     ```bash
     cd "<SKILL_DIR 绝对路径>" && \
     source scripts/source_dispatcher_env.sh && \
     EVENT="failure" ORIGIN_JSON="<origin_json 或空>" \
     REASON="<准备脚本 reason>" \
     bash scripts/notify_user.sh
     ```

     然后返回 `{path:"intake", outcome:"rejected", reason:"<reason>"}`。这不是下游失败，不写 pending。

4. **stuck 兜底**（先跑，回收泄漏的 pending；覆盖两段 git_issuer/executor）：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   bash scripts/evict_stuck.sh
   ```

   其 stdout `evicted <N> stuck pending`：若 `N > 0`，**可选 ops 通知**（见 §可选 ops 通知，`EVENT=stuck_evicted COUNT=<N>`）。

5. **`create_issue` / `create_and_execute` 调用蓝区 `git_issuer`**：用 `scripts/run_agent_turn.sh` 包装 `openclaw agent`。payload 是第 3 步生成的当前建单消息：wiki 入口为 `.git_issuer_payloads[n]`，自由文本入口为 `.git_issuer_payload`；不要把 114 原文直接发给 git_issuer。该脚本返回结构化 envelope：`{status,run_id,child_session_key,exit_code,worker_result_json,raw_output}`；`worker_result_json` 优先来自 git_issuer 输出中的最后一行紧凑 JSON，也兼容 Markdown 代码块里的 pretty JSON object（成功时含 `project`/`issue_iid`/`issue_url`）。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   TARGET_AGENT="${GIT_ISSUER_AGENT}" \
   AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}" \
   bash scripts/run_agent_turn.sh <<'EOF'
   <当前 git_issuer payload>
   EOF
   ```

   默认 session key 由 `run_agent_turn.sh` 自动生成并统一通过 `openclaw agent --session-key` 传给 CLI：普通调用默认 `agent:${TARGET_AGENT}:main`；`RUN_SINGLE_ISSUE` 会从 payload 的 `project`/`iid` 自动生成 `agent:${TARGET_AGENT}:issue-<sanitized-project>-<iid>`，避免多个 issue 堆在 executor main session。`TARGET_SESSION_KEY` 是主输入；旧 `TARGET_SESSION_ID` 仅作为兼容别名保留，最终也会转为 `--session-key`；若旧上下文显式传了 `agent:${TARGET_AGENT}:main`，`RUN_SINGLE_ISSUE` 仍会改投 issue 级 session。不要手写 `agent:…main`、`agent:<target>:main` 这类占位符；脚本会拒绝包含省略号或尖括号的 session selector。
   `run_agent_turn.sh` 会在等待下游 OpenClaw agent 时定期向 stderr 输出 heartbeat，stdout 仍只保留最终 JSON envelope。若 tool 返回“仍在运行”，必须继续 poll 到进程完成并读取最终 stdout，不得因为暂时无新输出就 kill。

   - **失败重试**（no-fallback）：若 envelope `status=failed`，同 payload 最多 3 次、2s 固定退避。三次仍失败 → 视为 `launch_failed`：调 `drain_pending.sh`（`OUTCOME=launch_failed`、`STAGE=git_issuer`、`REASON=<最后一次 raw_output>`、`RUN_ID="<最后一次 envelope.run_id>"`）写 ledger，不写 pending；随后可选 ops 通知。本路径结束。
   - **成功但 `worker_result_json` 为空/非对象** → 视为 `failed`，推用户"建 issue 失败：git_issuer 未返回有效 JSON"并 drain git_issuer 审计行。

6. **记录 git_issuer 审计 stage**：拿 envelope 的 `run_id` / `child_session_key` 记一条 `STAGE=git_issuer`，随后在成功收尾时 drain。它是本轮审计键，不要求蓝区 git_issuer 回显任何 token。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   RUN_ID="<git_issuer envelope.run_id>" STAGE="git_issuer" \
   ORIGIN_JSON="<origin_json 或不传>" \
   CHILD_SESSION_KEY="<git_issuer envelope.child_session_key>" \
   REQ_DIGEST="<当前需求条目正文前80字>" \
   bash scripts/record_pending.sh
   ```

7. **解析 git_issuer 结果 JSON**：成功（`status=success`，带 `project`、`issue_iid`、`issue_url`）先 drain git_issuer stage；失败（`status=failed`，带 reason）推用户"建 issue 失败" + drain git_issuer stage，本路径结束。

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

   成功 drain：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   RUN_ID="<run_id>" OUTCOME="success" STAGE="git_issuer" \
   PROJECT="<project>" IID="<issue_iid>" ISSUE_URL="<issue_url>" \
   bash scripts/drain_pending.sh
   ```

   - 若动作是 `create_issue`：到这里结束，回最小建单结果/ack，例如 `{path:"intake", action:"create_issue", outcome:"issue_created", project, iid, issue_url}`。**不得**调用 `route_project.sh`、`enqueue_executor_issue.sh` 或 `drain_executor_queue.sh`。
   - 若动作是 `create_and_execute`：继续第 8 步，把刚创建的 issue 入 executor queue。

8. **`execute_issue` / `create_and_execute` 按 project 路由选 executor**：

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   PROJECT="<要执行 issue 的 group/project>" \
   ROUTING_FILE="${ROUTING_FILE:-}" \
   DEFAULT_EXECUTOR_AGENT="${DEFAULT_EXECUTOR_AGENT}" \
   bash scripts/route_project.sh
   ```

   - stdout 是 executor agent 名 → 进第 9 步。
   - stdout 是 `__NO_ROUTE__` → **默认执行器未配置且无覆盖路由**：推用户 + ledger + ops 通知 + drain git_issuer 段，本路径结束。蓝区默认配置下，所有合法 `group/project` 都应命中 `DEFAULT_EXECUTOR_AGENT`，不应走到此分支。
     - 推用户：`EVENT="failure" ORIGIN_JSON="<origin>" IID="<issue_iid>" REASON="该 project 未接入执行器" bash scripts/notify_user.sh`。
     - drain：`RUN_ID="<run_id>" OUTCOME="failed" STAGE="git_issuer" PROJECT="<project>" IID="<issue_iid>" ISSUE_URL="<issue_url>" REASON="no_route" bash scripts/drain_pending.sh`。
     - 可选 ops 通知：`EVENT=git_issuer_failed RUN_ID=<run_id> REASON=no_route`（复用 ops 失败枚举留痕）。
   - 脚本 `exit 2`（project 不是 `group/project`、`ROUTING_FILE` 缺失/格式错）→ **部署期或 git_issuer 返回形态错误**：按 No-Fallback 读 stderr、分类、记录、**停**（不当成 no-route，不臆造投递）。
9. **enqueue executor issue（不直接启动）**：把明确要执行的 issue 追加到 durable executor FIFO 队尾。`create_and_execute` 使用 git_issuer 返回的 `project`/`issue_iid`/`issue_url`；`execute_issue` 使用 `prepare_executor_issue_payload.sh` 返回的 `project`/`iid`/`issue_url`。`EXECUTOR_AGENT` 使用第 8 步 `route_project.sh` 的 stdout。`ORIGIN_JSON` 必须沿用接入路径捕获到的 origin；手动入口为空即可。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   PROJECT="<project>" IID="<issue_iid>" ISSUE_URL="<issue_url>" \
   EXECUTOR_AGENT="<route_project.sh stdout>" \
   TARGET_BRANCH="<入口准备脚本的 target_branch 或空>" \
   ORIGIN_JSON="<origin_json 或空>" \
   REQ_DIGEST="<当前需求条目正文前80字 或空>" \
   bash scripts/enqueue_executor_issue.sh
   ```

   stdout 是 `{status:"queued", queue_id, queued_count}`。这是 issue 进入待执行队列的 durable 证据。

10. **尝试启动队首 executor issue**：每个执行动作在 enqueue 后调用一次 drain；如果已有 active executor，则返回 `busy`，新 issue 保持排队。若没有 active，则启动队首。这个脚本内部生成 `correlation_id`、调用 `build_executor_payload.sh`、通过 `run_agent_turn.sh` 调 executor、并记录 executor pending。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   bash scripts/drain_executor_queue.sh
   ```

   可能返回：

   - `launched`：队首 issue 已启动，executor pending 占位已补齐启动信息。
   - `active_changed_after_launch`：executor 接单返回前，回调已处理并清掉 active；这是竞态恢复成功，不再补写旧 pending。
   - `busy`：已有 active executor issue，当前新 issue 留在队列中。
   - `idle`：队列为空。
   - `launch_failed`：启动尝试失败但 active 未丢弃，后续 `RUN_EXECUTOR_QUEUE_DRAIN` 会重试。

   `launch_failed` 不推用户终态、不删除 active，因为 issue 仍是待执行工作；周期性 queue drain 会恢复。

11. **回最小受理 ack** 给 114（文案见 [`../../USER.md`](../../USER.md)）。`create_issue` 返回 issue 创建结果；`execute_issue` / `create_and_execute` 返回 `queued_for_executor` 或 `waiting_for_executor_callback`。若 drain 返回 `launched`，处理结果会经 executor 回调异步返回；若返回 `busy`，后续回调或周期性 `RUN_EXECUTOR_QUEUE_DRAIN` 会继续启动。

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
5. **清理 executor queue active**：无论 executor 终态是 `done` / `failed` / `timeout`，这个 issue 都不再是"待执行"。按 I2 的 `correlation_id` 清空当前 active；若回调迟到或不匹配，脚本返回 `ignored` 或 `no_active`，不算错误。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   CORRELATION_ID="<I2 correlation_id>" PROJECT="<project 或空>" IID="<iid 或空>" \
   bash scripts/finish_executor_queue_active.sh
   ```

6. **继续 drain 队列**：回调路径完成后必须立刻调用一次 drain，让后续 queued issue 自动启动。这样 #11 完成后 #12 不依赖人工追问。

   ```bash
   cd "<SKILL_DIR 绝对路径>" && \
   source scripts/source_dispatcher_env.sh && \
   bash scripts/drain_executor_queue.sh
   ```

7. **不自动重试业务结果**（failed/timeout 不重投执行，重试由用户重发需求）。返回单条紧凑状态；其中可包含 finish/drain 的简短状态。

## 路径 C：executor 队列 drain 路径（周期性恢复）

`RUN_EXECUTOR_QUEUE_DRAIN` 是部署侧周期性唤醒使用的幂等触发。它先调用
`evict_stuck.sh` 清理过期 pending（并清理匹配的 executor queue active），再调用
`drain_executor_queue.sh` 并打印该脚本的 compact JSON。它用于恢复用户/前端/运行时
中断导致的 `active.launch_state="launching"`，也用于在队列非空但没有回调唤醒时继续推进。

```bash
cd "<SKILL_DIR 绝对路径>" && \
source scripts/source_dispatcher_env.sh && \
bash scripts/evict_stuck.sh && \
bash scripts/drain_executor_queue.sh
```

返回 `idle` / `busy` / `waiting_retry` / `launched` / `launch_failed` 均为有效状态；
不要把 `busy` 或 `idle` 当成失败。

## 可选 ops 通知（best-effort）

失败事件在 drain / ledger 写入**之后**可选地推给运维 channel（`OPS_NOTIFY_CHANNEL`，部署期 pin；留空则整步 no-op）。三类事件同一脚本：

```bash
cd "<SKILL_DIR 绝对路径>" && \
source scripts/source_dispatcher_env.sh && \
EVENT="<launch_failed|git_issuer_failed|stuck_evicted>" \
RUN_ID="<相关 run_id 或空>" REASON="<原因摘要 或空>" COUNT="<stuck 驱逐数 或空>" \
bash scripts/ops_notify.sh
```

- `launch_failed`（git_issuer 下游调用耗尽，或 executor queue 启动耗尽本轮重试）：`EVENT=launch_failed RUN_ID=<run_id> REASON=<最后错误>`。
- `git_issuer_failed`（git_issuer 返回失败 / 路由 `no_route`）：`EVENT=git_issuer_failed RUN_ID=<run_id> REASON=<reason|no_route>`。
- `stuck_evicted`（接入路径开头 `evict_stuck` 驱逐到 `>0` 条；覆盖两段 pending）：`EVENT=stuck_evicted COUNT=<驱逐数>`。

退出码语义（**不**违反 No-Fallback）：脚本对"无 channel / 缺 curl / 网络失败 / webhook 非 2xx"一律 `exit 0`（best-effort——已尽力，需求本身由 ledger 兜底，绝不因发告警失败而回滚或停下）；仅当**部署配置形态写错**（`OPS_NOTIFY_CHANNEL` 非 http(s) URL、`EVENT` 非法）才 `exit 2`，此时按 No-Fallback 记一条 `ops-misconfig` 状态停下（失败需求此前已 drain，主流程不受影响）。

## Working Directory（per-exec env 契约）

OpenClaw 每个 Bash tool call 是**全新 shell**，`export`/`cd` 不跨 exec 存活。每次调脚本都必须在**同一个** Bash exec 里：`cd "<SKILL_DIR 绝对路径>"` → `source scripts/source_dispatcher_env.sh`（拿 `STATE_ROOT`/`GIT_ISSUER_AGENT`/`DEFAULT_EXECUTOR_AGENT`/`DOWNSTREAM_AGENT_TIMEOUT_SECONDS`/`EXECUTOR_AGENT_TIMEOUT_SECONDS`/`STUCK_AFTER_MINUTES`/`OPS_NOTIFY_CHANNEL`/`ROUTING_FILE`/`WIKI_GITLAB_HOST`/`WIKI_GITLAB_API_PROTOCOL`/`WIKI_GITLAB_TOKEN`/`WIKI_GLAB_BIN`/`REPLY_GATEWAY_URL`/`REPLY_GATEWAY_TOKEN`/`DEFAULT_REPLY_AGENT`/`REPLY_NOTIFY_TIMEOUT_SECONDS`/`DISPATCHER_CALLBACK_TARGET`/`EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS`/`EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS`/`EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS`/`EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS`）→ 前置最小 env → `bash scripts/<name>.sh`。脚本自身顶部 `source env_paths.sh` 从 `STATE_ROOT` 派生所有路径。不要把 `cd`/`source` 拆成单独的 exec。

脚本入参契约（env 变量名，须与脚本实际读取一致；I4）：

| 脚本 | 必填 env | 可选 env |
|------|---------|---------|
| `source_dispatcher_env.sh` | — | `DISPATCHER_CONFIG_DIR`（测试用；默认工作区 `config/`。必须用 `source` 调用；先加载 `dispatcher.env`，再加载被 git 忽略的 `dispatcher.local.env`） |
| `capture_origin.sh` | — | `MESSAGE` 或 `MESSAGE_FILE` 或 stdin；结构化运行时来源 env：`OPENCLAW_DELIVER_ORIGIN_JSON` / `OPENCLAW_DELIVER_ORIGIN` / `OPENCLAW_SOURCE_ORIGIN_JSON` / `OPENCLAW_SOURCE_ORIGIN` / `DELIVER_ORIGIN_JSON` / `DELIVER_ORIGIN` / `SOURCE_ORIGIN_JSON` / `SOURCE_ORIGIN`；离散运行时来源 env：`OPENCLAW_SOURCE_AGENT` / `OPENCLAW_SOURCE_SESSION` / `OPENCLAW_DELIVER_CHANNEL` / `OPENCLAW_DELIVER_USER` / `OPENCLAW_DELIVER_CONVERSATION` 等。stdout：有 origin 时输出紧凑 JSON；没有时输出空。优先级：结构化 JSON → 离散运行时 env → 文本 `[origin]` 行。 |
| `prepare_wiki_downstream_payloads.sh` | — | `MESSAGE` 或 `MESSAGE_FILE` 或 stdin；`FETCH_WIKI=1` 时读取 `WIKI_GITLAB_HOST`/`WIKI_GITLAB_API_PROTOCOL`/`WIKI_GITLAB_TOKEN`/`WIKI_GLAB_BIN`（也兼容同名 `GITLAB_*`/`GLAB_BIN` 测试覆盖）；`WIKI_CONTENT` 可用于本地测试跳过 glab。stdout：`{status,project,target_branch,wiki_url,wiki_slug,requirements,git_issuer_payloads,reason}`；`status=success` 时 `target_branch` 是从入口消息明确分支语义中提取出的安全 Git ref 名或 `null`，`git_issuer_payloads` 是一组顺序处理的建单消息；`status=failed` 时不调用 git_issuer。入参文件缺失 exit 2。 |
| `prepare_downstream_payloads.sh` | — | `MESSAGE` 或 `MESSAGE_FILE` 或 stdin。stdout：`{status,project,target_branch,requirement_text,git_issuer_payload,reason}`；`status=success` 时 `project` 是从文本里的 `group/project`、GitLab 仓库/Wiki URL，或 `glab api projects/<encoded-group%2Fproject>/...` 片段确定性提取的 `group/project`；`target_branch` 是从明确分支语义中提取出的安全 Git ref 名，缺省为 `null`；`git_issuer_payload` 是发给 git_issuer 的标准化消息；`status=failed` 时不调用 git_issuer，推用户失败说明后结束。入参文件缺失 exit 2。 |
| `prepare_executor_issue_payload.sh` | — | `MESSAGE` 或 `MESSAGE_FILE` 或 stdin。stdout：`{status,project,iid,target_branch,issue_url,request_text,reason}`；`status=success` 时 `project` / `iid` 来自 GitLab issue URL，或显式 `group/project` + issue IID；`target_branch` 是从明确分支语义中提取出的安全 Git ref 名，缺省为 `null`；`status=failed` 时不调用 executor，推用户失败说明后结束。入参文件缺失 exit 2。 |
| `run_agent_turn.sh` | `TARGET_AGENT` + (`MESSAGE` 或 `MESSAGE_FILE` 或 stdin) | `TARGET_SESSION_KEY`(显式覆盖 session key；不传时普通调用默认 `agent:${TARGET_AGENT}:main`，`RUN_SINGLE_ISSUE` 默认 `agent:${TARGET_AGENT}:issue-<sanitized-project>-<iid>`；若显式值是 `agent:${TARGET_AGENT}:main`，`RUN_SINGLE_ISSUE` 会改用 issue 级 session；统一传给 `openclaw --session-key`), `TARGET_SESSION_ID`(历史兼容别名，也会转为 `--session-key`), `DOWNSTREAM_AGENT_TIMEOUT_SECONDS`(通用配置下限), `EXECUTOR_AGENT_TIMEOUT_SECONDS`(executor 目标专用配置下限，默认部署为 10800), `AGENT_TIMEOUT_SECONDS`(未传时默认取对应配置下限或 600；传入值低于对应配置下限时提升到配置下限), `RUN_AGENT_TURN_HEARTBEAT_SECONDS`(stderr heartbeat 间隔，默认 30), `OPENCLAW_BIN`(默认 `openclaw`), `RUN_ID`(测试/审计覆盖)。stdout：`{status,run_id,child_session_key,exit_code,worker_result_json,raw_output}`；`worker_result_json` 优先解析最后一行紧凑 JSON，并兜底解析 Markdown 代码块内的 pretty JSON object；入参形态错 exit 2；openclaw 调用失败返回 `status=failed` 且 exit 0 |
| `build_executor_payload.sh` | `PROJECT`, `IID`, `CORRELATION_ID` | `DISPATCHER_CALLBACK_TARGET`, `TARGET_BRANCH`。stdout：完整 `RUN_SINGLE_ISSUE` 多行触发文本；`TARGET_BRANCH` 非空时追加 `branch=<target>`；project 形态错、IID 非正整数、分支名不安全或缺必填项 exit 2。 |
| `enqueue_executor_issue.sh` | `STATE_ROOT`, `PROJECT`, `IID`, `EXECUTOR_AGENT` | `ISSUE_URL`, `ORIGIN_JSON`, `REQ_DIGEST`, `TARGET_BRANCH`。stdout：`{status:"queued",queue_id,queued_count}`；追加到 `${EXECUTOR_QUEUE_FILE}` FIFO 队尾，安全分支名持久化为 `target_branch`。 |
| `drain_executor_queue.sh` | `STATE_ROOT` | `OPENCLAW_BIN`, `OPENCLAW_CALL_LOG`(测试 fake openclaw 使用), `DISPATCHER_CALLBACK_TARGET`, `DOWNSTREAM_AGENT_TIMEOUT_SECONDS`, `EXECUTOR_AGENT_TIMEOUT_SECONDS`, `EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS`(默认 11100), `EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS`(默认 60), `EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS`(默认 3), `EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS`(默认 2)。stdout：`idle|busy|waiting_retry|launched|active_changed_after_launch|launch_failed` compact JSON；内部调用 `build_executor_payload.sh` / `run_agent_turn.sh`，将 active 的 `target_branch` 转成 I1 `branch=`，认领 active 时预写 executor pending 占位；只有 executor `worker_result_json.status="waiting_for_callbacks"` 或 raw output 含 `waiting_for_callbacks` 才记为 launched，失败时删除 pending 占位。 |
| `finish_executor_queue_active.sh` | `STATE_ROOT`, `CORRELATION_ID` | `PROJECT`, `IID`。stdout：`cleared|ignored|no_active` compact JSON；只有 active correlation 匹配时清空 active。 |
| `evict_stuck.sh` | `STATE_ROOT`, `STUCK_AFTER_MINUTES` | `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / `DEFAULT_REPLY_AGENT` / `REPLY_NOTIFY_TIMEOUT_SECONDS`（仅 executor stuck 且带 origin 的 timeout 用户通知路径使用；覆盖两段 git_issuer/executor；若 executor pending 匹配当前 queue active，则同步清 active） |
| `next_correlation_id.sh` | `STATE_ROOT` | —（stdout：`reqd-<n>`，flock 保护 `${STATE_ROOT}/_dispatcher/seq`） |
| `find_pending.sh` | `STATE_ROOT` + (`RUN_ID` 或 `CORRELATION_ID`) | —（stdout：pending entry JSON；找不到 exit 1，参数缺失 exit 2） |
| `record_pending.sh` | `STATE_ROOT`, `RUN_ID`, `STAGE`(`git_issuer`\|`executor`) | `ORIGIN_JSON`, `PROJECT`, `IID`(正整数), `CORRELATION_ID`, `CHILD_SESSION_KEY`, `REQ_DIGEST` |
| `drain_pending.sh` | `STATE_ROOT`, `RUN_ID`, `OUTCOME` | `STAGE`, `PROJECT`, `IID`(或 `ISSUE_IID`), `ISSUE_URL`, `STATUS`(`done`\|`failed`\|`timeout`), `MR_URL`, `REASON` |
| `route_project.sh` | `PROJECT` | `ROUTING_FILE`, `DEFAULT_EXECUTOR_AGENT`（stdout：覆盖 executor、默认 executor 或 `__NO_ROUTE__`；合法 project 默认路由到 `DEFAULT_EXECUTOR_AGENT`；project 形态错/路由表文件缺失/格式错 exit 2） |
| `notify_user.sh` | `EVENT`(`result`\|`failure`) | `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / `DEFAULT_REPLY_AGENT`（仅当 `ORIGIN_JSON` 是合法 object 且缺 `reply_agent` 时兜底；空/null/非 object origin 不出站推 114）, `REPLY_NOTIFY_TIMEOUT_SECONDS`(默认 30), `ORIGIN_JSON`, `STATUS`, `IID`, `MR_URL`, `REASON` |
| `ops_notify.sh` | `EVENT` | `OPS_NOTIFY_CHANNEL`(空则 no-op), `RUN_ID`, `REASON`, `COUNT` |

`STATE_ROOT` / `GIT_ISSUER_AGENT` / `DEFAULT_EXECUTOR_AGENT` / `DOWNSTREAM_AGENT_TIMEOUT_SECONDS` / `EXECUTOR_AGENT_TIMEOUT_SECONDS` / `STUCK_AFTER_MINUTES` / `OPS_NOTIFY_CHANNEL` / `ROUTING_FILE` / `WIKI_GITLAB_HOST` / `WIKI_GITLAB_API_PROTOCOL` / `WIKI_GITLAB_TOKEN` / `WIKI_GLAB_BIN` / `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN` / `DEFAULT_REPLY_AGENT` / `REPLY_NOTIFY_TIMEOUT_SECONDS` / `DISPATCHER_CALLBACK_TARGET` / `EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS` / `EXECUTOR_QUEUE_LAUNCH_RETRY_BACKOFF_SECONDS` / `EXECUTOR_QUEUE_SPAWN_MAX_ATTEMPTS` / `EXECUTOR_QUEUE_SPAWN_RETRY_SLEEP_SECONDS` 由 `source scripts/source_dispatcher_env.sh` 注入：先读 tracked `config/dispatcher.env`，再读 ignored `config/dispatcher.local.env`（若存在，本机测试覆盖只写这里）。`capture_origin.sh` 只规范化来源元数据，不碰 state；`prepare_wiki_downstream_payloads.sh` 只读 wiki、拆分需求并准备建单消息，不写 GitLab、不碰 state；`prepare_downstream_payloads.sh` 只做自由文本建单入口分析与消息准备，不碰 state、不碰 GitLab；`prepare_executor_issue_payload.sh` 只做既有 issue 执行入口分析，不碰 state、不碰 GitLab；`build_executor_payload.sh` 只生成 executor trigger 文本；`enqueue_executor_issue.sh` 只追加 durable queue；`drain_executor_queue.sh` 是唯一启动 executor 的入口；`run_agent_turn.sh` 只调用 `openclaw agent` 并输出 envelope，不碰 GitLab；`route_project.sh` / `ops_notify.sh` 不碰 state（不读写 pending/ledger/锁）：前者只做 project→executor 查表/默认路由，后者只发 best-effort 告警。`notify_user.sh` 不碰 GitLab、不建 issue、不打标签——只在 `ORIGIN_JSON` 是合法 object 时经反向网关把结果信封投给 114 接收 agent；目标 agent 优先取 `ORIGIN_JSON.reply_agent`，没有时才用默认 `DEFAULT_REPLY_AGENT`。`ORIGIN_JSON` 为空/null/非 object 时视为手动入口，只写 ledger 留痕；网关 pin 未配置、目标 agent 缺失、投递失败或超时也记 ledger 留痕、不静默丢。

## No-Fallback（HARD）

- 脚本非零退出 → 读 stdout/stderr、分类、记录、**stop**。不内联重写脚本逻辑、不"手动来一遍"、不换"更简单的命令"。
- **不写 GitLab**：不得用任何 token 建 issue / 打标签 / 写 note / 跑 issue——建 issue 是 git_issuer 的事、跑 issue 是 req_executor 的事。唯一允许的 GitLab 访问是 `prepare_wiki_downstream_payloads.sh` 使用 `glab api` 只读拉取 wiki 页面内容。
- **先判动作，再做受控入口分析**：只建单动作必须用 `prepare_wiki_downstream_payloads.sh` 或 `prepare_downstream_payloads.sh` 生成 git_issuer payload；执行既有 issue 动作必须用 `prepare_executor_issue_payload.sh` 提取 `project` / `iid`；显式建单并执行动作先走 git_issuer，成功后才入 executor queue。若准备脚本失败，推用户失败说明并停止，不调用下游。不语义猜 project、不补写 project、不把 114/origin 包装原样发给下游。最终建单事实仍以 git_issuer 返回的 `project`/`issue_iid`/`issue_url` 为准。
- **所有合法 GitLab project 默认可路由**：`route_project.sh` 先查覆盖表，未命中时返回 `DEFAULT_EXECUTOR_AGENT`。`__NO_ROUTE__` 只表示默认执行器未配置且无覆盖；project 形态错、路由表文件缺失/格式错（exit 2）才是部署/回调形态错误，按 No-Fallback 停。
- **不去重**：透传语义；114 重发同建单需求会生成新的 git_issuer 调用，重发同执行请求会生成新的 executor queue item / pending，可能重复建 issue或重复执行（去重是 114/git_issuer/人工侧的事）。
- **git_issuer / executor 业务结果失败 → 不自动重试**（避免重复建 issue / 重复测；重试由用户重发需求）。
- git_issuer 下游调用失败（`run_agent_turn.sh` envelope `status=failed`）只允许"同 payload 3 次 2s 退避"这一种重试；耗尽即 `launch_failed`，不另寻他法。executor 启动失败由 `drain_executor_queue.sh` 对同一 `RUN_SINGLE_ISSUE` payload 做 3 次 2s 重试；耗尽后保留 active 为 `launch_failed`，等待后续 `RUN_EXECUTOR_QUEUE_DRAIN` 重试，不把 issue 从队列丢弃。
- origin 捕获固定使用 `capture_origin.sh`：优先读取 OpenClaw 网关/运行时来源元数据，才 fallback 到文本 `[origin]` 行；跨 agent 调用固定使用 `run_agent_turn.sh` 包装 `openclaw agent`，executor 结果回调使用 `RUN_EXECUTOR_RESULT_CALLBACK` + `worker_result_json`，`correlation_id` 由 `next_correlation_id.sh` 生成。用户出站推送已对齐：`notify_user.sh` 仅在 origin 为合法 object 时反向网关推 114 接收 agent，连接 pin 为 `REPLY_GATEWAY_URL` / `REPLY_GATEWAY_TOKEN`，目标 agent 优先取 `origin.reply_agent`、否则取默认 `DEFAULT_REPLY_AGENT`；空/null/非 object origin 视为手动入口不推 114。

若你发现自己要用一个 SKILL / 脚本 / references 里没列出的工具、命令、flag 或流程，那就是**停下并失败**的信号，而不是更努力地试。

## Chat Output Policy

orchestrator 每轮只回一条紧凑状态摘要：接入路径 → `{path:"intake", action, outcome, project?, iid?, issue_url?, queue_id?, queue_drain_status?}`；executor 回调路径 → `{path:"executor_cb", run_id, status, iid?, notified, queue_finish_status?, queue_drain_status?}`；队列 drain 路径 → `{path:"executor_queue_drain", status, active?, queued_count?}`。详细证据只落 disk（`ledger.jsonl` / `executor_queue.json`），不进 chat。

## Where to look

- agent 灵魂、Global Rules、Session Policy：[`../../SOUL.md`](../../SOUL.md)。
- 工作区说明、agent 身份、执行模型、req_executor 衔接依赖：[`../../AGENTS.md`](../../AGENTS.md)。
- 114 调用方式、ack 文案、配置项：[`../../USER.md`](../../USER.md)。
- state / ledger schema（两段 pending、I3）：[`references/state_schema.md`](references/state_schema.md)。
- `run_agent_turn.sh` 调用契约 + executor RUN_SINGLE_ISSUE(I1)/结果回调(I2) 信封：[`references/trigger_command.md`](references/trigger_command.md)。
- 默认执行器路由、覆盖路由表与用户结果推送 pin 配置（`REPLY_*`）：[`../../config/README.md`](../../config/README.md)、[`../../config/routing.env`](../../config/routing.env)。
- git_issuer 产出/变更对接文档（跨团队，运行时不必读）：[`../../docs/integration/gitissuer_contract.md`](../../docs/integration/gitissuer_contract.md)、[`../../docs/integration/gitissuer_change_request.md`](../../docs/integration/gitissuer_change_request.md)。

存疑时 READ 对应 reference，不要凭记忆重构契约。
