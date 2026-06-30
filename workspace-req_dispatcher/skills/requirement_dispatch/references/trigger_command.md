# Trigger / 跨 agent 原语契约

> 状态：**部分待对齐**。下面"接入消息"与"三条逻辑路径"已定；两段"跨 agent spawn 原语"（→git_issuer、→req_executor）与两类"回调 trigger"（git_issuer 完成、executor 结果）的确切工具名/字段**待与 OpenClaw 维护者/同事对齐**（标注 ⚠️ 处）。架构不依赖这些具体取值——两段匹配都以各自 `run_id` 为主，故即便对齐前也能推进设计与脚本。
>
> 编排器对一条需求做**两段异步 spawn**：先 git_issuer 段（建 issue），其回调成功后按 project 路由选 executor、再起 executor 段（驱动 req_executor 单次 issue 执行）。每段各记一条 pending（各自 `run_id`、`stage` 区分），各自回调 drain。下面 §1 是 git_issuer 段（沿用旧契约），§2 是新增的 executor 段（I1 入参 + I2 结果回调）。

## 接入消息（114 → req_dispatcher）

- 形态：自由文本，经网关 `agent run --agent req_dispatcher "<需求原文>" --deliver`（架构图"114 侧调用特定 agent"方式 A）或等价 HTTP 桥接（方式 B）。
- req_dispatcher 收到的就是一段需求文本，**不是结构化 trigger 信封**。orchestrator 据"路径判定"识别为接入路径。
- `req_dispatcher` 整段原样透传给 git_issuer，不解析需求语义。

## origin 元数据（114 在需求文本里携带）⚠️ 待对齐

- 编排器需把处理结果推回**发起需求的企微用户**，故接入时要从需求文本 capture **origin 元数据** `{channel,user,conversation}`（仅供回推用，**不是**解析需求语义/project）。
- [ ] 114 在需求文本里放 origin 的确切约定（约定行格式 / 独立信封字段名）——沿用 [`../../../docs/integration/result_notify_loop.md`](../../../docs/integration/result_notify_loop.md) §3 设想，待对齐。
- 对齐前：capture 不到则 `ORIGIN_JSON` 不传、entry 里 origin = `null`，**不阻断**主流程；`notify_user.sh` 仍会把 `origin:null` 放进结果信封推给 114 智伴（若 `ZHIBAN_*` pin 未配置则仅 ledger 留痕）。

# §1 git_issuer 段（建 issue）

## 跨 agent spawn 原语（req_dispatcher → git_issuer）⚠️ 待对齐

用户已确认：形态**类 `sessions_spawn`、可指定目标 agent、异步、结果经回调返回**。对齐时需敲定：

- [ ] 工具确切名称：是带 `agent`/`target_agent` 参数的 `sessions_spawn`，还是另一个专用跨 agent 工具？（据此更新 SKILL frontmatter `allowed-tools` 与接入路径第 3 步。）
- [ ] 如何指定目标 = `${GIT_ISSUER_AGENT}`（参数名）。
- [ ] 如何传 payload `{requirement_text}`（参数名、是否需写入临时文件再传路径，类似 acpx 的 `spawn_payload.txt`）。
- [ ] 返回里 `run_id` / `child_session_key` 的字段名（接入路径第 4 步据此填 `RUN_ID` / `CHILD_SESSION_KEY`）。
- [ ] launch ack 等待超时参数（类比 acpx `timeoutSeconds=30`）与运行超时参数（类比 `runTimeoutSeconds`）。
- [ ] 失败形态枚举（`status:"error"` / 网关超时 / 缺 `run_id` 等），以触发"同 payload 3 次 2s 退避"。

对齐前，连接所需的额外变量（如网关 url/token）写入 `config/dispatcher.env` 末尾占位处。

## 回调 trigger（git_issuer 完成 → req_dispatcher）⚠️ 待对齐

类比 acpx 的 `RUN_CHILD_COMPLETION_CALLBACK`。对齐时需敲定：

- [ ] 回调 trigger 的确切名称（占位：`RUN_GITISSUER_CALLBACK`）。
- [ ] 回调里 `run_id`（或 `child_session_key`）字段名——**回调路径以此为主匹配键**。
- [ ] git_issuer 终态输出承载在哪个字段（类比 acpx 的 `worker_result_json`）。其完整结构与字段含义（git_issuer 一侧的产出规格）见 [`gitissuer_contract.md`](../../../docs/integration/gitissuer_contract.md)（跨团队对接文档，**orchestrator 运行时不必读它**——下面这张映射表才是回调路径解析所需的运行时契约）。

### 回调字段 → drain_pending env（运行时解析契约，已定）

orchestrator 回调路径从 git_issuer 终态 JSON 取值，填入 `drain_pending.sh` 的 env：

