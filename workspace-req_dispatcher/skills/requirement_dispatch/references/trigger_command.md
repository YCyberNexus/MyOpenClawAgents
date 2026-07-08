# Trigger / 跨 agent 调用契约

> 状态：**已落成明确契约**。`req_dispatcher` 发起下游 agent turn 固定通过 `scripts/run_agent_turn.sh` 包装 `openclaw agent`；executor 结果回调固定为 `RUN_EXECUTOR_RESULT_CALLBACK` + `worker_result_json=<I2>`。不再使用未确认参数名的旧占位原语。
>
> 编排器对一条需求做两段下游调用：入口消息若包含 GitLab wiki URL，先用 `prepare_wiki_downstream_payloads.sh` 只读拉取 wiki Markdown、拆分需求并生成一组面向 `git_issuer` 的标准化建单消息；否则用 `prepare_downstream_payloads.sh` 从自由文本中的 `group/project`、GitLab 仓库/Wiki URL，或 `glab api projects/<encoded-group%2Fproject>/...` 片段确定性提取 project 并整理成单条建单消息。随后调用蓝区 `git_issuer` 建 issue 并读取其 `worker_result_json`；成功后按 project 路由选 executor，把 issue 追加到 durable `executor_queue.json`，再由 `drain_executor_queue.sh` 为队首生成并调用该 executor 的 `RUN_SINGLE_ISSUE`。git_issuer 段只做本轮审计 record/drain；executor 段由队列 active 记录 pending，等待后续 I2 结果回调。

## 接入消息（114 → req_dispatcher）

- 形态：自由文本，经网关 `agent run --agent req_dispatcher "<需求原文或 wiki URL>" --deliver`（架构图"114 侧调用特定 agent"方式 A）或等价 HTTP 桥接（方式 B）。
- req_dispatcher 收到的就是一段需求文本，**不是结构化 trigger 信封**。orchestrator 据"路径判定"识别为接入路径。
- `req_dispatcher` 不再把这段文本原样透传给 git_issuer。若文本里有 GitLab wiki URL，它调用 `scripts/prepare_wiki_downstream_payloads.sh` 从 URL 解析 `group/project`、读取 wiki 并拆分为多条 `git_issuer_payloads`。若没有 wiki URL，则调用 `scripts/prepare_downstream_payloads.sh` 剥离 114/origin 包装，并从 `group/project`、GitLab 仓库/Wiki URL，或 `glab api projects/<encoded-group%2Fproject>/...` 片段中确定性提取 project，生成带 `repo=<group/project>` 的单条 `git_issuer_payload`。入口准备失败时，req_dispatcher 直接推用户失败说明，不调用 git_issuer。

## origin 元数据（运行时来源优先，文本兜底）

- 编排器需把处理结果推回**发起需求的企微用户**，故接入时要 capture **origin 元数据** `{channel,user,conversation,reply_agent}`（仅供回推用，**不是**解析需求语义/project）。`reply_agent` 是 114 上接收终态结果的 agent 名，用来支持任意 114 agent 作为调用方。
- 捕获入口固定为 `scripts/capture_origin.sh`。优先级：
  1. OpenClaw 网关/运行时给出的结构化 origin JSON，例如 `OPENCLAW_DELIVER_ORIGIN_JSON` / `OPENCLAW_SOURCE_ORIGIN_JSON`。
  2. OpenClaw 网关/运行时给出的离散来源字段，例如 `OPENCLAW_SOURCE_AGENT` / `OPENCLAW_SOURCE_SESSION` / `OPENCLAW_DELIVER_USER` / `OPENCLAW_DELIVER_CONVERSATION`。只有 session key 且形如 `agent:<agent>:<session>` 时，脚本会推导 `reply_agent=<agent>`。
  3. 需求文本里的显式 fallback 行：`[origin] channel=<channel> user=<user> conversation=<conversation> reply_agent=<agent>`。
- 当前实现不因 capture 不到 origin 而阻断主流程；`ORIGIN_JSON` 不传时 entry 里 origin = `null`。`notify_user.sh` 只有在 `ORIGIN_JSON` 是合法 object 时才允许出站推 114：目标 agent 优先取 `origin.reply_agent`，没有时才用默认 `DEFAULT_REPLY_AGENT`；`ORIGIN_JSON` 为空/null/非 object 时视为手动入口，只写 ledger 留痕，不调用 114。

# §1 git_issuer 段（建 issue）

## 消息准备（req_dispatcher 本地）

wiki 入口固定脚本契约：

