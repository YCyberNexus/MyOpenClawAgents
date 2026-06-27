# Spec：状态机 v2 标签语义落地

> 日期：2026-06-15
> 分支：`feat/statemachine-v2-labels`
> 目标：把 `statemachine.v2.md` 的设计语义落到真实实现（SKILL.md 编排器 + bash 脚本 + executor_prompt.md，无 Temporal）。

## 1. 背景与现状

`statemachine.v2.md` 与 `主状态机汇报讲稿.md` 描述了 v2 标签模型，但**只是设计稿，从未落地**。证据：

- `ensure_labels.sh:32` `REQUIRED_LABELS=(todo retry new doing pr done blocked failed timeout continue)` —— 单一 `blocked`/`failed`，无 `model:*`/`quality:low`。
- `set_issue_label.sh:35` `WORKFLOW_LABELS` 同样只有单一 `blocked`/`failed`。
- SKILL.md / executor_prompt.md 中 `blocked-cc` 出现 0 次。
- `git log -S"blocked-cc" -- scripts/` 为空。
- `label_lifecycle.md` 规则 1 明确写 "`pr` is additive, not a replacement for `done`" —— 当前 `pr` 叠加在 `done` 上，v2 说的"pr 替换 done"也未落地。
- `run_acpx_attempt.sh:141` acpx 调用固定为 `acpx --auth-policy skip claude exec -f <prompt>`，**无 `--model` flag**；唯一切模型入口是 trigger 字段 `claude_settings_path`（复制一个 `.claude/settings.json` 进 worktree）。

设计稿引用的 `temporal/workflows/campaign.py` 在本仓不存在；真实"分类逻辑"在 SKILL.md Phase 6 + `_dispatch_lib.sh` + `dispatch_followup.sh` + `dispatch_prepare_tick.sh`。

## 2. 落地范围（全套 v2）

五块：

- **A** `blocked` → `blocked-cc` / `blocked-dispatcher`（按归因拆）。
- **B** `failed` → `failed-cc` / `failed-dispatcher`（镜像 A）。
- **C** `pr` 替换 `done`（不再叠加）。
- **D** `model:{tier}` 正交持久标签 + 文件式自动升档。
- **E** `quality:low` 一次性软信号（喂给 D 的升档触发）。

不变量不变：**GitLab 实时标签 = 唯一真相；磁盘 state 只是缓存；每 tick 强制 `reconcile.sh` + 写证据文件，无证据 = tick 失败。**

## 3. 决定锁定

- **命名**：连字符 `blocked-cc` / `blocked-dispatcher` / `failed-cc` / `failed-dispatcher`（与设计稿、讲稿、drawio 一致）。
- **旧标签迁移**：**跳过**（项目无遗留 issue）。`ensure_labels.sh` 从此不创建单一 `blocked`/`failed`；旧标签定义由人工在 GitLab UI 删。`reconcile.sh` 仍**兼容识别**旧 `blocked`/`failed`（万一有残留也不漏）。
- **model id**：**代码零硬编码**，全部走 trigger `model_tiers`（文件式，见 §6）。`model_tiers` 缺省 = 关掉 D，其它四块照常。

## 4. 标签全集

**工作维度（互斥，恰好一个，含瞬态对例外）**

```
todo  new  retry  continue  contiune(旧拼写别名)  doing  done  pr
blocked-cc  blocked-dispatcher  timeout  failed-cc  failed-dispatcher
```

- 删除单一 `blocked` / `failed`（agent 不再打；reconcile 兼容识别残留）。
- 瞬态并存对：`{done + blocked-cc}` / `{done + blocked-dispatcher}`（建 MR 前失败）。
- `{done + pr}` **不再存在**（C：pr 替换 done）。`done` 变纯瞬态（建 MR 前的过渡）。

**model 维度（正交、持久、单调升，不参与"进 doing 清除"）**

```
model:flash (TIER_0 默认)  →  model:pro (TIER_1)  →  model:max (TIER_2 封顶)
```

档位 suffix 与文件由 trigger `model_tiers` 配置；默认 suffix `flash/pro/max`（顺序即档位，首=最低默认，尾=封顶）。

**软信号（独立，不与任何标签互斥）**

```
quality:low
```

人工在评审态加；resolve_model_tier 在本轮评估后移除（升档生效或封顶都消费掉，不长期残留）。

## 5. 侧归因映射（拆分核心）

dispatcher 已知每个失败的来源，归因零歧义。判定规则极简：**回复来自子代理解析（`status=blocked`）→ `cc`；任何 dispatcher 合成/强制降级 → `dispatcher`**。