| git_issuer JSON 字段 | drain_pending env | 备注 |
|----------------------|-------------------|------|
| `status`（`success`\|`failed`） | `OUTCOME` | 原样透传；`launch_failed` 不来自 git_issuer（spawn 失败时 req_dispatcher 自合成）。 |
| `issue_iid` | `ISSUE_IID`（或 `IID`） | success 才有；同时透传给 §2 spawn executor 的 I1 `iid`。 |
| `issue_url` | `ISSUE_URL` | success 才有。 |
| `project` | `PROJECT`（drain 审计） | success 才有；**主要消费方是 `route_project.sh`**（按它选 executor）与 I1 `project`。 |
| `reason` | `REASON` | failed 才有。 |
| —（恒定） | `STAGE=git_issuer` | drain 该段固定写 `STAGE=git_issuer`。 |
| —（不取） | `RUN_ID` | **来自 runtime 回调自带的 `run_id`，不取自这段 JSON**（匹配键，见 §匹配）。 |

`entry_label` / `action` / `superseded_by` 等字段供审计/排查，orchestrator 不强依赖。完整字段表与变更场景的 `action` 扩展见 docs/integration 下的两份对接文档。

> **drain git_issuer 段 ≠ 链路终点**（与旧"薄派发器"不同）：success 时 drain git_issuer 段只是**收尾该段**，编排器随即按 project 路由起 executor 段（§2）；failed/no_route 时 drain 并推用户。

## 匹配策略（git_issuer 段）

- **主（已定，已实现）：`run_id`**。接入路径记 `pending[run_id]`（`stage=git_issuer`）；git_issuer 回调路径用回调的 `run_id` 直接 drain（`drain_pending.sh` 按 `RUN_ID` 删除）。**不要求 git_issuer 回显任何我们的 token**，对同事 agent 零侵入。
- **匹配不到 pending（已定）**：迟到 / 重复 / 已被 stuck 驱逐的回调，仍照常调 `drain_pending.sh`，写 `was_pending=false` 审计行——预期情形、非错误。
- **兜底：`child_session_key`** ⚠️ 待对齐：仅当回调带 `child_session_key` 而 `run_id` 缺时才需要。**当前 `drain_pending.sh` 不支持按 `child_session_key` 反查**——若对齐后确实需要此路径，需给 `drain_pending.sh` 增"`RUN_ID` 空时按 `CHILD_SESSION_KEY` 反查 pending 主键再 drain"的分支。未对齐前不承诺此路径。
- **回显模式（git_issuer 段 `correlation_id`）** ⚠️ 待对齐：仅当 `run_id` 与 `child_session_key` 都拿不到的退化情形才启用。设想是接入时用 `${STATE_ROOT}/_dispatcher/seq`（flock 保护、`env_paths.sh` 已预留 `SEQ_FILE` 路径）单调递增生成 token、随 payload 传给 git_issuer 并要求其回显。**此 seq 生成机制尚未实现**（无脚本写 `seq`），且**需 git_issuer 配合回显、有侵入**。对齐时若确需此模式，再补 seq 自增脚本 + git_issuer 回显约定。**未对齐前不要自行用随机/时间戳生成 token**（违反 No-Fallback）。

---

# §2 executor 段（驱动 req_executor 单次 issue 执行）

git_issuer 回调成功后，编排器按 `project` 查 `route_project.sh` 选目标 req_executor 部署 agent，再 spawn 其 `RUN_SINGLE_ISSUE` driven 入口，并记一条**新** `pending[run_id2]`（`stage=executor`）。executor Phase 6 终态回调结果，编排器据 `run_id2` drain、把结论 `notify_user.sh` 推回 origin。

## 跨 agent spawn 原语（req_dispatcher → req_executor）⚠️ 待对齐

同 git_issuer spawn 同一待对齐项（形态类 `sessions_spawn`、可指定目标 agent、异步、结果经回调）。对齐时需敲定：

- [ ] 工具确切名称与如何指定目标 = `route_project.sh` 返回的 **executor agent 名**（**不是** `${GIT_ISSUER_AGENT}`；目标随 project 路由动态决定）。
- [ ] 如何传 I1 多行 payload（参数名、是否需写临时文件再传路径）。
- [ ] 返回里 `run_id2` / `child_session_key2` 的字段名（git_issuer 回调路径第 6 步据此填 `RUN_ID` / `CHILD_SESSION_KEY`）。
- [ ] 失败形态枚举（触发"同 payload 3 次 2s 退避"；耗尽 = `launch_failed` 推用户"已建 issue #<iid> 但未能启动处理"）。

### (I1) RUN_SINGLE_ISSUE 入参（req_dispatcher 构造，发往 executor orchestrator session `agent:req_executor:main`）

多行 key=value（沿用现有 trigger 文本格式）：

```
RUN_SINGLE_ISSUE
project=<group/project，git_issuer 回调透传>
iid=<正整数，要测的 issue IID>
correlation_id=<req_dispatcher 生成的关联 token>
dispatcher_callback_target=<回调目标 = ${DISPATCHER_CALLBACK_TARGET}，待对齐占位>
group=<可选，缺省取执行器 pin 配置>
```

