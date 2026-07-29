# req 三件套迁移 Temporal + LangGraph 架构设计

> 文档版本：2026-07-21.2
>
> 适用范围：`req_dispatcher` / `req_executor`（104 蓝区）
>
> 当前状态：**设计草案，未实施**。本文不描述现状，只描述一个待评审的改造方案；
> 现状契约以各 workspace 的 `SOUL.md` / `SKILL.md` / `references/` 为准。
>
> 相对 `2026-07-21.1` 的变化：引入 **Temporal 作为持久化编排/状态机内核**，
> LangGraph 从"控制面主导者"降级为"可选的 review 决策子图"（§2.3、§4、§10）。

## 0. 结论前置

评估命题：把 `req_dispatcher` / `req_executor` 改造为
`企业微信 → OpenClaw Agent → MCP Tool → 编排引擎 → GitLab/Jenkins/…`。

结论分四条：

1. **技术上可行**，但核心阻碍不是 MCP 或编排引擎，而是 OpenClaw 运行时工具
   （`sessions_spawn` / `sessions_yield` / `subagents`）无法从 MCP server 侧调用。
   解法是让这些调用**变得不必要**，而不是想办法调到它们（见 §3.1）。
2. **收益真实但性质与命题描述不同**：不是"编排引擎比现有 shell 更会编排"，
   而是"把随机性组件从确定性控制回路里摘掉"＋"删掉一整套只因为两个 agent 分离才存在的传输协议"
   ＋"把手写的持久化状态机换成引擎原语"。
3. **编排引擎选型的结论是 Temporal 而非 LangGraph。** 这套系统缺的是
   *durable execution*（持久化定时器、重试策略、取消传播、崩溃重放、单例围栏、外部信号），
   不是 *graph authoring*。现状里最脏的代码——冷却重试、tick 轮询、claim 抢占、三阶段重放、
   退避回投 outbox——逐条对应 Temporal 的一等原语（§5.0 映射表）。
   LangGraph 的 checkpointer 在这里是**纯冗余的第二套持久化层**。
4. **LangGraph 仍有位置，但只在 P3、且不承担持久化**：`review` / `retry` 若演化成多步 LLM 推理
   （读 MR diff → 跑测试 → 评审 → 决策），把它写成一张 LangGraph 图，
   **整张图跑在单个 Temporal activity 内部**，作为无副作用的决策库使用（§7.6）。

---

## 1. 前提纠正：这不是"纯 prompt agent"

改造讨论中常见的表述是"当前 req 三件套是纯 prompt 的 OpenClaw agent"。该表述不成立：

| 指标 | 实际值 |
|---|---|
| 两个 workspace 的 shell 代码 | **36,289 行** |
| `dispatch_prepare_tick.sh` | 3,771 行 |
| `run_executor_batch_tick.sh` | 2,842 行 |
| `_dispatch_lib.sh` | 2,305 行 |
| 可独立执行的 shell 测试 | 约 150 个 |

LLM 在 `req_dispatcher` 中的**全部职责**：

1. 读首行 → 在 6 条路径中选 1 条（纯字符串匹配）
2. 调用 1 个顶层 wrapper
3. 读严格 JSON，按 `status` 分支
4. 回一句最小 ack

LLM 在 `req_executor` 中的**全部职责**：上述流程，外加 4 件 shell 无法完成的运行时操作
（`Read(payload_path)`、`sessions_spawn`、`sessions_yield`、`subagents list/kill`）。

**即：LLM 已经是一个约 50 行的有限状态机，外面裹着约 900 行 prompt 在阻止它自作主张。**

`skills/gitlab_issue_campaign_dispatcher/SKILL.md` 中的防御性文字是直接证据 ——
"never add a markdown fence"、"never Read a script"、"never debug a wrapper"、
"if you ever feel the urge to open a wrapper, that urge itself is the signal to stop"。
这些不是使用文档，而是在约束一个不可靠的状态机执行器。

这一纠正改变了改造的立论基础：

- ❌ **不是**因为图编排能力更强。现有 shell 的 claim fencing、幂等重放、原子写、
  双扫一致性冻结、SHA 栅栏 push、`exact-GET → SHA-fenced-PUT → exact-GET` 合并验证，质量都很高。
- ✅ **而是**为了把随机性组件移出确定性回路、删除跨 agent 传输协议，
  并把"手写得很好但很贵"的持久化状态机换成引擎原语。

**补充纠正（本版新增）**：现状也不是"没有状态机"。`references/label_lifecycle.md` 定义的
`todo/retry/new/continue → doing → done → pr → finish`，加上
`blocked-cc` / `blocked-dispatcher` 的冷却重试、`blocked_retry_limit` 溢出后升级为
`failed-*`、`timeout` 终态且不消耗 `retry_count`、人工 `continue` 回流——
这是一台**定义完整、语义精细的状态机**，只是它的持久化、定时、重试、互斥
全部由 shell + JSON 文件 + `flock` + 轮询 tick 手写实现。
改造的实质是**换掉这台状态机的运行时，而不是重新设计它**。

---

## 2. 收益分析（按价值排序）

### 2.1 `sessions_spawn` 全套机制可整体删除 —— 单点最大收益

依据 `references/executor_prompt.md`：被 `sessions_spawn` 拉起的 subagent，其**全部工作**是

1. 校验 manifest 的 SHA-256 与字节数；
2. 发起**一次** Bash 调用 `bash {SCRIPTS_DIR}/run_executor_attempt.sh`；
3. 将最后一行 JSON 原样输出。

在 Python 中这等价于一个 Temporal activity 里的 `subprocess.run(cmd, timeout=...)`。

它今天之所以是一个 LLM 子代理，唯一原因是 OpenClaw 的 Bash tool 有 per-exec 超时、
父 session 必须 `sessions_yield` 才能保持响应。为了让这"一行"可靠，围绕它长出了：

- **三层任务体系**：secret-free spawn bootstrap ／ 私有 executor payload ／
  mode-600 manifest（SHA-256 + byte count）
- `ingest_subagent_completion.sh`（**1,035 行**）：认证原生完成事件、绑定本地 session registry、
  校验非符号链接 JSONL transcript、要求 final assistant `stop` 行、full-bootstrap row 唯一性
