# Issue 状态机 v2 —— 状态 / label 语义变更记忆

> 这是给 Claude 自己看的持久化记忆，只记**状态机语义**（有哪些状态、哪些 issue label、迁移/触发规则）。
> 图的画法（节点布局、走线、记法）在 `statemachine.v2.drawio`，本文件不复述。
> 实现仓库：`workspace-req_executor/`（脚本 `scripts/`、Temporal `temporal/workflows/`）。

---

## 0. 本次改动（语义增量，相对上一版）

1. **`failed` 按归因拆成 `failed-cc` / `failed-dispatcher`**（镜像 `blocked` 的拆法）。提升映射：`blocked-cc` 超限 → `failed-cc`；`blocked-dispatcher` 超限 → `failed-dispatcher`。目的：失败终态也"看到 label 即知改哪边"。
2. **新增 `model:{tier}` 正交持久 label 维度** + **model 逐级自动升级机制**：按 issue 解决质量自动升 model（`model:flash → model:pro → model:max`），per-issue 单调不降。
3. **新增一次性软信号 label `quality:low`**：人工在评审态加，作为升 model 档的软触发之一，升档生效后移除。
4. **model 升档触发按侧统一**：CC 侧 `{blocked-cc, timeout, failed-cc}` 重跑 → 升一档；调度器侧 `{blocked-dispatcher, failed-dispatcher}` → 不升（升 model 对基础设施问题无用）。

> 本次落地：`pr` **替换** `done`（不再叠加，`done` 仅瞬态）；`blocked` 拆成 `blocked-cc` / `blocked-dispatcher`；`failed` 拆成 `failed-cc` / `failed-dispatcher`；新增 `model:{tier}` 正交维度与 `quality:low` 软信号。

---

## 1. 状态全集（主状态机）

每个状态 = 一个 GitLab 工作 label（终态 `CLOSED` = issue `closed`）。

| 状态 (label) | 进入条件 | 含义 / 活动 | 出口（→ 目标，触发/守卫） |
| --- | --- | --- | --- |
| **QUEUED** (`todo`/`new`/`retry`/`continue`) | 人工打入口标签（= 状态机起点） | 已登记，等待被调度器自动认领 | 被选中 → `AUTO_RUNNING`；未选中则保持 |
| **AUTO_RUNNING** (`doing`) | 被调度器选中：清空旧工作标签、打 `doing`；PREPARE 解析 model 档位并注入本轮 | `acpx claude exec` 跑一次 attempt（人不介入） | 完成后按 `outcome` 分流到 5 个后继之一（见 §3） |
| **AWAITING_REVIEW** (`pr`) | `outcome=done` → 开 MR → `pr` 替换 `done` | 等人 review/合并 MR | 合并 MR → `CLOSED`；或人工加 `continue`（可带 `quality:low`）→ `QUEUED` |
| **blocked-cc** (`blocked-cc`) | CC 侧失败：acpx 非超时失败 / `NO_CHANGES` / push 被拒 / acpx 后步骤失败 | partial work 已 push 到 `WORK_BRANCH` | 改提示词+hulat → `retry`/`continue` → `QUEUED`（升 model 档）；或 `retry_count > limit` → `failed-cc` |
| **blocked-dispatcher** (`blocked-dispatcher`) | 调度器侧失败：prep / spawn / scope eviction / 子流程错 / 等不到回调(stuck) | 无 CC 产出，看 `block_reason` | 改 dispatcher → `retry` → `QUEUED`（model **不升**）；或 `retry_count > limit` → `failed-dispatcher` |
| **timeout** (`timeout`) | `acpx claude exec` 跑超 wall-clock 上限 | partial 已 push，无 MR/pr；不自动重试、**不消耗 `retry_count`**（parked），**永不自动提升 failed** | 改提示词/hulat 缩小任务 → `retry`/`continue` → `QUEUED`（升 model 档） |
| **failed-cc** (`failed-cc`) | `blocked-cc` 的 `retry_count > limit` 被提升（retry budget 耗尽是唯一成因）；或 `outcome=failed` 直达（罕见） | 永不自动重排（CC 侧），待人工 | 改提示词/hulat → `retry`/`continue` 重新武装 → `QUEUED`（升 model 档，封顶保持 max）；或人工 `close` → `CLOSED` |
| **failed-dispatcher** (`failed-dispatcher`) | `blocked-dispatcher` 的 `retry_count > limit` 被提升 | 永不自动重排（调度器侧），待人工 | 改 dispatcher → `retry` 重新武装 → `QUEUED`（model **不升**）；或人工 `close` → `CLOSED` |
| **CLOSED** (issue `closed`) | MR 合并（`Closes #iid` 自动关闭）或人工直接关闭 | `reconcile` 永久硬跳过，不再调度 | 终态 |

