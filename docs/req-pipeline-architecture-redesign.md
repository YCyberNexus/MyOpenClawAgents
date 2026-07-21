# req 三件套架构重构方案

> 文档版本：2026-07-21.1
>
> 适用范围：`req_dispatcher` / `req_executor` / `git_issuer`（104 蓝区）
>
> 当前状态：**设计草案，未实施**。本文不描述现状，只描述一个待评审的目标架构；
> 现状契约以各 workspace 的 `SOUL.md` / `SKILL.md` / `references/` 为准。
>
> 配套流程图：[`req_pipeline_target_architecture.drawio`](req_pipeline_target_architecture.drawio)

## 0. 这份文档解决什么问题

[`req-pipeline-langgraph-migration.md`](req-pipeline-langgraph-migration.md) 回答的是
「**用什么引擎**」（结论：Temporal）。本文回答更上一层的问题：
**现状架构里哪些复杂度是必须保留的领域约束，哪些只是纯 prompt agent 时代的妥协。**

触发这次重构的观察是一句话：

> 冷却重试目前是**按 tick 计数**的（`blocked_cooldown_ticks`），
> 这意味着必须有个外部循环把 2842 行的 `run_executor_batch_tick.sh` 持续跑起来，
> 每轮重扫标签、重算资格、重放 coordinator、回收孤儿、查 `stuck_after_minutes`。
> **调度的时间语义被绑死在轮询频率上。**

沿这条线索回溯，会发现现状里体量最大、最难维护的那几块代码，
根因全都不是业务复杂，而是「OpenClaw prompt agent 做不到某件事，于是绕」。

**重构的第一原则**：先分辨，再动手。把妥协删干净，把本质一行不动地保留下来。

---

## 1. 分辨：妥协产物 vs 领域本质

### 1.1 A 类 · 妥协产物 —— 根因消失后整块归零

| 现状机制 | 真正的根因 | 重构后 |
|---|---|---|
| tick 轮询循环 + `blocked_cooldown_ticks` 按 tick 计数 | prompt agent 无法常驻，只能被 cron 唤醒；没有定时器就只能数 tick | 归零 |
| `sessions_spawn` 三层任务体系（spawn bootstrap / 私有 payload / mode-600 manifest + SHA-256 + 字节数） | 两个 LLM 之间只能传字符串，且要防篡改 | 归零 |
| `ingest_subagent_completion.sh`（1,035 行） | subagent 完成事件不可信：要认证原生事件、绑定 session registry、校验非符号链接 JSONL transcript、要求 final assistant `stop` 行 | 归零 |
| `driven_launch_receipts` / `claim_token_sha256` / `claim_generation` / exact typed authorization boundary | `sessions_spawn` 调用非事务，必须建一套可重放的授权协议来回答「我刚才那次 spawn 到底成功没有」 | 归零 |
| I1 / I3 / `callback_nonce` / outbox / mirror / `received→mirror→accepted` 三段 receipt | `req_dispatcher` 与 `req_executor` 是两个只能互发聊天字符串的独立 agent | 归零 |
| `reap_driven_orphan_placeholders.sh` 孤儿回收 | spawn 会留下半死的 `childSessionKey` | 归零（子进程退出即终态） |
| `exec_tool_timeout` / `executor_agent_timeout` / `queue_launch_reclaim_seconds` / `stuck_after_minutes` 派生预算 | 要把 OpenClaw 的多层 timeout 互相套住 | 归零，只剩一个真实的 acpx wall-clock 超时 |
| `dependency_scan_cursor_iid` 轮转防饥饿 | 单个 tick 只能看**有界视图**，怕靠前的等待前缀永久饿死后面的候选 | 归零（常驻编排器持有完整队列） |
| **严禁并行 spawn** 的硬规则 | 本机 loopback 网关按 channel 串行处理，并行会 `gateway timeout` 并留孤儿 | 归零 |
| `SKILL.md` 中约 900 行防御性 prompt（"never add a markdown fence"、"never Read a script"、"if you ever feel the urge to open a wrapper, that urge itself is the signal to stop"） | LLM 是不可靠的状态机执行器，需要用 prompt 围栏约束 | 归零 |
| `executions/execution-<id>.json` 不可变绑定 + `execution_id` 围栏 | 没有天然的执行身份可用作 stale-callback 栅栏 | 用引擎的 run id 替代 |

> 这一栏加起来是现状 36k 行 shell 的相当一部分，
> 而且**正是最脆弱、最难测、出事最多的那部分**。