- OpenClaw `2026.4.9`（`openclaw_4_9_terminal_reference`）与 `2026.6.11`
  （结构化 `task_completion` 事件）两套版本适配
- `_driven_launch_coordinator.sh` 的 `ack_received / project_recorded / scheduler_recorded` 三阶段重放
- `resolve_executor_batch_reconcile.sh` + `subagents list` 运行时证据核对
- `reap_driven_orphan_placeholders.sh` 孤儿占位回收
- LLM 侧硬规则：3 次重试 × 2 秒退避、payload 逐字节不变、**严禁并行 spawn**
  （本机 loopback 网关按 channel 串行处理，并行会让第 2 个 spawn 返回
  `gateway timeout after 10000ms` 并留下孤儿 `childSessionKey`）

**这一整块在 Temporal 架构中不存在。** activity 直接跑子进程，进程退出即终态；
worker 崩溃由 `heartbeat_timeout` 兜底，不存在"最终 model turn 未被调度"这一失败模式，
因而也不需要 durable result 兜底恢复。三阶段重放 coordinator 被事件溯源重放原生替代。

### 2.2 跨 agent 传输协议可整体删除

I1 / I3 / `callback_nonce` / receipt / mirror / legacy bridge —— 这套机制**只因为
`req_dispatcher` 与 `req_executor` 是两个只能互发聊天字符串的独立 OpenClaw agent 才存在**。

| 侧 | 纯协议开销 |
|---|---|
| dispatcher | `executor_batch_outbox.json` durable intent；`executor_batches.json` compact mirror；`executor_batch_events.jsonl` event ledger；64-hex `callback_nonce` + SHA-256 校验；`received → mirror → accepted` 三段 receipt 状态机；legacy FIFO bridge；`handle_executor_batch_event.sh`；`drain_executor_batch_outbox.sh`；`apply_executor_batch_event.sh` |
| executor | `emit_driven_batch_acceptance.sh` 五字段 public acceptance；`drain_driven_outbox.sh` 带退避的回投 outbox；`RUN_DRIVEN_BATCH_RESULT_ACK_ONLY` 三行 transport；`import_driven_handoff.sh` / `drain_driven_handoff_intents.sh`；`notify_dispatcher.sh`；`openclaw_agent_transport.sh` |

在单一 Temporal namespace 内，上述全部退化为父子 workflow 之间的一次调用/信号。
`drain_driven_outbox.sh` 那套"带退避的回投"直接等价于 activity 的 `RetryPolicy`。
连 `malformed_or_ambiguous_ack`（对端 LLM 多输出了一个 markdown 围栏）这一失败类别
都从词汇表中消失。

### 2.3 durable execution 替代手写持久化状态机

现状：JSON 文件 + `flock` + 原子 rename + 手写重放/幂等逻辑，分散在
`scheduler_state.json`、`campaign_state.json`、`executor_batch_outbox.json`、
`_driven_launch_coordinator`、`executions/execution-<id>.json` 中。

两个候选引擎在这一层的能力差距是本次选型的决定点：

| 需求 | LangGraph | Temporal |
|---|---|---|
| 崩溃后从中断处恢复 | ✅ checkpointer | ✅ 事件溯源重放 |
| **持久化定时器**（冷却 N 分钟后重试） | ❌ 无原语，需外部调度器 | ✅ `workflow.sleep()` |
| **重试策略 + 上限**（`blocked_retry_limit`） | ❌ 手写 | ✅ `RetryPolicy(maximum_attempts=…)` |
| **单例围栏**（同一 Issue 不得并发执行） | ❌ 手写锁 | ✅ workflow id 唯一性 |
| **外部信号**（`/slot`、`/repo-slot`、`/timeout-executor`、人工审批） | ⚠️ `interrupt()` 仅限进程内恢复 | ✅ Signal，跨进程可寻址 |
| **取消传播**（`cancel_run` 要杀到 acpx 子进程） | ❌ 手写 | ✅ 原生，经 heartbeat 传递 |
| **状态查询不触发 IO** | ❌ 读 checkpoint | ✅ Query |
| 长任务（小时级）承载 | ⚠️ 进程内 | ✅ 设计目标 |
| 图编排 / 条件边 / 扇出 | ✅ 一等公民 | ⚠️ 就是普通 Python 控制流 |
| LLM 节点生态 | ✅ | ❌ 无 |

**结论**：这套系统的痛点全部落在上半张表。图编排能力（下半张表）在这里价值有限——
per-issue 流程是一条几乎线性的链，`prepare → execute → finalize → classify`，
用普通 `async def` 写反而更直白。

> ⚠️ **不要两套持久化层。** 把 LangGraph 图塞进 Temporal workflow 会违反
> workflow 的确定性约束（LangGraph 内部有自己的调度与并发）；
> 若为了绕开而把整张图塞进单个 activity，Temporal 就退化成任务队列，
> 失去 per-step 的重试/超时/可见性。二选一：**图归 Temporal**（workflow 就是图），
> 或**把 LangGraph 限制在无副作用的决策子图内**（§7.6）。本设计取前者，后者留给 P3。

> ⚠️ **分寸（原则不变）**：只把控制面搬进引擎，**不动效果层的磁盘状态**。
> `campaign_state.json` / per-issue `state.json` / GitLab label 是 GitLab 与 worktree 的
> 本地投影，仍由 shell 拥有。一次搬两层必然失控。
> 推论见 §7.5：**GitLab label 仍是对外权威真相，Temporal 历史是编排真相**，
> 两者之间必须保留 reconcile 路径（`reconcile.sh` 不删）。

### 2.4 调度轮询回路可大幅退化 —— Temporal 独有收益

这是 LangGraph 给不了、而 Temporal 直接消除的一整类复杂度。

现状的冷却重试是**按 tick 计数**的：`blocked_cooldown_ticks` 表示"再过 N 个 tick 才可重试"，
这意味着必须有一个外部循环持续把 `run_executor_batch_tick.sh`（2,842 行）跑起来，
每轮重新扫描 GitLab 标签、重算资格、重放 coordinator、回收孤儿占位、检查 `stuck_after_minutes`。
调度的时间语义被绑死在轮询频率上。

Temporal 下，一个 `blocked-cc` 的 Issue 由它自己的 `IssueWorkflow` 执行：

