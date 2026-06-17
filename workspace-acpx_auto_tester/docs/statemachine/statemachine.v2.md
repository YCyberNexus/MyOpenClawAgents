# Issue 状态机 v2 —— benchmark-test 分支状态 / label 语义记忆

> 这是给 Claude 自己看的持久化记忆，只记 **benchmark-test 分支**的状态机语义（有哪些状态、哪些 issue label、迁移/触发规则）。
> 图的画法（节点布局、走线、记法）在 `statemachine.v2.drawio`，本文件不复述。
> 实现仓库：`workspace-acpx_auto_tester/`（脚本 `scripts/`）。
>
> **权威以脚本与 reference 为准。** 本文件与 [`workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/label_lifecycle.md`](workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/label_lifecycle.md) / [`references/state_schema.md`](workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/state_schema.md) 冲突时，以那两个为准。
>
> **本分支关键特征（先读这段）：**
> - 无 MR / 无 `pr` 标签，`done` 即**终态成功**（永不被替换）；GitLab 级别完成 = 人工关闭 issue。
> - `continue` / resume **已禁用**：每次 attempt 强制 fresh，从 `origin/${dev_branch}` 干净基线起跑。
> - 模型档位由 per-tick **必填**触发字段 `pin_model_tier` 钉死：**无失败升档阶梯、无单调只升不变式**，pin 可下调档位。
> - 每 attempt 只推送**一个不可变的 per-attempt 远端分支** `LOCAL_ATTEMPT_BRANCH = issue/<iid>-auto-fix-att<NNN>-<tier>`（非 force、推一次、永不覆盖；尾部 `-<tier>` 是本次锁定的模型等级 flash/pro/max，同样的后缀也加在该次运行的 `log/attempt-<NNN>-<tier>/` 目录上，便于从分支列表与文件夹一眼看出用了哪档模型）；`WORK_BRANCH = issue/<iid>-auto-fix` 退化为**仅命名前缀，不再推送**。
>
> production / 通用版 v2 设计（`pr` 替换 `done`、`resolve_model_tier` 失败升档、`continue` 续作、`quality:low` 软信号、Temporal 工作流 `temporal/workflows/`）**不在本分支、也不在本文件**——如需参考见其它分支与 git 历史，不要据其推断 benchmark-test 的真实行为。

---

## 0. 关键语义概述（相对更早 v1 的增量）

1. **`blocked` / `failed` 按归因拆成 per-side 两套**：`blocked-cc` / `blocked-dispatcher` 与 `failed-cc` / `failed-dispatcher`（v1 的单一 `blocked` / `failed` 退出词表）。提升映射同侧：`blocked-cc` 超限 → `failed-cc`；`blocked-dispatcher` 超限 → `failed-dispatcher`。目的：看 label 即知失败在哪一侧（CC = Claude Code，dispatcher = 调度器/基础设施）。
2. **`model:{tier}` 正交持久维度**：`model:flash` / `model:pro` / `model:max` 跟随 issue 终身。benchmark-test 上由 `pin_model_tier` **每 tick 钉死**，不做任何自动升档。
3. **`timeout` 独立终态停靠标签**：acpx wall-clock 超限，partial work 已推送，**不消耗 `retry_count`、不自动重试、永不提升 `failed`**。
4. **每 attempt 不可变远端分支留档**：模型评测需要每次运行的产物可横向对比，故每 attempt 推一个永不覆盖的 per-attempt 分支。

---

## 1. 状态全集（主状态机）

每个状态 = 一个 GitLab 工作 label（终态 `CLOSED` = issue `closed`）。