注意：`failed-cc` / `failed-dispatcher` 名为"失败态"但**有出边可被人工重新武装**，不是真正的终态；唯一终态是 `CLOSED`。任意非终态都可被人工 `close` → `CLOSED`。

---

## 2. issue label 模型（两条正交维度 + 一个软信号）

### 2.1 工作标签维度（互斥，任意时刻恰好一个）

- 入口：`todo` / `new` / `retry` / `continue`
- 进行：`doing`
- 产出（临时）：`done`（写完 Wiki、建 MR 前的过渡）
- 待评审：`pr`（建 MR 后**替换** `done`，`done` 被移除）
- 异常：`blocked-cc` / `blocked-dispatcher` / `timeout` / `failed-cc` / `failed-dispatcher`

互斥规则（`set_issue_label.sh`）：加任一工作标签都移除其它工作标签。`{done+pr}` 永不并存（`pr` 替换 `done`）；唯一瞬态并存对 = 建 MR 前失败的 `{done+blocked-cc}` 或 `{done+blocked-dispatcher}`。

**进 `doing` 清除集**（进 `doing` 时移除、只留 `doing`）：
`{ todo, new, retry, continue, done, pr, blocked-cc, blocked-dispatcher, timeout, failed-cc, failed-dispatcher }`。
**该清除集不含 `model:{tier}`**（model 维度持久，进 `doing` 不清除）。

### 2.2 `model:{tier}` 维度（正交、持久、单调升）

- 取值：`model:flash`（TIER_0，最低/默认）→ `model:pro`（TIER_1）→ `model:max`（TIER_2，封顶）。档数 = trigger 可配的有序 model 列表（3 档为示例）。
- 与工作标签**正交并存**；互斥只在本维度内部（恰好一个 `model:{tier}`）。
- **per-issue 单调不降**：只换成更高档，跟随 issue 终身到 `CLOSED`。新 issue 无 `model:{tier}` → 视为 TIER_0；首次 PREPARE 显式打最低档。
- source of truth = GitLab 标签；`state.json` 的 `model_tier` 仅缓存，`reconcile` 让缓存向标签看齐。

### 2.3 `quality:low`（一次性软信号）

人工在 `AWAITING_REVIEW` 加，表示"这轮质量一般"。作为升 model 档的软触发之一；**升档生效后被移除**（不长期存在）。

---

## 3. 迁移与触发规则

### 3.1 outcome → label（`AUTO_RUNNING` 完成后写回，据此分流）

| outcome | 写回 label | → 状态 |
| --- | --- | --- |
| `done` | `pr`（替换 `done`） | AWAITING_REVIEW |
| CC 侧失败 | `blocked-cc` | blocked-cc |
| 调度器侧失败 | `blocked-dispatcher` | blocked-dispatcher |
| acpx 超时 | `timeout` | timeout |
| `failed`（直达，罕见） | `failed-cc` | failed-cc |

### 3.2 retry 超限提升（自动）

- `blocked-cc` 且 `retry_count > blocked_retry_limit` → `failed-cc`
- `blocked-dispatcher` 且 `retry_count > blocked_retry_limit` → `failed-dispatcher`
- `timeout` **不参与**提升（不消耗 `retry_count`）