```python
except RetryableAttemptError as e:
    await workflow.execute_activity(set_issue_label, "blocked-cc", ...)
    self.retry_count += 1
    if self.retry_count > self.blocked_retry_limit:
        await workflow.execute_activity(set_issue_label, "failed-cc", ...)
        return terminal("failed-cc")
    await workflow.sleep(self.cooldown)   # 持久化定时器：worker 可以全部重启
    continue                              # 自唤醒，不需要任何人来 tick 它
```

`workflow.sleep()` 的等待期不占用 worker、不占用内存，worker 全挂重启后定时器照常触发。
随之消失的有：tick 循环本身、`blocked_cooldown_ticks` 的 tick 计数语义（改回真实时间）、
`queue_launch_reclaim_seconds`、`stuck_after_minutes` 派生预算、孤儿占位回收。

> ⚠️ **不要过度宣称"轮询完全消失"。** 有一处轮询无法消除：**人工在 GitLab 上打标签**
> （`continue` / 剥 `timeout` / `quality:low`）是既有评审工作流的一部分，
> Temporal 无法感知外部系统的状态变化。两种收口方式：
> 1. **GitLab webhook → 104 上一个薄 HTTP 接收器 → `signal_workflow`**（最优，需 GitLab 能回调 104）；
> 2. **Temporal Schedule 定期触发一个 `LabelWatchWorkflow`**，扫描标签变更后 signal 对应的
>    `IssueWorkflow`（不依赖 GitLab 回调能力，作为默认方案）。
>
> 准确表述是：轮询从**驱动整个调度回路**，降级为**只用于捕获人工标签变更**。

### 2.5 运行时控制从"改状态文件"变成引擎原语

| 现有命令 | 现状实现 | Temporal |
|---|---|---|
| `/slot <n>` | `set_executor_slots.sh` 写 `max_concurrency` 进 scheduler state，下一轮 tick 生效 | Signal 到父 workflow，改并行仓库信号量；缩容不取消在途（语义不变） |
| `/repo-slot <n>` | `set_executor_repo_slots.sh` 写 `max_issues_per_repository` 进 scheduler state，下一轮 tick 生效 | Signal 到父 workflow，改每仓库 Issue 信号量；缩容不取消在途（语义不变） |
| `/timeout-executor <时长>` | `set_executor_acpx_timeout.sh`，仅影响后续 attempt | Signal 改后续 activity 的 `start_to_close_timeout`（在途 activity 保留启动时值，语义天然一致） |
| 查批次状态 | 读 JSON 状态文件 | Query，不触发任何 IO |
| 取消批次 | **现状无此能力** | `handle.cancel()`，经 heartbeat 传播到 acpx 子进程 |

注意 `/timeout-executor` 的"在途 attempt 保留启动时固定的值"这条现状语义，
在 Temporal 里是**免费得到**的：已 schedule 的 activity 的 timeout 不可变。

### 2.6 `review / retry` 是新能力，不是移植

命题图中的 `review` 节点**当前并不存在**。现状是：一个 Issue 要么走到 `pr` / `finish`，
要么落入 `blocked-cc` / `blocked-dispatcher` 进入冷却重试，**没有任何"检查产出再决定"的环节**。

Temporal 下这是在 `IssueWorkflow` 里加一段：跑测试 / 读 MR diff / LLM 评审 →
`pass | retry | escalate`。人工审批用 **Signal + `workflow.wait_condition()` + 超时定时器**，
比 LangGraph 的 `interrupt()` 更适合生产——审批信号可以从任意进程、任意时间点发来，
等待期跨越 worker 重启依然成立。

若该评审逻辑本身演化成多步 LLM 推理，再引入 LangGraph（§7.6）。

### 2.7 可观测性

现状排障依赖 `${RESULT_ROOT}/_dispatcher/log/wrapper.log` 的文本检索。
迁移后每个 run 的完整事件历史（每次 activity 调度/开始/完成/重试/超时、每个信号、
每次定时器触发）成为结构化数据，Temporal Web UI 可直接按 workflow id
（即 Issue IID）回溯，并支持 replay 调试。

---

## 3. 结构性阻碍

### 3.1 运行时工具不可从 MCP server 调用（核心阻碍）

`sessions_spawn` / `sessions_yield` / `subagents` 是 OpenClaw 运行时工具，
`SKILL.md` 明确标注 "not callable from a shell process"。MCP server 与 Temporal worker 均位于
OpenClaw **进程外**，同样调用不到。

**解法**：不去调用它们，而是让它们**变得不必要** —— Temporal activity 直接
`subprocess` 执行 `run_executor_attempt.sh`（§2.1）。subagent 这层间接性从架构中消失。

**推论**：P1 阶段必须**一次性**切换 executor 的 spawn 路径，不允许部分迁移 ——
两套路径并存会同时持有同一 worktree 与 GitLab label，必然互相踩踏。

### 3.2 MCP 是请求/响应，而批次执行以小时计

MCP tool call 无法承载小时级同步等待。因此 MCP 面必须设计为**异步作业控制**：
提交即返回，结果走独立推送通道。

这与现状语义**完全一致**（I1 同步 ack + I3 异步逐条回投），不构成新约束。
Temporal 让它更自然：`client.start_workflow()` 立即返回 handle，
`handle.query()` 拿状态，两者都在毫秒级（§6）。

### 3.3 蓝区离线约束

- **Temporal Server**：Go 编写，Frontend / History / Matching / Worker 四个角色，
  单机可同进程起。生产持久化需 PostgreSQL（对应蓝区规划 5.3「关系型数据库」P0）。
  `temporal server start-dev`（SQLite）官方明确标注**非生产用途**，只允许出现在 P0 spike 与影子期。
- **Advanced Visibility**：自 Temporal 1.20 起 SQL 后端（PostgreSQL 12+ / MySQL 8.0.17+）
  支持 advanced visibility，**蓝区可不引入 Elasticsearch**。此条列为 P0 spike 的验证项，
  不作为既定事实采信。
- **Python SDK**：`temporalio` 基于 Rust core，wheel 是平台相关的预编译产物。
  若 104 是 RHEL7（glibc 2.17），必须验证 manylinux wheel 可用性——
  这是 P0 的硬门槛，可复用仓库 `packaging/` 的 RHEL7 离线经验（注意 `packaging/` 已在
  `edb315b` 从仓库删除，只作为 GitHub Release 附件存在）。