| 状态 (label) | 进入条件 | 含义 / 活动 | 出口（→ 目标，触发/守卫） |
| --- | --- | --- | --- |
| **QUEUED** (`todo`/`new`/`retry`) | 人工打入口标签（= 状态机起点），或触发 `require_labels` 命中 | 已登记，等待被调度器自动认领 | 被选中 → `AUTO_RUNNING`；未选中则保持 |
| **AUTO_RUNNING** (`doing`) | 被调度器选中：清空旧工作标签、打 `doing`；PREPARE 用 `pin_model_tier` 钉本轮 model 档位并注入 | `acpx claude exec` 跑一次 fresh attempt（人不介入） | 完成后按 `outcome` 分流到 5 个后继之一（见 §3.1） |
| **done** (`done`) | `outcome=done`：分支已推送、post-push 校验通过、Wiki 产物发布 | **终态成功标签**，永不被替换（无 MR、无 `pr`）；等人工 review 后关闭 issue | 人工关闭 issue → `CLOSED`；或 CC 侧后续失败 → 瞬态并存 `done` + `blocked-cc` |
| **blocked-cc** (`blocked-cc`) | CC 侧失败：acpx 非超时失败 / `NO_CHANGES` / push 被拒 / acpx 后步骤失败 | committable partial work 已尽力 push 到 `${LOCAL_ATTEMPT_BRANCH}`（不可变 per-attempt 分支）；不发 Wiki 证据 | 改提示词+hulat，人工 `retry` → `QUEUED`（model 由该 tick 的 `pin_model_tier` 决定）；或 `retry_count > limit` → `failed-cc` |
| **blocked-dispatcher** (`blocked-dispatcher`) | 调度器侧失败：prep / spawn / scope eviction / 等不到回调(stuck) / `pin_model_tier` 不在 effective 档集 | 无 CC 产出，看 `block_reason` | 改 dispatcher / 触发参数，人工 `retry` → `QUEUED`；或 `retry_count > limit` → `failed-dispatcher` |
| **timeout** (`timeout`) | `acpx claude exec` 跑超 wall-clock 上限（`acpx_timeout_seconds`） | partial work 已 push 到 `${LOCAL_ATTEMPT_BRANCH}`，无 MR/pr；不自动重试、**不消耗 `retry_count`**（parked），**永不自动提升 `failed`** | 人工剥掉 `timeout` 或在其上加 `retry` → `QUEUED`（fresh 重置） |
| **failed-cc** (`failed-cc`) | `blocked-cc` 的 `retry_count > blocked_retry_limit` 被提升（retry budget 耗尽是唯一成因）；或 `outcome=failed` 直达（罕见） | 永不自动重排（CC 侧），待人工 | 改提示词/hulat，人工 `retry` 重新武装 → `QUEUED`；或人工 `close` → `CLOSED` |
| **failed-dispatcher** (`failed-dispatcher`) | `blocked-dispatcher` 的 `retry_count > blocked_retry_limit` 被提升 | 永不自动重排（调度器侧），待人工 | 改 dispatcher，人工 `retry` 重新武装 → `QUEUED`；或人工 `close` → `CLOSED` |
| **CLOSED** (issue `closed`) | **人工关闭 issue**（本分支无 MR、无 `Closes #iid` 自动关闭） | `reconcile` 永久硬跳过，不再调度 | 终态 |

注意：`failed-cc` / `failed-dispatcher` 名为"失败态"但**有出边可被人工 `retry` 重新武装**，不是真正的终态；唯一终态是 `CLOSED`。任意非终态都可被人工 `close` → `CLOSED`。`done` 是 agent 的终态成功标签，但**它本身不关闭 issue**——关闭是人工动作。

---

## 2. issue label 模型（两条正交维度 + 一个 tick 级 gate）

### 2.1 工作标签维度（互斥，任意时刻恰好一个）

- 入口：`todo` / `new` / `retry`（外加触发 `require_labels` 作一次性入口）
- 进行：`doing`
- 终态成功：`done`（**永不被替换**；无 `pr`）
- 异常：`blocked-cc` / `blocked-dispatcher` / `timeout` / `failed-cc` / `failed-dispatcher`