| 来源 | block_side | 标签 |
|------|-----------|------|
| 子代理 compact JSON `status=blocked`（executor 自己的 FAIL 路径：acpx 非超时失败 / NO_CHANGES / push 被拒 / post-push / wiki / 标签 / MR / add pr 失败） | `cc` | `blocked-cc` |
| dispatcher 合成 blocked：prep 失败 / launch_failed / scope evict / stuck 非超时驱逐 / 回复无法解析被强制降级 / label-sync 失败降级 | `dispatcher` | `blocked-dispatcher` |
| acpx 超时（子代理 TIMEOUT flow）或 stuck 超 acpx 预算驱逐或空/不可解析回复且已超预算 | （CC 天生） | `timeout`（不拆） |
| `blocked-cc` 且 `retry_count > blocked_retry_limit` | `cc` | 提升 `failed-cc` |
| `blocked-dispatcher` 且 `retry_count > blocked_retry_limit` | `dispatcher` | 提升 `failed-dispatcher` |
| 子代理直达 `status=failed`（罕见） | `cc` | `failed-cc` |

实现手段：Phase 6 处理链多带一个 `block_side`（`cc`/`dispatcher`）参数贯穿 `phase6_sync_labels` / `phase6_write_state_files` / 提升判定。

- `timeout` 永远 CC 侧，**永不消耗 `retry_count`、永不提升 failed**（沿用现状）。
- `iid` 分桶不细拆：`blocked_iids` / `failed_iids` 仍是单桶（调度/重试逻辑不变）；侧只决定**打哪个 label** 与**提升到哪个 failed-***。侧信息持久在 `state.json.block_side`。
- 子代理的 compact JSON `status` 枚举**保持不变**（`done|no_changes|blocked|failed|timeout`）；侧由 dispatcher 据回复来源判定，子代理无需感知"侧"。

## 6. model 文件式升档机制（D）

复用 `claude_settings_path` 的"复制 settings 文件进 worktree"机制（`dispatch_prepare_tick.sh:1196-1216`）。dispatcher **完全不碰 model id**——只认"档位 → 文件路径"，把那一档的文件 `cp` 进 `${WORKTREE_DIR}/.claude/settings.json` + `git update-index --skip-worktree`。model id 在每个文件里，由操作者维护。

**trigger 字段 `model_tiers`**（可选，carry-forward 持久；有序数组，顺序即档位高低）：

```json
"model_tiers": [
  {"tier": "flash", "settings": "/abs/path/settings-flash.json"},
  {"tier": "pro",   "settings": "/abs/path/settings-pro.json"},
  {"tier": "max",   "settings": "/abs/path/settings-max.json"}
]
```

- 每条 `settings` 路径校验复用 `claude_settings_path` 那套：绝对路径、字符限 `[A-Za-z0-9_./-]`、无 `..`、复制时必须存在可读，否则 `prep_blocked`。
- `model_tiers` 缺省/空 = 关 D：不建 `model:*` 标签、`resolve_model_tier` 跳过、settings 注入回退到 `claude_settings_path` → 提交进仓的 settings。

**worktree `.claude/settings.json` 优先级**：

1. `model_tiers` 配了 → 用解析出那一档的文件。
2. 否则 `claude_settings_path` 配了 → 用它。
3. 都没有 → 提交进仓的 settings 原样。

**新 trigger 字段 `continue_upgrade_threshold`**（可选，默认 2，carry-forward）：continue 累计次数达到它即软触发升档。

### resolve_model_tier 算法（Phase 4 per-IID prep，进 doing 前；仅当 `model_tiers` 配置时运行）

1. 读 live `model:{tier}` 标签 → 当前档（无 → TIER_0，即 `model_tiers[0].tier`）。
2. 求 `UPGRADE?`：
   ```
   硬触发：上一轮 outcome ∈ {blocked-cc, timeout, failed-cc}
           （从 state.json.status + block_side 读；timeout 恒 CC 侧）
   软触发（任一）：
       quality:low 在场
       continue_count ≥ continue_upgrade_threshold
       自动评分 < 阈值  ← 占位 no-op（设计稿明确未实现）
   排除：上一轮 outcome ∈ {blocked-dispatcher, failed-dispatcher} → 不升
   ```
3. 判定：命中且未封顶 → 升一档（`tier_index + 1`）；命中已封顶 → 保持 `max`；未命中 → 保持当前档。
4. 副作用：
   - 写 `model:{新档}` 标签（model 组互斥：remove 其它 `model:*`，add 新档）。
   - 若 `quality:low` 参与了本轮评估 → `remove quality:low`（升档或封顶都消费）。
   - 把新档的 `settings` 文件 `cp` 进 `${WORKTREE_DIR}/.claude/settings.json` + `skip-worktree`。
   - 缓存 `model_tier` 到 `state.json`。