- **必须关闭一切云端上报**：Temporal 的 telemetry 关闭；若 P3 引入 LangGraph，
  同时关闭 LangSmith（`LANGCHAIN_TRACING_V2=false`）—— 蓝区不允许外发。
- MCP server、Temporal Frontend（gRPC 7233）、Web UI（8233）**只绑 `127.0.0.1`**。
- Temporal Server 与 SDK 版本必须 pin 死并成对升级；蓝区升级成本高，不能跟随上游快速演进。

### 3.4 workflow 确定性约束（新增硬纪律）

Temporal 通过**重放事件历史**恢复 workflow 状态，因此 workflow 函数体必须是确定性的。
这是一条与仓库现有 **jq 1.5 兼容基线** 同级的硬约束，必须写进 workspace 的 `AGENTS.md`：

- workflow 内**禁止**：`subprocess`、文件 IO、网络调用、`datetime.now()`、`random`、
  `uuid4()`、读环境变量、依赖 dict/set 迭代顺序的逻辑
- 对应替代：`workflow.now()`、`workflow.random()`、`workflow.uuid4()`、`workflow.sleep()`
- **所有 shell wrapper 调用必须在 activity 内**，无例外
- Python SDK 的 workflow sandbox 会拦截大部分违规，但不是完备的——需要 lint 规则兜底
- **workflow 代码变更需版本化**：有在途 workflow 时修改编排逻辑会导致重放不一致，
  必须用 `workflow.patched()` / Worker Versioning。这是一项现状不存在的新运维纪律（R10）。

### 3.5 事件历史即持久化面 —— 凭据风险比 checkpointer 更尖锐

`GITLAB_TOKEN` 必须由各 activity 从进程环境或 `config/gitlab.env` 现取现用，
**永不进入 workflow 参数、activity 入参/返回值、Signal payload 或 Query 结果**。

理由比 LangGraph 方案更强：**activity 的入参与返回值会被完整写入事件历史**，
而事件历史不仅落盘持久化，还在 Temporal Web UI 上**可直接浏览**。
一次疏忽等于把 token 明文贴到一个内网 Web 界面上。

现有 shell 在这点上已足够谨慎（token 不进 trigger、spawn bootstrap、manifest、executor payload；
`run_acpx_attempt.sh` 还会从内层 acpx 进程剥离 token 别名）。迁移时必须显式承接这条纪律，
并增加自动化检查（CI 扫描 activity 签名与返回类型），否则是实质性的安全降级。

### 3.6 副作用型 activity 不可盲目自动重试

Temporal 的默认 `RetryPolicy` 会无限重试 activity。对本系统这是**危险默认值**：
`run_acpx_attempt.sh` 跑了 40 分钟后 worker 崩溃，自动重试会在一个已有半成品改动的
worktree 上重新跑一遍 acpx。

必须逐个 activity 显式声明重试语义，分三类：

| 类别 | 例子 | 策略 |
|---|---|---|
| 幂等只读 | GitLab 查询、snapshot 扫描、`post_push_verify.sh` | 默认重试即可 |
| 幂等写（自带栅栏） | `commit_and_push.sh`（SHA 栅栏）、`set_issue_label.sh`、`merge_mr.sh`（exact-GET → SHA-fenced-PUT → exact-GET） | 可重试，但 `maximum_attempts` 设有限值 |
| **非幂等重副作用** | `run_acpx_attempt.sh`、`create_mr.sh`、`migrate_shared_dependency_head.sh` | **`maximum_attempts=1`**，失败上抛由 workflow 显式决策（走既有的 `blocked-*` 冷却重试语义） |

这条映射必须逐个 wrapper 做，不能一刀切——**它是 P1 最容易出错的地方**。

### 3.7 事件历史体量

单个 workflow 的历史有上限（数万事件 / 50MB 量级）。因此不能用一个巨型 workflow
承载整个批次的全部 Issue。本设计的 **per-Issue child workflow 分解**（§4）天然规避了这一点；
父 workflow 若需长期存活（如常驻的 `LabelWatchWorkflow`），用 `continue_as_new` 截断历史。

---

## 4. 目标架构

```text
企业微信（绿区）
   ↓
114 智伴 OpenClaw
   ↓ 反向网关（104 → 114 已放行）
104 OpenClaw：req_intake agent（唯一保留的 LLM 编排点，只做 NLU）
   ↓ MCP tool call（127.0.0.1，streamable-http）
MCP Server（FastMCP）—— Temporal Client 的薄封装，任何调用 < 1s
   │  start_workflow / query / signal / cancel
   ↓ gRPC 127.0.0.1:7233
┌──────────── Temporal Server（104，PostgreSQL 持久化）────────────┐
│  Frontend / History / Matching / Worker  +  Web UI（127.0.0.1）   │
└──────────────────────────────────────────────────────────────────┘
   ↕ task queue: req-executor
┌──────────── Worker 进程（Python，systemd 常驻，无状态）──────────┐
│                                                                  │
│  RequirementRunWorkflow      id = idempotency_key                │
│    ├─ activity  snapshot_issues        （双扫一致性冻结）         │
│    ├─ activity  plan_dependency_groups （A→C 共享分支组）         │
│    ├─ signal    set_slots / set_acpx_timeout / cancel            │
│    ├─ query     get_run                                          │
│    └─ 按槽位放行 child workflow ──┐                              │
│                                   ↓                              │
│  IssueWorkflow   id = issue-<project>-<iid>   ← 单例围栏即互斥   │
│    prepare → execute(acpx) → finalize(push/MR/label) → classify  │
│      │                                                           │
│      ├─ blocked-* → workflow.sleep(cooldown) → 自唤醒重试         │
│      │              retry_count > limit → failed-*（终态）        │
│      ├─ timeout   → 终态，不消耗 retry_count                      │
│      ├─ review（P3）→ Signal 等人工审批 / 内嵌 LangGraph 决策图    │
│      └─ 终态 → activity notify（反向网关直推 114）                │
│                                                                  │
│  LabelWatchWorkflow（Temporal Schedule 驱动）                     │
│    扫描人工标签变更（continue / 剥 timeout / quality:low）        │
│    → signal 对应 IssueWorkflow，或 signal_with_start 复活终态     │
└──────────────────────────────────────────────────────────────────┘
   ↓ activity 内 subprocess（**不重写，原样调用**）
现有 shell wrappers → glab / git / acpx
```