```bash
cd "<SKILL_DIR>" && \
source scripts/source_dispatcher_env.sh && \
MESSAGE="<含 GitLab wiki URL 的需求原文>" FETCH_WIKI=1 \
bash scripts/prepare_wiki_downstream_payloads.sh
```

成功输出：

```json
{"status":"success","project":"claw_gitlab/px_ifp_hulat_test","wiki_url":"http://<host>/claw_gitlab/px_ifp_hulat_test/-/wikis/product/requirements","wiki_slug":"product/requirements","requirements":[{"ordinal":1,"title":"Login flow","body":"...","wiki_url":"...","wiki_section":"Login flow"}],"git_issuer_payloads":["CREATE_GITLAB_ISSUE\nrepo=claw_gitlab/px_ifp_hulat_test\nsource=req_dispatcher_wiki\n..."],"reason":null}
```

自由文本入口固定脚本契约：

```bash
cd "<SKILL_DIR>" && \
MESSAGE="<需求原文>" \
bash scripts/prepare_downstream_payloads.sh
```

成功输出：

```json
{"status":"success","project":"ai-infra/veqp_server_v3","requirement_text":"开发虚拟机台状态机...","git_issuer_payload":"CREATE_GITLAB_ISSUE\nrepo=ai-infra/veqp_server_v3\n...","reason":null}
```

失败输出：

```json
{"status":"failed","project":null,"requirement_text":"开发虚拟机台状态机...","git_issuer_payload":null,"reason":"需求文本未包含可识别的 GitLab project（格式 group/project），请补充目标 group/project 或具体 GitLab/Wiki URL"}
```

`status=failed` 是入口信息不足，不是 git_issuer 失败；req_dispatcher 应推用户失败说明并停止本路径。wiki 成功时按 `git_issuer_payloads[]` 顺序逐条执行后续 git_issuer → executor 流程；自由文本成功时把 `git_issuer_payload` 当成长度为 1 的列表。

## 下游 agent 调用（req_dispatcher → git_issuer）

固定脚本契约：

```bash
cd "<SKILL_DIR>" && \
source scripts/source_dispatcher_env.sh && \
TARGET_AGENT="${GIT_ISSUER_AGENT}" \
AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}" \
bash scripts/run_agent_turn.sh <<'EOF'
<当前 git_issuer payload>
EOF
```

`run_agent_turn.sh` 调用的底层 CLI 形态固定为：

```bash
openclaw agent --agent <TARGET_AGENT> --session-id <TARGET_SESSION_ID> --message <payload> --timeout <AGENT_TIMEOUT_SECONDS>
```

stdout 固定是一行 JSON envelope：

```json
{"status":"success|failed","target_agent":"git_issuer","child_session_key":"agent:git_issuer:main","run_id":"openclaw-git_issuer-...","exit_code":0,"worker_result_json":{...},"raw_output":"..."}
```

- `status=failed` 表示 `openclaw agent` 调用失败；脚本仍 `exit 0`，由 orchestrator 做同 payload 3 次 2s 退避。
- 入参形态错误（缺 `TARGET_AGENT`、消息为空、timeout 非正整数等）才 `exit 2`，按 No-Fallback 停。
- `TARGET_SESSION_ID` 默认由脚本生成，并统一通过 `--session-id` 传给 OpenClaw CLI：普通调用为 `agent:${TARGET_AGENT}:main`；`RUN_SINGLE_ISSUE` 为 `agent:${TARGET_AGENT}:issue-<sanitized-project>-<iid>`。历史环境变量 `TARGET_SESSION_KEY` 仍可作为兼容输入，但也会转为 `--session-id`；若旧上下文显式传了 `agent:${TARGET_AGENT}:main`，`RUN_SINGLE_ISSUE` 仍会改投 issue 级 session。普通下游调用不要手写这两个变量；脚本会拒绝包含省略号或尖括号的占位符 session selector。
- `DOWNSTREAM_AGENT_TIMEOUT_SECONDS` 是通用配置下限；即使单次调用传入更短的 `AGENT_TIMEOUT_SECONDS`，脚本也会提升到该下限，避免本机或蓝区下游 agent 启动被过短超时截断。executor 目标还会叠加 `EXECUTOR_AGENT_TIMEOUT_SECONDS` 专用下限。
- 下游 agent turn 可能超过本地 shell tool 的短轮询窗口；`run_agent_turn.sh` 等待时会按 `RUN_AGENT_TURN_HEARTBEAT_SECONDS`（默认 30）向 stderr 输出 heartbeat，stdout 仍只保留最终 JSON envelope。若 tool 返回进程仍在运行，继续 poll 到进程完成并读取最终 stdout，不要因为暂时无新输出而 kill。
- `worker_result_json` 优先来自目标 agent 输出中的最后一行紧凑 JSON；若下游把 pretty JSON 放在 Markdown 代码块里，`run_agent_turn.sh` 会兜底提取最后一个合法 JSON object。蓝区 `git_issuer` 仍推荐把回调 JSON 放在最后一行，代码块兼容只用于容错。