5. 新 issue（无 state.json）：视为 TIER_0，首次 PREPARE 显式打 `model:{TIER_0}`。

## 7. set_issue_label.sh 三组互斥（最易错处）

```
work 组：todo new retry continue contiune doing done pr
         blocked-cc blocked-dispatcher timeout failed-cc failed-dispatcher
model 组：model:flash model:pro model:max   （动态 = model_tiers 各 tier 加前缀 model:）
soft   ：quality:low
```

- **加 work 标签** → 仅移除 work 组其它标签。keep 例外：
  - `pr → {pr}`（加 pr 即移除 done —— C）。
  - `blocked-cc → {done, blocked-cc}`。
  - `blocked-dispatcher → {done, blocked-dispatcher}`。
  - 其余 work 标签 → `{自身}`。
  - **不动 model / quality:low。**
- **加 model 标签** → 仅移除 model 组其它标签；不动 work / quality:low。
- **加 `quality:low`** → 不移除任何东西；只有 `resolve_model_tier` 主动 `remove quality:low`。
- **进 doing 清除集**：移除 work 组其它标签，**保留 model:* 与 quality:low**（model 持久；quality:low 由 resolve_model_tier 决定何时消费）。

实现：`set_issue_label.sh` 把扁平 `WORKFLOW_LABELS` 重构成"按组判定 + 组内互斥"。**分组按前缀识别，不依赖 `model_tiers`**（脚本很多调用处 env 里没有 `model_tiers`）：

- 标签以 `model:` 开头 → model 组。
- 标签以 `quality:` 开头 → soft 组（目前仅 `quality:low`）。
- 标签在 work 列表内 → work 组。
- 其余 → 非工作标签，原样保留不动（priority/severity 等人工标签）。

这样 `set_issue_label.sh` 仅凭标签名本身即可判定组别与组内互斥，无需知道具体有哪些档位。

## 8. 逐文件改动清单

### A+B 拆分

| 文件 | 改动 |
|------|------|
| `scripts/ensure_labels.sh` | `REQUIRED_LABELS` 增 `blocked-cc blocked-dispatcher failed-cc failed-dispatcher`，删 `blocked failed`；按 `model_tiers` 建 `model:<tier>`；建 `quality:low`（仅当 D 启用）。 |
| `scripts/set_issue_label.sh` | 三组互斥重构（§7）。 |
| `scripts/_dispatch_lib.sh` | `phase6_sync_labels` 增 `block_side` 入参，blocked/failed 分支按侧选标签、remove 所有变体；`phase6_write_state_files` 持久 `block_side`；提升判定（blocked→failed）按侧映射到 `failed-cc`/`failed-dispatcher`。 |
| `scripts/dispatch_followup.sh` | 合成 blocked → `block_side=dispatcher`；解析到 `status=blocked` → `block_side=cc`；超时合成不变（timeout）。 |
| `scripts/dispatch_prepare_tick.sh` | `prep_blocked` / scope-evict / launch_failed 路径 → `block_side=dispatcher`。 |
| `scripts/reconcile.sh` | `has_blocked` = `blocked-cc ∨ blocked-dispatcher ∨ blocked(旧,兼容)`；`has_failed` 同理；`user_reopened` 排除集补全新标签；新增读 `model:{tier}` → 校正缓存。 |
| `references/executor_prompt.md` | 所有 `set_issue_label.sh add blocked` → `add blocked-cc`；`labels_added` 数组同步为 `["blocked-cc"]`；status 枚举保持 `blocked`。 |

### C pr 替换 done

| 文件 | 改动 |
|------|------|
| `scripts/set_issue_label.sh` | `pr` keep 集 `(done pr)` → `(pr)`。 |
| `scripts/reconcile.sh` | 完成判定 `has_done_pr`（`done ∧ pr`）→ `has_pr`（`index("pr")`）。 |
| `scripts/_dispatch_lib.sh` | `phase6_sync_labels` done 分支：`add pr` + `remove done`（+ remove blocked-*/failed-*/timeout）。 |
| `references/executor_prompt.md` | step 8 `add pr` 后 done 自动移除；`labels_removed` 含 `done`。 |
| `references/label_lifecycle.md` | 规则 1/3 改写为"pr 替换 done"语义；转换表更新。 |

### D model 升档 + E quality:low