**设计决策**：

- `git_issuer` 前期保持独立 agent 不动（它只用 `glab`、逻辑稳定、改动少），P3 再考虑收编。
- **P1/P2 不引入 LangGraph。** 见 §2.3 与 §10。
- Worker 进程无状态，可多副本（同 task queue）；并发上限由 worker 配置
  `max_concurrent_activity_task_executions` 与父 workflow 信号量**双层**控制（§7.3）。

---

## 5. 分层：进引擎 / 留 shell / 删除

### 5.0 现有机制 → Temporal 原语映射（本设计的核心论据）

| 现有实现 | 手写代价 | Temporal 原语 |
|---|---|---|
| `flock` + claim fencing + `active_jobs` 防重入 | 高 | **workflow id 唯一性**（同 namespace 同 id 只允许一个 Running execution） |
| `execution_id` 作为 stale-callback 围栏 | 中 | **`workflow.info().run_id`**（语义几乎 1:1，日志归档分支名可直接沿用） |
| `_driven_launch_coordinator.sh` 三阶段重放 | 高 | **事件溯源重放**（原生，无需编码） |
| `blocked_cooldown_ticks` + tick 轮询驱动冷却 | 高 | **`workflow.sleep()`** 持久化定时器 |
| `blocked_retry_limit` → 升级 `failed-*` | 中 | **`RetryPolicy.maximum_attempts`** + `non_retryable_error_types` |
| `drain_driven_outbox.sh` 带退避回投 | 高 | **activity 重试策略**（指数退避内建） |
| `stuck_after_minutes` / `queue_launch_reclaim_seconds` 派生预算 | 高 | **`start_to_close_timeout` + `heartbeat_timeout`** |
| `reap_driven_orphan_placeholders.sh` 孤儿回收 | 中 | 不存在此失败模式（worker 崩溃即心跳超时） |
| `/slot <n>` 改 scheduler state | 中 | **Signal** → 父 workflow 信号量 |
| `/repo-slot <n>` 改每仓库 Issue 上限 | 中 | **Signal** → 父 workflow 的仓库级信号量 |
| `/timeout-executor` 只影响后续 attempt | 中 | **Signal**；已 schedule 的 activity timeout 不可变（语义免费得到） |
| 读 JSON 状态文件查批次进度 | 低 | **Query**（不触发 IO） |
| I1 durable intent outbox + 稳定 `batch_id` 复用 | 高 | **`start_workflow` 幂等**（`WorkflowExecutionAlreadyStarted`） |
| `callback_nonce` + SHA-256 防串扰 | 中 | 不需要（同 namespace 类型化调用） |
| 批次取消 | **现状缺失** | **`handle.cancel()`**，经 heartbeat 传播至子进程 |
| 人工审批介入 | **现状缺失** | **Signal + `wait_condition` + 超时定时器** |

### 5.1 进 Temporal（控制面）

| 现有实现 | 迁移后 |
|---|---|
| `run_executor_batch_tick.sh` 的调度与重放部分 | `RequirementRunWorkflow` 编排逻辑 |
| `reserve_driven_batch_items.sh` round-robin | workflow 内显式队列 + 游标（确定性，可重放） |
| `scheduler_state.json` 的 `active_jobs` / 并发上限 | workflow 局部状态 + `asyncio.Semaphore` |
| `_driven_launch_coordinator.sh` 三阶段重放 | 事件溯源重放 |
| `dispatch_prepare_tick.sh` 的资格判定 / 配额 / 批次成形 | `snapshot_issues` / `plan_dependency_groups` activity + workflow 判定 |
| `blocked-*` 冷却重试回路 | `workflow.sleep()` + `RetryPolicy` |
| dispatcher 全部 I1/I3/receipt/mirror/nonce | **删除**（父子 workflow 调用） |

### 5.2 留 shell（效果层，activity 内 subprocess 调用，**一行都不重写**）

这些是仓库最有价值的资产，重写等于静默丢掉安全加固：

- `run_executor_attempt.sh` + `run_acpx_attempt.sh` —— PATH 白名单、`--safe-mode`、
  内层 `glab` 全禁、Git 变更/网络命令禁用、`safety_bin` 前缀、进程组 teardown 防孤儿、
  token 从内层进程剥离
- `create_driven_batch.sh` —— GitLab GraphQL 游标分页 + **两次归一化全扫必须一致才冻结**
- `merge_mr.sh` —— exact GET → SHA-fenced PUT → 二次 exact GET
- `migrate_shared_dependency_head.sh` —— A→C 共享分支迁移的可重放检查点
- `git_network_guard.sh`、`clone_or_pull.sh`、`branch_utils.sh`、`prepare_attempt.sh`
- `stage_and_guard.sh`、`commit_and_push.sh`、`post_push_verify.sh`
- `create_mr.sh`、`set_issue_label.sh`、`reconcile.sh`、`summarize_attempt.sh`
- `archive_execution_logs.sh`

**接口约定**：这些 wrapper 已经是"一个 JSON envelope 出 stdout"，天然适配 activity 调用。
activity = 组装 env → `subprocess.run` → `json.loads(stdout)` → 转 dataclass。
**activity 是薄适配层，不含业务判断**；判断留在 workflow（可重放）或 shell（已验证）。

对长任务（`run_acpx_attempt.sh`）额外要求：activity 内起后台任务周期
`activity.heartbeat()`，并监听取消以杀掉子进程**进程组**（复用现有 teardown 逻辑）。

### 5.3 删除

**executor 侧（P1）**：`_driven_launch_coordinator.sh`、`dispatch_record_spawn.sh`、
`record_executor_batch_spawn.sh`、`resolve_executor_batch_reconcile.sh`、
`ingest_subagent_completion.sh`、`reap_driven_orphan_placeholders.sh`、
`emit_driven_batch_acceptance.sh`、`drain_driven_outbox.sh`、`notify_dispatcher.sh`、
`openclaw_agent_transport.sh`、`import_driven_handoff.sh`、`drain_driven_handoff_intents.sh`、
三层任务体系、`run_executor_batch_tick.sh` 的 coordinator replay 与孤儿回收段。