### git_issuer JSON → drain_pending env（运行时解析契约）

orchestrator 从 `run_agent_turn.sh` envelope 的 `worker_result_json` 取值，填入 `drain_pending.sh` 的 env：

| git_issuer JSON 字段 | drain_pending env | 备注 |
|----------------------|-------------------|------|
| `status`（`success`\|`failed`） | `OUTCOME` | 原样透传；`launch_failed` 不来自 git_issuer（下游调用失败耗尽重试时 req_dispatcher 自合成）。 |
| `issue_iid` | `ISSUE_IID`（或 `IID`） | success 才有；同时透传给 §2 调用 executor 的 I1 `iid`。 |
| `issue_url` | `ISSUE_URL` | success 才有。 |
| `project` | `PROJECT`（drain 审计） | success 才有；**主要消费方是 `route_project.sh`**（按它选 executor）与 I1 `project`。 |
| `reason` | `REASON` | failed 才有。 |
| —（恒定） | `STAGE=git_issuer` | drain 该段固定写 `STAGE=git_issuer`。 |
| —（不取） | `RUN_ID` | 来自 `run_agent_turn.sh` envelope 的 `run_id`，不取自这段 JSON。 |

`entry_label` / `action` / `superseded_by` 等字段供审计/排查，orchestrator 不强依赖。完整字段表与变更场景的 `action` 扩展见 docs/integration 下的两份对接文档。

> **drain git_issuer 段 ≠ 链路终点**：success 时 drain git_issuer 段只是收尾审计 stage，编排器随即按 project 路由并把 issue 入 executor FIFO queue（§2）；failed/no_route 时 drain 并推用户。

## 匹配策略（git_issuer 段）

- **主：`run_id`**。接入路径用 `run_agent_turn.sh` envelope 的 `run_id` 记 `pending[run_id]`（`stage=git_issuer`），同一轮 drain。**不要求 git_issuer 回显任何 req_dispatcher token**，对蓝区 git_issuer 零侵入。
- **匹配不到 pending**：重复 drain 或审计行已被清理时，仍照常调 `drain_pending.sh`，写 `was_pending=false` 审计行。

---

# §2 executor 段（驱动 req_executor 单次 issue 执行）

git_issuer 返回成功 JSON 后，编排器按 `project` 调 `route_project.sh` 选目标 req_executor 部署 agent：覆盖表命中则用专属 executor，未命中则用 `DEFAULT_EXECUTOR_AGENT`。随后必须调用 `enqueue_executor_issue.sh` 把 issue 追加到 `${STATE_ROOT}/_dispatcher/executor_queue.json`；只有 `drain_executor_queue.sh` 可以把队首 issue 认领为 active、调用其 `RUN_SINGLE_ISSUE` driven 入口，并在 executor 明确进入等待回调状态后记一条**新** executor pending（`stage=executor`）。executor Phase 6 终态回调结果，编排器据 executor `run_id` 或 `correlation_id` drain、把结论 `notify_user.sh` 推回 origin。

## 入队与下游 agent 调用（req_dispatcher → req_executor）

接入路径不得直接调用 executor。先入队：

```bash
cd "<SKILL_DIR>" && \
source scripts/source_dispatcher_env.sh && \
PROJECT="<group/project>" IID="<issue_iid>" ISSUE_URL="<issue_url>" \
EXECUTOR_AGENT="<route_project.sh stdout>" \
ORIGIN_JSON="<origin_json 或空>" \
REQ_DIGEST="<当前需求条目摘要 或空>" \
bash scripts/enqueue_executor_issue.sh
```

然后由 `drain_executor_queue.sh` 内部生成 payload 并调用 `run_agent_turn.sh`：

```bash
cd "<SKILL_DIR>" && \
source scripts/source_dispatcher_env.sh && \
PROJECT="<group/project>" IID="<issue_iid>" \
CORRELATION_ID="<reqd-n>" \
DISPATCHER_CALLBACK_TARGET="${DISPATCHER_CALLBACK_TARGET}" \
bash scripts/build_executor_payload.sh
```

再把上一条命令的 stdout 作为 payload 调用目标 executor：

```bash
cd "<SKILL_DIR>" && \
source scripts/source_dispatcher_env.sh && \
TARGET_AGENT="<route_project.sh stdout>" \
AGENT_TIMEOUT_SECONDS="${EXECUTOR_AGENT_TIMEOUT_SECONDS:-${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}}" \
bash scripts/run_agent_turn.sh <<EOF
<build_executor_payload.sh stdout>
EOF
```