互斥规则（`set_issue_label.sh`）：加任一工作标签都移除其它工作标签。唯一允许的瞬态并存对 = CC 侧在 `done` 之后失败的 `{done + blocked-cc}` 或 `{done + blocked-dispatcher}`。

**进 `doing` 清除集**（进 `doing` 时移除、只留 `doing`）：
`{ todo, new, retry, doing, done, blocked-cc, blocked-dispatcher, timeout, failed-cc, failed-dispatcher }` 外加匹配的触发 `require_labels`。
**该清除集不含 `model:{tier}`**（model 维度持久，进 `doing` 不清除，随后被重新 stamp 成该 tick 的 pin）。非工作标签 `precheck-failed`（见 §2.3）也在这一步被一并移除。

### 2.2 `model:{tier}` 维度（正交、持久、per-tick 钉死）

- 取值：`model:flash`（TIER_0）/ `model:pro`（TIER_1）/ `model:max`（TIER_2）。档数 = trigger 可配的有序 `model_tiers` 列表长度（3 档为示例）。
- 与工作标签**正交并存**；互斥只在本维度内部（恰好一个 `model:{tier}`）。
- **per-tick 钉死，无单调升不变式**：本分支由 per-tick **必填**触发字段 `pin_model_tier` 决定本轮档位，issue 被精确打成 `model:<pin>`。**没有 `resolve_model_tier` 失败升档阶梯，没有"只升不降"约束**——pin **可从高档下调**（靠 `set_issue_label` 的 `model:*` 互斥在同一次更新里清掉旧档）。缺 `pin_model_tier` 则整 tick abort（`pin_model_tier_required`）；值非法 abort（`invalid_pin_model_tier`）；值不在 effective 档集 → 该 IID 标 `blocked-dispatcher`。
- source of truth = GitLab 标签；`state.json` 的 `model_tier` 仅缓存，`reconcile` 让缓存向标签看齐。
- **档位如何真正生效**：本轮 `MODEL`（= `pin_model_tier`）在 PREPARE 阶段驱动一次"按档复制 settings"——当 trigger 配了 `model_settings_dir`（存放 `<tier>-settings.json` 的绝对目录）时，dispatcher 把 `${model_settings_dir}/${MODEL}-settings.json` 复制（并重命名）为 worktree 的 `.claude/settings.json` 并标 `skip-worktree`，acpx claude exec 随后读取它，从而真正切换底层模型。未配 `model_settings_dir` 时跳过复制（沿用 worktree 自带的 `.claude/settings.json`），此时 `model:{tier}` 仅作为 prompt 文本提示而不改变实际模型。
- **档位自动发现 + 智慧序（full / effective 拆分）**：配了 `model_settings_dir` 时，`model_tiers`（默认 `flash,pro,max`）退为"智慧序全集"，本部署 **effective** 档集 = 全集 ∩ 目录里实际有 `${tier}-settings.json` 的档（保智慧序，每 tick 由 `derive_effective_model_tiers` 重新发现）。例：目录只放 `pro-settings.json`+`max-settings.json` → effective 档集 `pro, max`；只放一个 → 单档。`pin_model_tier` 必须命中这个 effective 子集。`reconcile`（`model_tier` 整数索引）与 tier pinning（`MODEL` 选择）消费 **effective** 子集；`ensure_labels` / `set_issue_label` 仍用 **全集**（建全部 `model:*` 标签 / 互斥清除，保证迁移时旧档标签可清）。配了但目录无任何匹配文件 → 整 tick fail（`no_model_settings_files`）。
- **sweep 一个 issue 跨候选模型** = 对该 issue 每个候选模型各触发一轮 tick（每 tick pin 一个档）。

### 2.3 `precheck-failed`（tick 级非工作 gate）