**dispatcher 侧（P2）**：`_executor_batch_outbox_lib.sh`、`enqueue_executor_batch_request.sh`、
`drain_executor_batch_outbox.sh`、`record_executor_batch_receipt.sh`、`record_executor_batch.sh`、
`apply_executor_batch_event.sh`、`handle_executor_batch_event.sh`、
`recover_legacy_executor_batch_bridge.sh`、`recover_executor_batch_callback_acceptance.sh`、
整套 callback nonce、整套 legacy FIFO（`executor_queue.json` / `drain_executor_queue.sh` / 旧 I2 路径）。

**粗估：36k 行中可删除 12–15k 行**，且删除的正是最脆弱的部分。
（相对 LangGraph 方案，Temporal 额外吃掉冷却/重试/回收/超时派生这几段，
删除量偏向区间上沿。）

---

## 6. MCP 接口设计

原则：**任何 tool 不阻塞超过 30 秒**。每个 tool 是 Temporal Client 的一次调用。

```python
submit_requirement(
    idempotency_key: str,                    # 客户端生成；直接用作 Temporal workflow_id
    project: str,                            # group/subgroup/project
    selector: Selector,                      # single | iid_list | range | open_unfinished | open_label
    auto_merge: bool = False,
    branch: str | None = None,               # 处理基准分支
    merge_target_branch: str | None = None,  # MR 目标分支
    origin: Origin | None = None,            # channel/user/conversation/reply_agent/...
) -> { run_id, batch_id, matched_count, snapshot_digest, status }
#   → client.start_workflow(...)，捕获 WorkflowExecutionAlreadyStartedError 后转 query 返回现状

get_run(run_id)              -> { status, items: [{iid, status, mr_url, reason}], counts }
#   → handle.query("get_run")，不触发任何 IO

set_slots(n: int)            -> { slot_count, previous, active_count, draining }
set_acpx_timeout(duration)   -> { acpx_timeout_seconds, previous, applies_to }
#   → handle.signal(...)；返回值用一次 query 读回确认

cancel_run(run_id)           -> { cancelled: [...], already_terminal: [...] }
#   → handle.cancel()，取消经 child workflow 传播至 acpx 子进程

get_issue(project, iid)      -> { state, retry_count, cooldown_until, execution_run_id, ... }
#   → 直接 query IssueWorkflow（id 可由 project+iid 推出，无需查表）
```

**幂等性设计（关键简化）**：`idempotency_key` 直接作为 Temporal `workflow_id`。
重复提交同一 key → `start_workflow` 抛 `WorkflowExecutionAlreadyStartedError` → 转 query
返回同一 run 的当前状态，不新建。
这一条**免费替代**现有的 durable outbox + 稳定 `batch_id` 复用 +
"ack 丢失只重投同一 intent、绝不生成新 ID 冒充恢复"整套机制。

同理 `IssueWorkflow` 的 `workflow_id = issue-<project>-<iid>` **本身就是 per-Issue 互斥锁**——
第二个批次想跑同一个 Issue 时会直接被引擎拒绝，不需要任何 claim 表。

**LLM 的职责边界**：`req_intake` agent 只做自然语言 → 结构化参数的转换，
包含现有 `prepare_executor_issue_payload.sh` 中的精细语义：
否定窗口（"不要/无需/不需要/不得"）、`force_rerun_pr` 动作词可位于宾语之后、
处理基准分支与 MR 目标分支的字段归属、多个不同 project 候选必须澄清。
**这部分必须留给 LLM，不要试图搬进确定性的 workflow 节点。**

---

## 7. workflow 设计要点

### 7.1 workflow 层次与 id 约定

| workflow | id | 职责 |
|---|---|---|
| `RequirementRunWorkflow` | `idempotency_key` | 冻结 snapshot、成组、按槽位放行、聚合结果、通知 |
| `IssueWorkflow` | `issue-<project>-<iid>` | 单个 Issue 的完整生命周期（含冷却重试） |
| `SharedBranchWorkflow`（可选） | `sharedbranch-<project>-<branch>` | 共享依赖分支的串行化；id 即互斥 |
| `LabelWatchWorkflow` | 固定单例 | 捕获人工标签变更并 signal（§2.4） |

`IssueWorkflow` 的 id **不含批次**，这是刻意的：它让"同一 Issue 同时只能有一次执行"
成为引擎保证，跨批次也成立。

### 7.2 状态机直接照搬 `label_lifecycle.md`

workflow 的内部状态枚举与 GitLab 标签**一一对应**，不新造语义：
`todo/retry/new/continue → doing → done → pr → finish`，
`blocked-cc` / `blocked-dispatcher` 走冷却重试，
`retry_count > blocked_retry_limit` 升级 `failed-*`，
`timeout` 终态且不消耗 `retry_count`。

**每次状态迁移仍然通过 `set_issue_label.sh` 落到 GitLab**——标签是对外真相（§7.5）。

### 7.3 并发控制是双层的

- **物理层**：worker 的 `max_concurrent_activity_task_executions` —— 保护机器资源
- **逻辑层**：`RequirementRunWorkflow` 内分别限制并行仓库数与每仓库 Issue 数，对应
  `EXECUTOR_MAX_CONCURRENCY` / `/slot` 和
  `EXECUTOR_MAX_ISSUES_PER_REPOSITORY` / `/repo-slot`

两层都需要。只靠 worker 配置无法实现"运行时调整且缩容不取消在途"的语义；
只靠 workflow 信号量则在多 worker 场景下无法保护单机资源。

### 7.4 超时分层大幅简化

`execute` activity 的 `start_to_close_timeout` = `ACPX_TIMEOUT_SECONDS` + 余量，
`heartbeat_timeout` 取 60s 量级。
外层不再需要 `exec_tool_timeout` / `executor_agent_timeout` / `queue_launch_reclaim` /
`stuck_after_minutes` 这套派生预算 —— 它们全部是为了套住 OpenClaw 多层 timeout 才存在的。

**保留**：OpenClaw 全局 `runTimeoutSeconds` 仍独立，不被这套联动（现状纪律不变）。