### 1.2 B 类 · 领域本质 —— 一行都不能删

- **GitLab 是外部真相源**，会被系统之外的人修改（人工打 `continue`、剥 `timeout`、加 `quality:low`）
- **两次归一化全扫一致才冻结快照**（`create_driven_batch.sh`）—— GraphQL 游标分页期间集合会变
- **exact-GET → SHA-fenced-PUT → exact-GET** 的合并验证（`merge_mr.sh`）
- **push 的 SHA 栅栏**（`commit_and_push.sh` / `post_push_verify.sh`）—— 防并发写同一分支
- **acpx 是小时级黑盒子进程**，只能靠 wall-clock 超时 + 进程组 teardown 控制
- **worktree 按 Issue 隔离**
- **凭据不落盘、不进任何可持久化面**（`run_acpx_attempt.sh` 还会从内层 acpx 进程剥离 token 别名）
- **人工评审回流**是工作流的一部分，不是异常路径（见 `continue_mode.md`）
- **A→C 共享依赖分支**的晚绑定、迁移与可重放检查点
- **PATH 白名单 / `--safe-mode` / 内层 `glab` 全禁 / Git 网络命令禁用**这套执行沙箱

### 1.3 C 类 · 半妥协 —— 需求真实，但实现方式是借来的

| 现状 | 问题 |
|---|---|
| 用 GitLab label 兼作**锁**和**状态存储** | label 是对外展示语义，被借去当并发控制原语；人一改标签就直接动了控制流 |
| `campaign_state.json` 摊了 30+ 字段 | 配置、调度状态、执行状态、终态集合（`blocked_iids`/`failed_iids`/`timeout_iids`/`completed_iids`）、对账证据全混在一个文件里 |
| batch 是一等实体（`batch_id` / outbox / mirror / terminal counts / reconcile） | 批次的本质只是「一次放行意图」，却背了完整生命周期 |
| 槽位存在 scheduler state 里、每 tick 重算 | 槽位是**跨批次全局**的物理资源（现状原话：所有 batch session 共享的物理并发上限），却挂在 per-batch 的调度器上 |

---

## 2. 目标架构

完整流程图见 [`req_pipeline_target_architecture.drawio`](req_pipeline_target_architecture.drawio)。
五层职责：

```text
① 接入层   req_intake（唯一保留的 LLM）—— 自然语言 → 结构化意图，不碰任何状态
② 控制平面 Orchestrator —— 持久化、定时、重试、互斥、取消、信号
③ 执行平面 Activity —— 薄适配：组装 env → subprocess → 解析 JSON envelope → 类型化
④ 效果层   现有 shell wrapper（一行不重写）→ glab / git / acpx / worktree
⑤ 事件入口 GitLab webhook → 薄 HTTP 接收器 → signal
```

控制平面由五类 workflow 组成：

| workflow | id | 生命周期 | 职责 |
|---|---|---|---|
| `RunWorkflow` | `idempotency_key` | 短 | 解析选择器 → 冻结快照 → 逐 IID `signal_with_start` → 聚合通知 |
| `IssueWorkflow` | `issue-<project>-<iid>` | **长** | 单个 Issue 的完整生命周期；id 即互斥锁 |
| `BranchWorkflow` | `branch-<project>-<branch>` | 长 | 共享依赖分支的写入序列化；id 即分支级互斥 |
| `SlotPoolWorkflow` | 单例 | 常驻 | 全局槽位租约 + 跨 project 轮转公平 |
| `DriftWatchWorkflow` | 单例 | 常驻 | **低频**对账，只防 webhook 丢事件，不驱动调度 |

---

## 3. 六个关键设计决策

### 决策 1 · 状态所有权重新划分

现状状态摊在三处且互相兼职。重构后各归各位：

| 层 | 存什么 | 谁写 | 权威性 |
|---|---|---|---|
| 引擎事件历史 | **编排真相**：当前状态、`retry_count`、冷却截止、订阅者列表 | 编排器 | 控制流唯一权威 |
| GitLab label | **对外投影**：给人看、给人改 | activity 写出 | 人工意图的权威 |
| 本地文件 | **只剩产物**：log / `prompt.txt` / diff / 归档分支 | shell | 无控制语义 |

**关键变化**：label 不再兼任锁。互斥由 workflow id 唯一性提供。
人改标签不再直接改控制流，而是变成一个**信号**进入编排器，由编排器裁决。

消掉 `campaign_state.json` 的 `pending_subagents` / `driven_launch_receipts` /
`blocked_iids` / `failed_iids` / `timeout_iids` / `completed_iids` /
`last_reconcile_evidence` 全部字段；剩下的纯配置项挪进配置文件。