当 trigger 配了 `precheck_relpath` 且环境 precheck 的 `required` 项失败（或 manifest 损坏），dispatcher 在本 tick batch 的 IID 上 best-effort 打 `precheck-failed` 并 abort 整 tick。它**不是**工作状态、**不**参与互斥：`set_issue_label.sh add precheck-failed` 与现有工作标签并存。**不消耗 `retry_count`、不改 model 档位**。issue 下次进 `doing` 时被清除（到了 `doing` 说明那 tick 的 precheck 已过，标记已陈旧）。只有 dispatcher 设/清，subagent 从不碰它。

---

## 3. 迁移与触发规则

### 3.1 outcome → label（`AUTO_RUNNING` 完成后 Phase 6 写回，据此分流）

subagent compact 回执用 side-agnostic 的 `status` 词表（`done` / `no_changes` / `blocked` / `failed` / `timeout`）；Phase 6 按 status + 侧别映射到内部终态与实时 label：

| outcome（来源） | reply.status | 侧 | 内部 final_status | 实时 label |
| --- | --- | --- | --- | --- |
| 解决，work 已 push | `done` | cc | `done` | `done`（终态成功） |
| acpx 非超时失败 / `NO_CHANGES` / push 被拒 / acpx 后步骤失败 | `blocked` | cc | `blocked_cc` | `blocked-cc` |
| prep / spawn launch / scope 或 stuck eviction 失败 | `blocked` | disp | `blocked_dispatcher` | `blocked-dispatcher` |
| acpx 超 wall-clock 上限 | `timeout` | cc | `timeout` | `timeout` |
| `failed` 直达（罕见，subagent 优先 `blocked`） | `failed` | cc | `failed_cc` | `failed-cc` |

侧别由谁产出回执决定：真实 subagent 回调恒为 CC 侧（`block_side: "cc"`）；dispatcher 合成的 blocked 回执（`phase6_synthesize_blocked`）恒为 dispatcher 侧（`block_side: "dispatcher"`）。`no_changes` 被归一化成 `blocked`（→ `blocked_cc`）。

### 3.2 retry 超限提升（自动，按侧）

- `blocked-cc` 且 `retry_count > blocked_retry_limit` → `failed-cc`
- `blocked-dispatcher` 且 `retry_count > blocked_retry_limit` → `failed-dispatcher`
- `timeout` **不参与**提升（不消耗 `retry_count`，parked）
- launch 侧合成的 blocked 回执（`dispatch_record_spawn.sh STATUS=launch_failed`）与 stuck-pending eviction 都 **不**增 `retry_count`，当 tick 不提升

### 3.3 model 档位钉死（PREPARE 阶段）

**没有 `resolve_model_tier`、没有 hard/soft 失败升档触发、没有单调只升不变式。** 每次 PREPARE 直接用 `pin_model_tier` 钉本轮档位、解析 `MODEL`，把 issue 精确打成 `model:<pin_model_tier>`（同一次更新里清掉其它 `model:*`，故 pin 可下调）。`model:{tier}` 维度从"进 doing 清除集"中**排除**，进 `doing` 后再被重新 stamp 成该 tick 的 pin。

一句话：**model 档位是这一 tick 的 `pin_model_tier` 说了算——无自动升档、也不自动保护更高的旧档。**

### 3.4 重跑模式：只有 fresh（`continue` 已禁用）

每个 attempt 都是 fresh 模式：基线 `origin/${dev_branch}`，从干净基线起跑，归档上轮产物（不恢复回 active worktree）。**没有 continue 模式、没有 `continue` / `contiune` 标签处理、没有 `needs_continue` 信号**。跨 attempt 的唯一信息延续是 prompt 里嵌入的上轮 summary（成功 `done` attempt 自动发的 GitLab note）与评审意见，以及从 `origin/${dev_branch}` 刷新的共享配置路径（`hulat/`、`.claude/`、`${data_basename}/`）。agent 永不自己打入口标签。

---

## 4. 推送模型（每 attempt 不可变远端分支）