### 7.5 双真相源的对账纪律（重要）

Temporal 事件历史是**编排真相**，GitLab label 是**对外真相**。二者会短暂不一致
（activity 成功但历史尚未落、人工在 GitLab 上直接改标签）。因此：

- `reconcile.sh` **不删除**，改为由 `LabelWatchWorkflow` 周期调用的 activity
- 冲突裁决规则：**人工操作优先**。人工打 `continue` / 剥 `timeout` 一律视为权威指令，
  由 `LabelWatchWorkflow` signal 进对应 `IssueWorkflow`（若已终态则 `signal_with_start` 复活）
- 禁止在 workflow 内缓存 label 状态后长期使用——每次决策前重新读取

### 7.6 LangGraph 的（唯一）位置

若 P3 的 `review` 演化成多步 LLM 推理，把它写成一张 LangGraph 图，约束如下：

- 整张图在**单个 activity 内**执行，activity 边界即重试边界
- 图**不做任何副作用**：只读 MR diff / 测试报告，输出 `pass | retry | escalate` 结构化决策
- 图**不使用 checkpointer**（持久化由 Temporal 独占，§2.3）
- 该 activity 设 `maximum_attempts` 有限值，失败按 `blocked-*` 处理

**判据**：若 `review` 只是"跑测试 + 看退出码"，不要引入 LangGraph，普通 Python 即可。

### 7.7 No-Fallback 用类型系统编码

activity 抛 typed exception → workflow 按异常类型分支到对应 `blocked-*`，
任何 activity 不得 catch 后即兴处理。这比 prompt 规则强得多 —— 现状靠 `SOUL.md`
写"不内联重写逻辑、不换更简单的命令"来维持。
`non_retryable_error_types` 把"这类错误不该重试"写进策略而非注释。

---

## 8. 分阶段路线

### P0 · 可行性验证（约 1–1.5 周，不写产品代码）

五个 spike，**任一不通过即终止或重估整个计划**：

| Spike | 验证内容 | 通过标准 |
|---|---|---|
| A | Python `subprocess` 直接执行 `run_executor_attempt.sh` | 产出的 `worker_result.json` 与现有 subagent 路径**逐字节等价** |
| B | 104 上 OpenClaw agent 连接本机 MCP server | 一次 tool call 往返成功；确认 `2026.4.9` 支持所需 MCP transport |
| C | 蓝区离线安装 Temporal Server + PostgreSQL | 完整离线物料清单可安装并起服务；**确认 SQL advanced visibility 可用、无需 Elasticsearch**（§3.3） |
| D | `temporalio` Python SDK 在 104 实际 OS 上可用 | manylinux wheel 可离线安装；workflow sandbox 正常；跑通一个含 `sleep` + Signal + Cancel 的样例 |
| E | 长 activity 取消链路 | 跑一个 30 分钟 fake acpx，`handle.cancel()` 后**子进程组确实被杀干净、无孤儿** |

Spike E 单列的理由：它是 §3.6 的实机验证，也是现状唯一缺失的能力。

### P1 · 执行器控制面（约 4–6 周）—— 最大收益、最小爆炸半径

- Temporal 接管 executor 的调度、`IssueWorkflow` 生命周期、acpx 子进程
- 逐个 wrapper 定级重试语义（§3.6 三分类表），**这是本阶段的主要设计工作量**
- **`req_dispatcher` 完全不动**：照旧发 I1、照旧收 I3；只是 I1 打到 MCP server，
  I3 由 notify activity 用同一 transport 回投
- 删除 §5.3 executor 侧全部清单
- **验收**：现有 executor shell 测试全绿（fake `glab` 测试改为驱动 activity）
  ＋ 新增 workflow replay 测试（Temporal 官方 replayer，防重放不一致）
  ＋ 影子运行至少一周，逐 Issue 比对终态 / MR / label 与旧路径一致
  ＋ **杀 worker 演练**：在 acpx 执行中途 `kill -9` worker，确认恢复行为符合预期

### P2 · 收编 dispatcher 控制面（约 3–4 周）

- I1 / I3 / nonce / receipt / mirror / bridge 全部删除；一条 workflow 链从需求走到通知
- OpenClaw 只保留两件事：NLU intake（调 MCP）＋ 结果出口（也可收进 notify activity）
- **验收**：端到端 ＋ 幂等重放（同 key 重投不产生第二个 run）＋ 崩溃恢复演练
  ＋ 取消演练 ＋ 人工标签介入演练（`continue` / 剥 `timeout` 均能正确回流）

### P3 · 新能力（按需，非必须）

- `review` / `retry` 逻辑；**仅当它是多步 LLM 推理时**才引入 LangGraph（§7.6）
- Signal 驱动的人工审批
- 用 Temporal Schedule 替代 OpenClaw 侧的定时触发（可顺带惠及 `acpx_auto_tester` / `emcp`）
- 收编 `git_issuer` 为 activity

---

## 9. 风险登记

| # | 风险 | 缓解 |
|---|---|---|
| R1 | **约 3–6 人月，用于替换一个正常工作的系统**；收益是"删掉不可靠性 + 删掉协议开销"，不是新功能 | P0 严格卡门槛；P1 交付后重新评估是否继续 P2 |
| R2 | 重写 shell 会静默丢掉安全加固 | **硬规则：效果层一行不重写，只在 activity 内 subprocess 调用**（§5.2） |
| R3 | **凭据进入事件历史并在 Web UI 可见**（比 checkpointer 方案更尖锐） | state/activity 签名层面禁止；CI 自动化扫描；Web UI 仅绑 `127.0.0.1`（§3.5） |
| R4 | Temporal 上游演进 + 蓝区离线升级困难 | Server 与 SDK 版本 pin 死并成对升级；不使用 experimental API |
| R5 | 现有约 150 个 shell 测试是资产，迁移中可能失活 | 效果层测试原样保留；控制面测试新写 pytest + Temporal replayer；两者都进 CI |
| R6 | P1 期间两套 spawn 路径并存会争抢 worktree / label | **不允许部分迁移**：executor spawn 路径一次性切换（§3.1） |
| R7 | 新增常驻服务（Temporal Server + PostgreSQL + Worker + Web UI）的运维成本，相对现状"同步一个目录"的部署方式 | systemd + 健康检查；争取复用蓝区规划 5.3 的关系型数据库而非自建；影子期允许 dev server，生产必须 PostgreSQL |
| R8 | **workflow 确定性约束是全新的编码纪律**，违反后果是重放失败而非立即报错 | 写进 workspace `AGENTS.md`（与 jq 1.5 基线同级）；lint 规则；replayer 进 CI（§3.4） |
| R9 | **副作用型 activity 被默认重试策略重复执行**（如 acpx 跑两遍） | 逐 wrapper 定级三分类表，`maximum_attempts=1` 为重副作用默认值（§3.6） |
| R10 | **workflow 代码升级与在途实例不兼容** | `workflow.patched()` / Worker Versioning；发布流程加"在途实例检查"步骤 |
| R11 | 双真相源（事件历史 vs GitLab label）漂移 | 保留 `reconcile.sh`；人工操作优先的裁决规则；`LabelWatchWorkflow` 周期对账（§7.5） |
| R12 | 引入 Temporal **和** LangGraph 造成双持久化层与概念重复 | P1/P2 不引入 LangGraph；P3 引入时限定为单 activity 内的无副作用决策图（§7.6） |