### 决策 2 · Issue 是长生命周期实体，不是任务

这是消掉 tick 的核心。现状每轮都要重新「发现 → 冻结 → 认领」，
因为没有任何东西能在两次 tick 之间**记住**这个 Issue 的处境。

新设计：每个被纳管的 Issue 有一个自己的 workflow 实例，从纳管活到终态。

```python
IssueWorkflow(project, iid):
    loop:
        lease = await SlotPool.acquire(project, iid)   # 阻塞等槽位，不轮询
        try:
            await prepare()                            # worktree
            await execute()                            # acpx；activity 超时 = 唯一真实超时
            await finalize()                           # push / MR / label
            if auto_merge: await merge()
            return terminal(finish | pr)
        except Timeout:      return terminal(timeout)  # 不消耗 retry_count
        except Retryable:
            retry_count += 1
            if retry_count > blocked_retry_limit:
                return terminal(failed-cc | failed-dispatcher)
            await set_label(blocked-cc | blocked-dispatcher)
            await sleep(cooldown)                      # 持久化定时器，无人 tick 它
            continue
        finally:
            lease.release()
    # 终态后仍可被 signal 唤醒：人工 continue / 剥 timeout / 显式重跑
```

状态枚举与 `references/label_lifecycle.md` **一一对应**，不新造语义。

一次性消掉：claim/fencing、`pending_subagents`、发现-冻结-认领循环、
`dependency_scan_cursor_iid`、孤儿回收、`stuck_after_minutes`。

**冷却从「N 个 tick」变回「N 分钟」—— 时间语义与轮询频率彻底解耦。**

### 决策 3 · 批次降级为一次性放行意图

`RunWorkflow` 只做四件事：解析选择器 → 调冻结快照 activity →
对每个 IID 发 `signal_with_start`（把自己登记为订阅者）→ 等结果聚合通知。

它**不持有** Issue 的执行状态 —— 那归 `IssueWorkflow`。
同一个 Issue 被两个 run 请求，第二个 run 只是往订阅者列表里加一项，
不会产生第二次执行。这是 workflow id 唯一性白送的。

消掉：batch 的 reconcile、terminal counts、per-batch 状态机、`import_driven_skipped` 那套 handoff。

### 决策 4 · 并发从「调度器发牌」改为「资源租约」

单例 `SlotPoolWorkflow` 持有槽位，`IssueWorkflow` 主动申请租约。

- `/slot <n>` → signal 到 SlotPool，立即生效；**缩容不取消在途**（等自然释放），语义与现状一致
- **round-robin 公平**：等待队列按 project 分桶轮转。常驻实体能看到全量等待者，
  比现状的有界视图 + 防饥饿游标简单得多
- **双层限流**：SlotPool 管逻辑并发（可运行时调），worker 并发上限管物理资源（防机器过载）
- 单例 workflow 的事件历史增长用 `continue_as_new` 定期截断

### 决策 5 · 人工回流改事件驱动，但对账不能删

- **主路径**：GitLab webhook（label events）→ 104 薄 HTTP 接收器 →
  按 `project + iid` 推出 workflow id → signal。已终态的用 `signal_with_start` 复活
- **兜底**：`DriftWatchWorkflow` 低频（15 分钟量级）扫「带 `continue`/`retry` 标签但无活跃 workflow」的 Issue

> ⚠️ **要诚实**：webhook 会丢，对账删不掉。但它的**性质**变了 ——
> 从「驱动整个调度回路的分钟级心跳」，降级为「只防事件丢失的低频漂移检查」。
> `reconcile.sh` 保留，改由这条路径调用。

冲突裁决规则必须明确：**人工操作优先**。GitLab 上的人工标签变更一律视为权威指令。

### 决策 6 · LLM 压缩到两个点

- **必要**：intake NLU。否定窗口（"不要/无需/不需要/不得"）、`force_rerun_pr` 动作词可位于宾语之后、
  处理基准分支 vs MR 目标分支的字段归属、多 project 候选澄清 ——
  这些确定性代码写不好，必须留给 LLM
- **可选（后期）**：review 决策，仅当它演化成多步推理时

其余全部确定性。`git_issuer` 从独立 agent 降为 intake 层的一个 activity：
LLM 判定动作类型（CREATE/CHANGE/CANCEL/SUPERSEDE），activity 执行 `glab` 调用。

---

## 4. 演进阶梯：不必一次到位