### 3.3 model 升档触发（`UPGRADE?`，在 PREPARE 的 `resolve_model_tier` 求值）

求值时机 = **重新武装并进 `doing` 时**（基于"导致本次排程"的上一轮历史）：

```
UPGRADE? = 硬触发 ∪ 软触发
  硬触发：上一轮 outcome ∈ { blocked-cc, timeout, failed-cc }
  软触发（任一）：quality:low  ∨  continue 累计次数 ≥ N  ∨  自动评分 < 阈值（黑盒·未实现·占位）
  排除：blocked-dispatcher / failed-dispatcher（调度器/基础设施侧）
判定：命中且未封顶 → 升一档；命中但已封顶 → 保持 max；未命中 → 保持当前档。
```

一句话：**CC 侧 `{blocked-cc, timeout, failed-cc}` 重跑升一档；调度器侧 `{blocked-dispatcher, failed-dispatcher}` 不升。**

### 3.4 retry vs continue（重跑模式，沿用旧规则）

`_attempt_mode_for_entry`：仅当 `continue` 是**唯一**工作标签 → continue 模式（基线 `origin/WORK_BRANCH`，恢复上轮产物，prompt 注入上轮 summary+评审意见）；否则（`retry`/`todo`/`new`，或 `continue` 与其它并存）→ fresh 模式（基线 `origin/DEV_BRANCH`，归档上轮产物）。agent 永不自己打 `continue`。

---

## 4. 实现状态（已落地）

上述 enriched label 模型（`blocked` 拆分、`failed` 拆分、`pr` 替换 `done`、`model:{tier}`、`quality:low`）**已在脚本与参考文档中落地**。落地点（实际文件）：

- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/ensure_labels.sh`：创建 `blocked-cc`/`blocked-dispatcher`/`failed-cc`/`failed-dispatcher`/`timeout`/`done`/`pr`/`model:<tier>`（按 `model_tiers` 配置）/`quality:low`；不再创建单一 `blocked`/`failed`（仍兼容识别残留）。
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/set_issue_label.sh`：工作标签互斥组扩展（含 `blocked-cc`/`blocked-dispatcher`/`failed-cc`/`failed-dispatcher`）；`model:{tier}` 排除出"进 `doing` 清除集"（正交直通）；三组语义：work 互斥、model:\* 正交、quality:\* 正交。
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/reconcile.sh`：完成判定改为「有 `pr`」（不再要求 `done∧pr`）；`has_blocked`/`has_failed` 按侧拆两路信号；新增读取当前 `model:{tier}` 写入 evidence digest。
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh`（Phase 6 链）：blocked/failed 按 `block_side`（内部推导，不来自 compact reply）落 `blocked-cc`/`blocked-dispatcher`/`failed-cc`/`failed-dispatcher`；`done` 成功路径最终写 `pr`（移除 `done`）；`timeout` 永不自动提升 `failed`。
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_prepare_tick.sh`：carry-forward `model_tiers`/`continue_upgrade_threshold`；Phase 4 执行 `resolve_model_tier`（读 GitLab model 标签、求 `UPGRADE?`、写 `model:{tier}`、注入 settings 文件、消费 `quality:low`）；写 `state.json.model_tier`/`block_side`/`continue_count`。
- `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md`：子代理失败路径按归因 sync `blocked-cc`/`blocked-dispatcher`/`timeout`；成功路径 Step 6 `done`（瞬态）→ Step 8 `pr`（替换 `done`）；compact reply 不含 `block_side` 字段（dispatcher 内部推导）。

---

## 5. 不变量（贯穿全程）

**GitLab 实时标签 = 状态唯一真相；磁盘 `campaign_state.json` / `state.json`（含 `model_tier`）/ `attempt_state.json` 只是 dispatcher 进度缓存。** 冲突时永远以 GitLab 为准；每 tick 强制 `reconcile.sh` 并写 `reconcile-<ts>.json` 证据文件兜底——**没有证据文件 = 该 tick 判失败**。