- 每个 attempt 推送**恰好一个**远端分支：不可变的 per-attempt 分支 `LOCAL_ATTEMPT_BRANCH = issue/<iid>-auto-fix-att<NNN>-<tier>`（尾部 `-<tier>` 为本次锁定的模型等级），由 `commit_and_push.sh` 用**非 force** push 推送（分支名每 attempt 唯一，首推总是新分支），带 `ls-remote` 幂等跳过（同 attempt 重跑时若 ref 已在 origin 则跳过，不覆盖留档产物）。**永不覆盖**。
- 旧的可变"最新指针" `WORK_BRANCH = issue/<iid>-auto-fix` **不再被推送**；它退化为 `env_paths.sh` 派生 `LOCAL_ATTEMPT_BRANCH` 的**命名前缀**，无远端推送/校验意义。`post_push_verify.sh` 的 push 后健康检查 fetch 的也是 `${LOCAL_ATTEMPT_BRANCH}`。
- partial work（`blocked-cc` / `timeout` 路径）同样尽力 commit + push 到不可变 per-attempt 分支；不发 Wiki 证据、不开 MR、不加 `pr`。
- compact 回执的 `work_branch` 字段**恒为空字符串 `""`**（旧的 `WORK_BRANCH` 不再推送，无意义）；真实推送的远端分支由 `local_branch` 字段承载。
- `stage_and_guard.sh` 用 `git add -f` 强制把当前 issue 的 `${OUTPUT_DIR}` 与**整个** `${LOG_DIR}`（eval 全量留档：`acpx_raw.log` / `git_status.txt` / `git_diff.patch` / `metrics.json` / `prompt.txt` / `claude_result.txt` 等全部 artifact）纳入，落到 `${LOCAL_ATTEMPT_BRANCH}`，让每 attempt 的完整证据都进入不可变 per-attempt 分支供 `issue × model` 横向对比。无基于路径的拒绝。

---

## 5. 不变量（贯穿全程）

**GitLab 实时标签 = 状态唯一真相；磁盘 `campaign_state.json` / `state.json`（含 `model_tier`）/ `attempt_state.json` 只是 dispatcher 进度缓存。** 冲突时永远以 GitLab 为准；每 tick 强制 `reconcile.sh` 并写 `reconcile-<ts>.json` 证据文件兜底——**没有证据文件 = 该 tick 判失败**。disk 缓存永远被纠正向 GitLab，不反向。

---

## 6. model-eval 特化（benchmark-test 的目的与产物）

`benchmark-test` 把 agent 特化为专门评测 model 的工具，从**效率 + 准确率**两维对比候选模型（cost 不采，交专门部门）。除了上面已贯穿全文的行为（`pin_model_tier` 钉档、`done` 终态无 `pr`、强制 fresh、每 attempt 不可变分支），它还有：

- **全量留档。** `stage_and_guard` force-add 当前 issue 的 `${OUTPUT_DIR}` 与**整个** `${LOG_DIR}`（全部 artifact，非仅 reviewer 文件）；每 attempt 的不可变分支 `issue/<iid>-auto-fix-att<NNN>-<tier>`（与运行目录 `log/attempt-<NNN>-<tier>/` 同样带模型等级后缀）永久保留该次运行的完整产物，供 `issue × model` 横向对比。
- **指标采集与汇总。** subagent Step 1.5 调 `collect_metrics.sh` 写 `metrics.json`（wall_clock + robot 通过率，best-effort），随 compact 回执回传；Phase 6 append 到 `${RESULT_BASENAME}/_dispatcher/benchmark/metrics.jsonl`（model 由 issue state 权威补齐）；`aggregate_benchmark.sh` 出 `issue × model` 矩阵。
- **保留不变的可靠性核心：** `reconcile` + 证据文件、`flock`、`precheck`、`timeout` / 孤儿防护、UI 账号池、并发 per-issue worktree、anonymous spawn + async callback、per-side 失败标签拆分（`blocked-cc` / `blocked-dispatcher` / `failed-cc` / `failed-dispatcher`）。