按投入递增排，**每一级单独交付都有价值**，且不阻碍下一级。

### 阶梯 0 · 止血（几天，不动架构）

**把冷却从 tick 计数改成绝对时间戳**：`blocked_cooldown_ticks` → `cooldown_until`（epoch 秒）。
tick 从「时钟」降级为「唤醒器」。

不解决任何架构问题，但立刻拿到：调度语义与轮询频率解耦、
tick 频率可自由调整而不改变重试行为、派生预算可以开始简化。
**成本极低，收益立竿见影。**

### 阶梯 1 · 常驻编排器（消掉 A 类妥协的约七成）

一个常驻进程接管调度，OpenClaw 只做 NLU 后 POST 给它。

拿到：spawn 全套归零、跨 agent 协议归零、孤儿回收归零、多层 timeout 归零、并行限制归零。
仍需自己实现：崩溃恢复、持久化定时器、租约、取消传播。

**这是「自研 daemon」路线。** 如果规模稳定、团队不愿引入新中间件，它是合理终点 ——
但要**老实承认**上面四件事得自己写对。

### 阶梯 2 · 引擎化（Temporal）

把阶梯 1 自己写的那四件事换成引擎原语。
额外拿到：取消传播、外部信号、审批介入、事件历史可观测。

代价：新增 Server + DB + Worker 运维面，以及两条全新编码纪律 ——
workflow 确定性约束、副作用 activity 的重试定级。
详见 [`req-pipeline-langgraph-migration.md`](req-pipeline-langgraph-migration.md) §3.4 / §3.6。

### 阶梯 3 · 收编与新能力

dispatcher 控制面并入、`git_issuer` 降为 activity、`review`/`retry`、人工审批、
用引擎的 Schedule 替代 OpenClaw 侧定时触发。

---

## 5. 连带影响（别漏）

- **`acpx_auto_tester` 与 `emcp` 共用 `gitlab_issue_campaign_dispatcher` 这个 skill 名。**
  重构 executor 会波及它们，必须先确认是分叉副本还是共享代码。
  `emcp` 在 `emcp` 分支上已被改写成迭代 DAG 模型，两条线的收敛策略要提前定。
- **约 150 个 shell 测试**：效果层测试原样保留（它们测的是 wrapper，wrapper 不变）；
  控制面测试全部重写。
- **`SKILL.md` 的约 900 行防御性 prompt** 在阶梯 1 之后大部分失去对象，
  必须同步瘦身，否则 prompt 契约与实际架构会长期不一致 —— 这正是当前 `emcp`
  在 `orchestra` 分支上的处境（CLAUDE.md 描述的还是旧 acpx 模型）。

---

## 6. 待决策项

1. **终点定在哪一级？** 阶梯 1（自研常驻）与阶梯 2（Temporal）是真正的分岔口。
   判据不是「哪个先进」，而是：**是否需要「取消运行中批次」和「人工审批介入」
   这两个现状缺失的能力**。需要 → 阶梯 2；不需要 → 阶梯 1 足够，运维面小一个量级。
2. **蓝区 GitLab 能否 webhook 回调 104？** 这决定决策 5 是「事件驱动 + 低频兜底」
   还是「只能中频轮询」。后者会让「消掉 tick」的收益打折 ——
   降不到 15 分钟，可能得停在 1–2 分钟。
3. **是否接受 label 不再兼任锁？** 这是决策 1 的实质影响：
   评审人的操作手感会变 —— 比如剥 `timeout` 后不再是「下次 tick 自然重跑」，
   而是「立即触发一次唤醒」。需要确认现有评审流程能接受。

---

## 7. 相关文档

- 引擎选型与迁移路线：[`req-pipeline-langgraph-migration.md`](req-pipeline-langgraph-migration.md)
- 目标架构流程图：[`req_pipeline_target_architecture.drawio`](req_pipeline_target_architecture.drawio)
- **现状**流程图（对照用）：[`req_dispatcher_executor_flow.drawio`](req_dispatcher_executor_flow.drawio)
- Issue 状态机（决策 2 直接照搬）：
  `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/label_lifecycle.md`
- 人工 `continue` 回流的评审契约（决策 5 的裁决依据）：
  `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/continue_mode.md`
- 现状状态字段全貌（决策 1 的消除清单来源）：
  `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/state_schema.md`
- 104 ↔ 114 通信协议：
  [`blue-zone-infrastructure/openclaw-104-114-communication-contract.md`](blue-zone-infrastructure/openclaw-104-114-communication-contract.md)
