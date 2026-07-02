# Trigger / 跨 agent 调用契约

> 状态：**已落成明确契约**。`req_dispatcher` 发起下游 agent turn 固定通过 `scripts/run_agent_turn.sh` 包装 `openclaw agent`；executor 结果回调固定为 `RUN_EXECUTOR_RESULT_CALLBACK` + `worker_result_json=<I2>`。不再使用未确认参数名的旧占位原语。
>
> 编排器对一条需求做两段下游调用：先调用蓝区 `git_issuer` 建 issue 并读取其最后一行 JSON；成功后按 project 路由选 executor，再调用该 executor 的 `RUN_SINGLE_ISSUE`。git_issuer 段只做本轮审计 record/drain；executor 段记录 pending，等待后续 I2 结果回调。

## 接入消息（114 → req_dispatcher）

- 形态：自由文本，经网关 `agent run --agent req_dispatcher "<需求原文>" --deliver`（架构图"114 侧调用特定 agent"方式 A）或等价 HTTP 桥接（方式 B）。
- req_dispatcher 收到的就是一段需求文本，**不是结构化 trigger 信封**。orchestrator 据"路径判定"识别为接入路径。
- `req_dispatcher` 整段原样透传给 git_issuer，不解析需求语义。

## origin 元数据（运行时来源优先，文本兜底）

- 编排器需把处理结果推回**发起需求的企微用户**，故接入时要 capture **origin 元数据** `{channel,user,conversation,reply_agent}`（仅供回推用，**不是**解析需求语义/project）。`reply_agent` 是 114 上接收终态结果的 agent 名，用来支持任意 114 agent 作为调用方。
- 捕获入口固定为 `scripts/capture_origin.sh`。优先级：
  1. OpenClaw 网关/运行时给出的结构化 origin JSON，例如 `OPENCLAW_DELIVER_ORIGIN_JSON` / `OPENCLAW_SOURCE_ORIGIN_JSON`。
  2. OpenClaw 网关/运行时给出的离散来源字段，例如 `OPENCLAW_SOURCE_AGENT` / `OPENCLAW_SOURCE_SESSION` / `OPENCLAW_DELIVER_USER` / `OPENCLAW_DELIVER_CONVERSATION`。只有 session key 且形如 `agent:<agent>:<session>` 时，脚本会推导 `reply_agent=<agent>`。
  3. 需求文本里的显式 fallback 行：`[origin] channel=<channel> user=<user> conversation=<conversation> reply_agent=<agent>`。
- 当前实现不因 capture 不到 origin 而阻断主流程；`ORIGIN_JSON` 不传时 entry 里 origin = `null`，`notify_user.sh` 仍会把 `origin:null` 放进结果信封。目标 agent 优先取 `origin.reply_agent`，没有时才用默认 `DEFAULT_REPLY_AGENT`；缺少网关 pin 或目标 agent 时仅 ledger 留痕。

# §1 git_issuer 段（建 issue）

## 下游 agent 调用（req_dispatcher → git_issuer）

固定脚本契约：

```bash
cd "<SKILL_DIR>" && \
source scripts/source_dispatcher_env.sh && \
TARGET_AGENT="${GIT_ISSUER_AGENT}" \
TARGET_SESSION_KEY="agent:${GIT_ISSUER_AGENT}:main" \
AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}" \
bash scripts/run_agent_turn.sh <<'EOF'
<需求原文>
EOF
```

`run_agent_turn.sh` 调用的底层 CLI 形态固定为：

```bash
openclaw agent --agent <TARGET_AGENT> --session-key <TARGET_SESSION_KEY> --message <payload> --timeout <AGENT_TIMEOUT_SECONDS>
```

stdout 固定是一行 JSON envelope：

```json
{"status":"success|failed","target_agent":"git_issuer","child_session_key":"agent:git_issuer:main","run_id":"openclaw-git_issuer-...","exit_code":0,"worker_result_json":{...},"raw_output":"..."}
```