executor queue active 的稳定 `run_id` 即 executor 段 pending 主键。`drain_executor_queue.sh` 在认领 active 时先写 executor pending 占位，避免 executor 子任务很快回调时找不到 pending；启动成功后补 `child_session_key` 便于审计。启动成功必须同时满足外层 envelope `status=success`，以及 executor `worker_result_json.status="waiting_for_callbacks"` 或 raw output 含 `waiting_for_callbacks`（兼容 req_executor 现有纯文本 `chat_summary` 输出）；其他状态会删除 pending 占位，把 active 标为 `launch_failed` 并等待后续 `RUN_EXECUTOR_QUEUE_DRAIN` 重试。同 payload 单次 drain 最多 3 次、2s 退避；耗尽 = `launch_failed`，不推用户终态，因为 issue 仍保留在 active 等恢复。如果 executor 在初始 turn 返回前已完成并回调，drain 返回 `active_changed_after_launch`，不再补写旧 pending。

### (I1) RUN_SINGLE_ISSUE 入参（req_dispatcher 构造，默认发往 executor issue 级 session）

`run_agent_turn.sh` 对 I1 调用会从 payload 的 `project` 与 `iid` 自动生成 session id：`agent:<executor>:issue-<sanitized-project>-<iid>`，例如 `agent:req_executor:issue-ai-infra-veqp-server-v3-11`。若旧上下文显式传了 `agent:<executor>:main`，wrapper 会改投 issue 级 session；不要把多个 I1 固定投到 `agent:req_executor:main`。

多行 key=value（沿用现有 trigger 文本格式）：

```
RUN_SINGLE_ISSUE
project=<group/project，git_issuer 返回透传>
iid=<正整数，要测的 issue IID>
correlation_id=<req_dispatcher 生成的关联 token>
dispatcher_callback_target=<回调目标 = ${DISPATCHER_CALLBACK_TARGET}>
group=<可选，缺省取执行器 pin 配置>
```

| 字段 | 必填 | 来源 |
|---|---|---|
| `project` | 是 | git_issuer 返回透传的 `project`。 |
| `iid` | 是 | git_issuer 返回透传的 `issue_iid`（正整数）。 |
| `correlation_id` | 是 | req_dispatcher 生成（见 §correlation_id），原样回显在 I2 供二次校验。 |
| `dispatcher_callback_target` | 是 | `config/dispatcher.env` 的 `DISPATCHER_CALLBACK_TARGET`（支持 `agent:req_dispatcher:main`；留空则执行器侧 `notify_dispatcher.sh` no-op）。 |
| `group` | 否 | 缺省取执行器 pin 配置。 |

**其余 campaign 字段一律不传**（`gitlab_token`/`branch`/`dev_branch`/`quota`/`concurrency`/… 全部由执行器侧 `config/campaign_defaults.env` pin，token 永不经 req_dispatcher）。

### §correlation_id（executor 段二次校验 token）

- 用途：req_dispatcher 调用 executor 时生成、随 I1 下发，执行器原样回显在 I2 `correlation_id`——**作 executor 回调的二次校验**（防 run_id 错配）；主匹配仍 executor `run_id`。
- 生成机制已实现：`scripts/next_correlation_id.sh` 在 `${STATE_ROOT}/_dispatcher/seq` 上用 flock 单调递增，stdout 输出 `reqd-<n>`。不要用随机数或时间戳替代。

## 结果回调 trigger（req_executor 完成 → req_dispatcher）

本地对齐形态：

- 回调 trigger 名称：`RUN_EXECUTOR_RESULT_CALLBACK`。
- 执行器结果 JSON（下面 I2）承载字段：`worker_result_json=<I2 JSON>`。
- 若运行时回调携带 executor `run_id`，executor 回调路径优先用 `RUN_ID` 查 pending；若 `openclaw agent` 回投消息不带运行时 `run_id`，用 `CORRELATION_ID` 调 `scripts/find_pending.sh` 反查 pending，再取 entry 的 `run_id` drain。

### (I2) 执行器结果回调信封（executor Phase 6 终态发出，一行紧凑 JSON）

```json
{"correlation_id":"<回显 I1 的值>","iid":<int>,"project":"<group/project>","status":"done|failed|timeout","mr_url":<string|null>,"wiki_url":<string|null>,"reason":<string|null>}
```