| 文件 | 改动 |
|------|------|
| `references/trigger_command.md` | 新增 `model_tiers` / `continue_upgrade_threshold` 字段定义 + carry-forward 说明。 |
| `scripts/ensure_labels.sh` | 见上（建 model:* + quality:low）。 |
| `scripts/dispatch_prepare_tick.sh` | 新增 `resolve_model_tier`（§6 算法）；settings 注入优先级（§6）；递增 `continue_count`（mode_actual==continue 时）。 |
| `scripts/set_issue_label.sh` | model 组 + quality:low 分组（§7）。 |
| `scripts/reconcile.sh` | 读 model:{tier} 校正缓存。 |
| `references/state_schema.md` | `state.json` 增 `model_tier` / `block_side` / `continue_count`；`campaign_state.json` 增 `model_tiers` / `continue_upgrade_threshold` 持久；compact reply 字段说明（侧由 dispatcher 推导，reply 不新增字段）。 |

### 配套

| 文件 | 改动 |
|------|------|
| `SKILL.md` | §Dispatcher Algorithm / §Source-of-Truth / §Concurrency 中所有 blocked/failed/done+pr 语义同步；**bump `SKILL_VERSION` 到 `2026-06-15.N`**（同一次提交）。 |
| `SOUL.md` / `AGENTS.md` | 标签模型、侧归因、pr 替换 done 同步。 |
| `references/continue_mode.md` | 凡提到单一 blocked/failed/done+pr 处同步。 |
| `references/glab_commands.md` | 若新增 glab 调用（如 reconcile 读 model label）则补；否则不动。 |
| `statemachine.v2.md` | §4「未落地」→「已落地」，落地点指向真实文件（本仓非 workspace，不触发版本 bump）。 |
| `CLAUDE.md` | 本仓根文件，描述行为处同步（非 workspace，不触发 bump；orchestrator 不读它）。 |

## 9. 状态 schema 变更

`issue-<iid>/state.json` 新增：

- `model_tier`：string，当前档位 suffix（如 `flash`），缓存；reconcile 向 GitLab `model:{tier}` 看齐。
- `block_side`：string|null，`cc`|`dispatcher`，上一轮失败侧（供 resolve_model_tier 硬触发判定 + 提升映射）。
- `continue_count`：int，continue 模式累计运行次数（软触发用）。

`campaign_state.json` 新增（carry-forward）：

- `model_tiers`：array|null（trigger 透传）。
- `continue_upgrade_threshold`：int，默认 2。

compact subagent reply：**不新增字段**（侧由 dispatcher 据来源推导）。

## 10. 实现阶段（便于审查，每阶段独立 review）

1. **标签与互斥底座**：`ensure_labels.sh` + `set_issue_label.sh` 三组重构。
2. **侧归因贯通**：`reconcile.sh` / `_dispatch_lib.sh` / `dispatch_followup.sh` / `dispatch_prepare_tick.sh` / `executor_prompt.md` 全链路带 `block_side`。
3. **pr 替换 done**：完成判定 + `phase6_sync_labels` + executor + `label_lifecycle.md`。
4. **model 升档 + quality:low**：trigger 字段 + `resolve_model_tier` + settings 注入优先级 + 状态缓存。
5. **文档 + 版本 bump**：SKILL.md / SOUL.md / AGENTS.md / references / statemachine.v2.md / CLAUDE.md。

每个非平凡脚本改动后 `/opt/homebrew/bin/bash -n <script>` 语法检查（本机 /bin/bash 是 3.2.57 会误判，统一用 homebrew bash）。所有 `workspace-req_executor/` 改动走 **code-review 子代理循环**（最多 3 轮），并在收尾时把 diff 指纹写入 `.claude/.review-done-sha` 解除 Stop hook。

## 11. 非目标 / 占位

- **迁移脚本**：不做（项目无遗留 issue）。
- **自动评分软触发**：占位 no-op（设计稿明确未实现）；保留 hook 点。
- **acpx `--model` flag**：不依赖（acpx 不支持）；model 选择纯靠 settings 文件。
- **`blocked_iids`/`failed_iids` 细分桶**：不做（侧信息存 `state.json.block_side` 足矣）。

## 12. 风险

- **C（pr 替换 done）改完成判定语义**：`reconcile.sh` 与 `_dispatch_lib.sh` 中所有 `done ∧ pr` 判定必须全部改对，漏一处会导致已完成 issue 被误判重排或漏判。需 grep 全量 `has_done_pr` / `done.*pr` 用法逐一核对。
- **set_issue_label 三组重构**：互斥逻辑是全链路标签正确性的底座，回归面最大；需覆盖"加各类标签后剩余标签集"的逐场景核对。
- **resolve_model_tier 的"上一轮 outcome"来源**：人工加 `retry`/`continue` 时会通过 set_issue_label 移除旧的 `blocked-cc` 等 work 标签，所以升档判定**不能读 live 标签**，必须读 `state.json.status + block_side`。这是 D 块正确性的关键前提。