- `status=failed` 表示 `openclaw agent` 调用失败；脚本仍 `exit 0`，由 orchestrator 做同 payload 3 次 2s 退避。
- 入参形态错误（缺 `TARGET_AGENT`、消息为空、timeout 非正整数等）才 `exit 2`，按 No-Fallback 停。
- `worker_result_json` 来自目标 agent 输出中的最后一行 JSON；蓝区 `git_issuer` 必须把回调 JSON 放在最后一行。

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

> **drain git_issuer 段 ≠ 链路终点**：success 时 drain git_issuer 段只是收尾审计 stage，编排器随即按 project 路由起 executor 段（§2）；failed/no_route 时 drain 并推用户。

## 匹配策略（git_issuer 段）

- **主：`run_id`**。接入路径用 `run_agent_turn.sh` envelope 的 `run_id` 记 `pending[run_id]`（`stage=git_issuer`），同一轮 drain。**不要求 git_issuer 回显任何 req_dispatcher token**，对蓝区 git_issuer 零侵入。
- **匹配不到 pending**：重复 drain 或审计行已被清理时，仍照常调 `drain_pending.sh`，写 `was_pending=false` 审计行。

---

# §2 executor 段（驱动 req_executor 单次 issue 执行）

git_issuer 返回成功 JSON 后，编排器按 `project` 调 `route_project.sh` 选目标 req_executor 部署 agent：覆盖表命中则用专属 executor，未命中则用 `DEFAULT_EXECUTOR_AGENT`。随后调用其 `RUN_SINGLE_ISSUE` driven 入口，并记一条**新** `pending[run_id2]`（`stage=executor`）。executor Phase 6 终态回调结果，编排器据 `run_id2` 或 `correlation_id` drain、把结论 `notify_user.sh` 推回 origin。

## 下游 agent 调用（req_dispatcher → req_executor）

同样使用 `run_agent_turn.sh`：

```bash
cd "<SKILL_DIR>" && \
source scripts/source_dispatcher_env.sh && \
TARGET_AGENT="<route_project.sh stdout>" \
TARGET_SESSION_KEY="agent:<executor>:main" \
AGENT_TIMEOUT_SECONDS="${DOWNSTREAM_AGENT_TIMEOUT_SECONDS:-600}" \
bash scripts/run_agent_turn.sh <<EOF
RUN_SINGLE_ISSUE
project=<group/project>
iid=<issue_iid>
correlation_id=<reqd-n>
dispatcher_callback_target=${DISPATCHER_CALLBACK_TARGET}
EOF
```

返回 envelope 的 `run_id` 即 executor 段 `pending[run_id2]` 主键，`child_session_key` 写入 pending 便于审计。若 envelope `status=failed`，同 payload 最多 3 次、2s 退避；耗尽 = `launch_failed`，推用户"已建 issue #<iid> 但未能启动处理"。

### (I1) RUN_SINGLE_ISSUE 入参（req_dispatcher 构造，发往 executor orchestrator session `agent:req_executor:main`）

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

- 用途：req_dispatcher 调用 executor 时生成、随 I1 下发，执行器原样回显在 I2 `correlation_id`——**作 executor 回调的二次校验**（防 run_id 错配）；主匹配仍 `run_id2`。
- 生成机制已实现：`scripts/next_correlation_id.sh` 在 `${STATE_ROOT}/_dispatcher/seq` 上用 flock 单调递增，stdout 输出 `reqd-<n>`。不要用随机数或时间戳替代。

## 结果回调 trigger（req_executor 完成 → req_dispatcher）

本地对齐形态：

- 回调 trigger 名称：`RUN_EXECUTOR_RESULT_CALLBACK`。
- 执行器结果 JSON（下面 I2）承载字段：`worker_result_json=<I2 JSON>`。
- 若运行时回调携带 executor `run_id`（= `run_id2`），executor 回调路径优先用 `RUN_ID` 查 pending；若 `openclaw agent` 回投消息不带运行时 `run_id`，用 `CORRELATION_ID` 调 `scripts/find_pending.sh` 反查 pending，再取 entry 的 `run_id` drain。

### (I2) 执行器结果回调信封（executor Phase 6 终态发出，一行紧凑 JSON）

```json
{"correlation_id":"<回显 I1 的值>","iid":<int>,"project":"<group/project>","status":"done|failed|timeout","mr_url":<string|null>,"wiki_url":<string|null>,"reason":<string|null>}
```