- `status` 取执行器 `final_status`（`done`/`failed`/`timeout`；`blocked` 不回调——可重试态，等下一 attempt 或停放）。
- `wiki_url` 为旧执行器兼容字段；req_dispatcher 不再消费或转发执行证据 Wiki 链接。
- 承载该 JSON 的跨 agent 回调信封字段名 = `worker_result_json`。

### I2 字段 → notify_user / drain_pending env（运行时解析契约，已定）

executor 回调路径从 I2 取值，分别填 `notify_user.sh`（推用户）与 `drain_pending.sh`（写 ledger + 删 pending）的 env：

| I2 JSON 字段 | notify_user env | drain_pending env | 备注 |
|---|---|---|---|
| `status`（`done`\|`failed`\|`timeout`） | `STATUS` | `STATUS` + 映射 `OUTCOME`（`done`→`success`，`failed`/`timeout`→`failed`） | `STATUS` 透传精确终态；`OUTCOME` 是 drain 二值。 |
| `iid` | `IID` | `IID` | 正整数。 |
| `project` | —（不取） | `PROJECT` | 审计用。 |
| `mr_url` | `MR_URL` | `MR_URL` | `done` 才有。 |
| `wiki_url` | —（不取） | —（不取） | 兼容旧 executor 信封；忽略。 |
| `reason` | `REASON` | `REASON` | `failed`/`timeout` 才有。 |
| `correlation_id` | —（不取） | —（不取） | **二次校验**：须 = pending entry 的 `correlation_id`（防 run_id 错配）。 |
| —（不取） | `ORIGIN_JSON` | —（不取） | **取自 executor pending entry 的 `origin`**（接入时 capture、经 executor queue 携带），非来自 I2；只有合法 object 才允许出站推 114，其中 `reply_agent` 决定回推到哪个 114 agent。 |
| —（不取） | —（`EVENT=result` 固定） | `STAGE=executor` 固定 | — |

`drain_pending.sh` 的 `RUN_ID` **优先来自 runtime 回调自带的 executor `run_id`**；若当前回调消息不带 runtime `run_id`，用 `find_pending.sh` 按 I2 `correlation_id` 反查 pending，并取返回 entry 的 `run_id`。

## 匹配策略（executor 段）

- **主：executor `run_id`**（= executor queue active 的稳定 `run_id`，启动成功后由 `record_pending.sh` 记为 `RUN_ID`）。executor 回调若带 runtime `run_id`，直接用它查 pending 并 drain。
- **无 run_id 回调：`correlation_id` 反查**。当前 `notify_dispatcher.sh` 经 `openclaw agent` 投递的 `RUN_EXECUTOR_RESULT_CALLBACK` 不携带 runtime `run_id`，因此 req_dispatcher 用 I2 的 `correlation_id` 调 `find_pending.sh` 找到 executor pending entry，再以 entry.run_id drain。
- **二次校验：`correlation_id`**（I2 回显值须 = pending entry 的 `correlation_id`）——防 run_id 错配。不一致：记紧凑告警、以 `run_id` 为准 drain，不臆造。
- **匹配不到 pending**：迟到 / 重复 / 已被 stuck 驱逐的回调，仍照常 `drain_pending.sh`（`STAGE=executor`、`was_pending=false`）——预期情形、非错误。

## 三条逻辑路径（已定，详见 SKILL.md）

- **接入路径（A）**：capture origin → wiki URL 走 `prepare_wiki_downstream_payloads` 生成 `git_issuer_payloads[]`，自由文本走 `prepare_downstream_payloads` 确定性提取 project 并生成单条 `git_issuer_payload`，无法确定 project 时推用户失败并停止 → evict_stuck → 对每个 payload 顺序 `run_agent_turn(git_issuer, payload)` → `record_pending(run_id, stage=git_issuer, origin)` → 解析 `{status,project,iid,url}` → 成功则 `route_project` 选 executor（默认 `DEFAULT_EXECUTOR_AGENT` 覆盖所有合法 project）→ `enqueue_executor_issue` → drain git_issuer 段 → `drain_executor_queue` 尝试启动队首 → 最小 ack。
- **executor 回调路径（B）**：解析 I2 → 按 executor `run_id` 匹配 executor 段，或在回调缺 `run_id` 时按 `correlation_id` 反查（`correlation_id` 二次校验）→ `notify_user(result)` 在 origin 为合法 object 时推回 114，否则只留痕 → drain executor 段 → `finish_executor_queue_active` → `drain_executor_queue` 继续推进下一条。
- **executor 队列恢复路径（C）**：收到 `RUN_EXECUTOR_QUEUE_DRAIN` → `evict_stuck` 清理过期 pending 和匹配 active → `drain_executor_queue` 恢复或推进队列。