---

## 10. 方案对比与推荐

三条路，成本递增：

| | A. 常驻 daemon | B. **Temporal（推荐）** | C. LangGraph |
|---|---|---|---|
| 删除 spawn 全套机制（§2.1） | ✅ | ✅ | ✅ |
| 删除跨 agent 协议（§2.2） | ✅ | ✅ | ✅ |
| 崩溃恢复 | ❌ 手写 | ✅ 原生 | ✅ checkpointer |
| **删除冷却/重试/tick 回路（§2.4）** | ❌ 手写 | ✅ 原生 | ❌ 需外部调度器 |
| **per-Issue 互斥围栏** | ❌ 手写 | ✅ workflow id | ❌ 手写 |
| **取消传播到 acpx** | ❌ 手写 | ✅ 原生 | ❌ 手写 |
| 运行时信号（`/slot`、`/repo-slot`、审批） | ❌ 手写 | ✅ Signal | ⚠️ 进程内 |
| 图编排 / LLM 节点生态 | ❌ | ⚠️ 普通控制流 | ✅ |
| 新增运维面 | 1 个进程 | **Server + DB + Worker + UI** | Server + DB |
| 新增编码纪律 | 低 | **确定性 + 版本化（中高）** | 低 |
| 粗估成本 | 小 | 中 | 中 |

**对 A（原 §10 的 500 行 daemon 方案）的重新评估**：它在"只要把 LLM 移出控制回路"这一
狭义目标下依然成立。但一旦承认系统真正需要的是**持久化定时器 + 重试上限 + 单例围栏 +
取消传播 + 崩溃恢复**（而这些正是现状 36k 行 shell 里最脏的部分），
那个 daemon 就不是 500 行——它是在**重新实现一个更差的 Temporal**，
和现在的 shell 犯同一个错误，只是换了种语言。

**对 C 的评估**：LangGraph 解决的是"图怎么写"，而本系统的图是一条近乎线性的链；
它不解决定时器、互斥、取消、外部信号——即痛点所在。作为主控制面是**选错工具**。

👉 **推荐：B。** 若组织上无法接受新增 Temporal Server + 数据库的运维面，
则退回 A 并**明确接受**冷却重试、互斥、取消这些仍然手写的事实（即：只拿 §2.1 + §2.2 的收益，
放弃 §2.4 + §2.5）。**不建议以 C 作为主控制面。**

---

## 11. 待决策项

以下选择会实质改变设计，需在进入 P0 前明确：

1. **编排引擎选型**：Temporal ／ 自研 daemon ／ LangGraph（§10）。
   本文推荐 Temporal；若否决，需同时确认放弃 §2.4 与 §2.5 的收益。
2. **改造动机排序**：主要解决 LLM 不守规矩 ／ 需要 review-retry 能力 ／ 需要可观测性
   ／ 需要取消与人工介入能力？—— 排序不同会改变 P1 与 P3 的边界。
3. **是否允许重写 shell**：本设计的硬前提是**不重写**。若预期"顺便把 shell 换成 Python"，
   工作量与风险须重新评估（不建议）。
4. **企微入口是否保留 OpenClaw**：本设计保留（LLM 做 NLU 有真实价值）。
   若要企微直连，NLU 逻辑需另行安置。
5. **Temporal 持久化归属**：复用蓝区规划 5.3 的共享 PostgreSQL，还是 104 本机单独起一套？
   —— 影响运维边界与备份策略（蓝区规划 10.1）。
6. **人工标签变更的收口方式**：GitLab webhook → 104 薄接收器，还是 `LabelWatchWorkflow`
   周期扫描（§2.4）？—— 取决于蓝区 GitLab 是否允许回调 104。
7. **workflow 版本化策略**：`workflow.patched()` 还是 Worker Versioning（Build ID）？
   —— 影响发布流程（R10）。
8. **P1 验收口径**：影子运行时长、比对哪些字段算通过、杀 worker 演练的通过标准。

---

## 12. 相关文档

- 现状运行契约：`workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`、
  `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/SKILL.md`
- **Issue 状态机（本设计 §7.2 直接照搬）**：
  `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/label_lifecycle.md`
- 人工 `continue` 回流的评审契约（§7.5 冲突裁决依据）：
  `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/continue_mode.md`
- I1 / I3 / acceptance 严格 schema：
  `workspace-req_dispatcher/skills/requirement_dispatch/references/trigger_command.md`
- subagent prompt 与三层任务体系：
  `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md`
- 104 ↔ 114 通信协议：[`blue-zone-infrastructure/openclaw-104-114-communication-contract.md`](blue-zone-infrastructure/openclaw-104-114-communication-contract.md)
- 蓝区基础服务规划（5.3 关系型数据库 / 5.4 缓存 KV MQ / 10.1 备份）：
  [`blue-zone-infrastructure/2026-06-29-blue-zone-base-services.md`](blue-zone-infrastructure/2026-06-29-blue-zone-base-services.md)
- 离线发布经验（wheel / RHEL7 参考）：[`openclaw-rhel7-offline-release.md`](openclaw-rhel7-offline-release.md)