| 字段 | 必填 | 来源 |
|---|---|---|
| `project` | 是 | git_issuer 回调透传的 `project`。 |
| `iid` | 是 | git_issuer 回调透传的 `issue_iid`（正整数）。 |
| `correlation_id` | 是 | req_dispatcher 生成（见 §correlation_id ⚠️），原样回显在 I2 供二次校验。 |
| `dispatcher_callback_target` | 是 | `config/dispatcher.env` 的 `DISPATCHER_CALLBACK_TARGET`（结果回调目标，形态待对齐 ⚠️；留空则执行器侧 `notify_dispatcher.sh` no-op）。 |
| `group` | 否 | 缺省取执行器 pin 配置。 |

**其余 campaign 字段一律不传**（`gitlab_token`/`branch`/`dev_branch`/`quota`/`concurrency`/… 全部由执行器侧 `config/campaign_defaults.env` pin，token 永不经 req_dispatcher）。

### §correlation_id（executor 段二次校验 token）⚠️ 待对齐

- 用途：req_dispatcher spawn executor 时生成、随 I1 下发，执行器原样回显在 I2 `correlation_id`——**作 executor 回调的二次校验**（防 run_id 错配）；主匹配仍 `run_id2`。
- [ ] 生成机制待对齐：复用 git_issuer 段设想的 `${STATE_ROOT}/_dispatcher/seq`（flock 单调递增）单条 token，或对齐后另定。**此 seq 生成机制尚未实现**（无脚本写 `seq`）。**未对齐前不要自行用随机/时间戳生成 `correlation_id`**（违反 No-Fallback）。

## 结果回调 trigger（req_executor 完成 → req_dispatcher）⚠️ 待对齐

类比 acpx 的 `RUN_CHILD_COMPLETION_CALLBACK`。对齐时需敲定：

- [ ] 回调 trigger 的确切名称（占位：`RUN_EXECUTOR_RESULT_CALLBACK`）。
- [ ] 回调里 `run_id`（= `run_id2`）字段名——**executor 回调路径以此为主匹配键**。
- [ ] 执行器结果 JSON（下面 I2）承载在哪个回调信封字段（类比 acpx 的 `worker_result_json`）。

### (I2) 执行器结果回调信封（executor Phase 6 终态发出，一行紧凑 JSON）

```json
{"correlation_id":"<回显 I1 的值>","iid":<int>,"project":"<group/project>","status":"done|failed|timeout","mr_url":<string|null>,"wiki_url":<string|null>,"reason":<string|null>}
```

- `status` 取执行器 `final_status`（`done`/`failed`/`timeout`；`blocked` 不回调——可重试态，等下一 attempt 或停放）。
- 承载该 JSON 的跨 agent 回调信封字段名 = 待对齐（⚠️）。

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
| —（不取） | `ORIGIN_JSON` | —（不取） | **取自 `pending[run_id2].origin`**（接入时 capture、全程随两段携带），非来自 I2。 |
| —（不取） | —（`EVENT=result` 固定） | `STAGE=executor` 固定 | — |

`drain_pending.sh` 的 `RUN_ID` **来自 runtime 回调自带的 `run_id`（=`run_id2`），不取自 I2 JSON**。

## 匹配策略（executor 段）

- **主：`run_id2`**（= git_issuer 回调路径 spawn executor 后 `record_pending.sh` 记的 `RUN_ID`）。executor 回调用 runtime 自带 `run_id` 直接 drain。
- **二次校验：`correlation_id`**（I2 回显值须 = `pending[run_id2].correlation_id`）——防 run_id 错配。不一致：记紧凑告警、以 `run_id` 为准 drain，不臆造。
- **匹配不到 pending**：迟到 / 重复 / 已被 stuck 驱逐的回调，仍照常 `drain_pending.sh`（`STAGE=executor`、`was_pending=false`）——预期情形、非错误。

## 三条逻辑路径（已定，详见 SKILL.md）

- **接入路径（A）**：capture origin → evict_stuck（覆盖两段）→ cross-agent spawn git_issuer → `record_pending(run_id, stage=git_issuer, origin)` → 最小 ack。
- **git_issuer 回调路径（B）**：解析 `{status,project,iid,url}` → 成功则 `route_project` 选 executor（`__NO_ROUTE__` → 推用户 + ledger + ops + drain）→ spawn `<executor> RUN_SINGLE_ISSUE`(I1) → `record_pending(run_id2, stage=executor, project/iid/correlation_id/origin)` → drain git_issuer 段；失败则推用户 failure + drain。
- **executor 回调路径（C）**：解析 I2 → 按 `run_id2` 匹配 executor 段（`correlation_id` 二次校验）→ `notify_user(result)` 推回 origin → drain executor 段。