- `status` 取执行器 `final_status`（`done`/`failed`/`timeout`；`blocked` 不回调——可重试态，等下一 attempt 或停放）。
- 承载该 JSON 的跨 agent 回调信封字段名 = `worker_result_json`。

### I2 字段 → notify_user / drain_pending env（运行时解析契约，已定）

executor 回调路径从 I2 取值，分别填 `notify_user.sh`（推用户）与 `drain_pending.sh`（写 ledger + 删 pending）的 env：

| I2 JSON 字段 | notify_user env | drain_pending env | 备注 |
|---|---|---|---|
| `status`（`done`\|`failed`\|`timeout`） | `STATUS` | `STATUS` + 映射 `OUTCOME`（`done`→`success`，`failed`/`timeout`→`failed`） | `STATUS` 透传精确终态；`OUTCOME` 是 drain 二值。 |
| `iid` | `IID` | `IID` | 正整数。 |
| `project` | —（不取） | `PROJECT` | 审计用。 |
| `mr_url` | `MR_URL` | `MR_URL` | `done` 才有。 |
| `wiki_url` | `WIKI_URL` | —（不取） | `failed` 文案的详情链接。 |
| `reason` | `REASON` | `REASON` | `failed`/`timeout` 才有。 |
| `correlation_id` | —（不取） | —（不取） | **二次校验**：须 = pending entry 的 `correlation_id`（防 run_id 错配）。 |
| —（不取） | `ORIGIN_JSON` | —（不取） | **取自 `pending[run_id2].origin`**（接入时 capture、全程随两段携带），非来自 I2；其中 `reply_agent` 决定回推到哪个 114 agent。 |
| —（不取） | —（`EVENT=result` 固定） | `STAGE=executor` 固定 | — |

`drain_pending.sh` 的 `RUN_ID` **优先来自 runtime 回调自带的 `run_id`（=`run_id2`）**；若当前回调消息不带 runtime `run_id`，用 `find_pending.sh` 按 I2 `correlation_id` 反查 pending，并取返回 entry 的 `run_id`。

## 匹配策略（executor 段）

- **主：`run_id2`**（= 调用 executor 后 `run_agent_turn.sh` envelope 的 `run_id`，由 `record_pending.sh` 记为 `RUN_ID`）。executor 回调若带 runtime `run_id`，直接用它查 pending 并 drain。
- **无 run_id 回调：`correlation_id` 反查**。当前 `notify_dispatcher.sh` 经 `openclaw agent` 投递的 `RUN_EXECUTOR_RESULT_CALLBACK` 不携带 runtime `run_id`，因此 req_dispatcher 用 I2 的 `correlation_id` 调 `find_pending.sh` 找到 executor pending entry，再以 entry.run_id drain。
- **二次校验：`correlation_id`**（I2 回显值须 = pending entry 的 `correlation_id`）——防 run_id 错配。不一致：记紧凑告警、以 `run_id` 为准 drain，不臆造。
- **匹配不到 pending**：迟到 / 重复 / 已被 stuck 驱逐的回调，仍照常 `drain_pending.sh`（`STAGE=executor`、`was_pending=false`）——预期情形、非错误。

## 三条逻辑路径（已定，详见 SKILL.md）

- **接入路径（A）**：capture origin → evict_stuck → `run_agent_turn(git_issuer)` → `record_pending(run_id, stage=git_issuer, origin)` → 解析 `{status,project,iid,url}` → 成功则 `route_project` 选 executor（默认 `DEFAULT_EXECUTOR_AGENT` 覆盖所有合法 project）→ `run_agent_turn(<executor>, RUN_SINGLE_ISSUE)` → `record_pending(run_id2, stage=executor, project/iid/correlation_id/origin)` → drain git_issuer 段 → 最小 ack。
- **executor 回调路径（C）**：解析 I2 → 按 `run_id2` 匹配 executor 段，或在回调缺 `run_id` 时按 `correlation_id` 反查（`correlation_id` 二次校验）→ `notify_user(result)` 推回 origin → drain executor 段。
