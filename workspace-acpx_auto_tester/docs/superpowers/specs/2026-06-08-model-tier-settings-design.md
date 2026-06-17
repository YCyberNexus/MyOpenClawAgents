# Model Tier 真正生效：按档复制 settings.json — 设计文档

> 移植批注（temporal 分支）：本文行号 / 分支 / commit 指 statemachine 原始实现；temporal 落位见本分支对应 commit。

- 日期：2026-06-08
- 分支：`statemachine`
- 状态：已实现并提交（commit 09d6662）
- **后续变更（2026-06-09）**：本文档当时把 `model_settings_dir` 设计为 carry-forward 字段（trigger 省略则沿用持久值）。后改为 **per-tick，不再 carry-forward**——trigger 不传即视为该 tick 未配置、退回原先逻辑（不复制、effective=full、tier 仅文本提示）；持久态仍快照本 tick 值，仅供同批 callback 的窄 reconcile 同源，不再用于 carry-forward 恢复。下文 §4/§8 中关于 `model_settings_dir` carry-forward 的描述以此变更为准（trigger 契约见 `references/trigger_command.md`）。

## 1. 背景与现状

`statemachine` 分支已落地 v2 的 `model:<tier>` 标签模型。dispatcher 能从 GitLab live 标签解析出每个 issue 的 model 等级，并据此决定升档，但**该等级目前只是"嘴上说说"**：

- `reconcile.sh` 从标签计算 `model_tier` 整数（0-based）。
- `dispatch_prepare_tick.sh` 的 `resolve_model_tier`（约行 1104-1197）决策升档，算出：
  - `MODEL`（字符串，如 `flash`/`pro`/`max`，来自 `model_tiers[NEW_TIER]`，行 1197）。
  - `MODEL_TIER_LABEL`（如 `model:pro`，行 1196）。
  - `NEW_TIER` 已在行 1190-1195 被 clamp 进 `[0, MODEL_MAX_TIER]`，保证 `MODEL` 永不为 `null`。
- `MODEL` 经 `MODEL="${MODEL}"` 传入 `build_prompt.sh`（行 1348），仅作为一行文字注入 `prompt.txt`（"Model tier (this attempt): pro"）。
- **没有任何环节真正改变 acpx 调用的底层模型。**

仓库里已存在一个雏形机制 `claude_settings_path`（`dispatch_prepare_tick.sh` 行 1251-1273）：trigger 给一个绝对文件路径，dispatcher 在 `prepare_attempt.sh` 之后、`build_prompt.sh` 之前，把该文件 `cp` 到 `${WORKTREE_DIR}/.claude/settings.json`，再 `git update-index --skip-worktree .claude/settings.json`（防止复制物被 stage 进 MR）。本设计是它的"按 tier 分档"升级版。

acpx 唤起点 `run_acpx_attempt.sh` 会 `cd "${WORKTREE_DIR}"` 后执行 `acpx --auth-policy skip claude exec -f "${LOG_DIR}/prompt.txt"`，claude code 启动时读取 cwd 下的 `.claude/settings.json`。该 `.claude/` 目录由 `prepare_attempt.sh` 的 `refresh_shared_config_from_dev`（行 387-417）从 `origin/${DEV_BRANCH}` 刷新而来。

## 2. 目标与非目标

### 目标
- 让 model tier 真正生效：根据已解析的 `MODEL`，把对应的分档 settings.json 复制为 acpx 启动目录下的 `.claude/settings.json`，acpx 随后读取它，从而切换底层模型。
- 分档文件目录可配置、carry-forward 持久化。
- 严守 no-fallback：配了目录但缺对应档文件时，该 IID 失败为 `blocked-dispatcher`。

### 非目标
- 不改动 model tier 的解析/升档逻辑（已现成）。
- 不改 acpx 调用契约（`run_acpx_attempt.sh` 不变）。
- 不改 prompt 渲染（`MODEL` 文本行已存在；本次不扩 scope 去改 `build_prompt.sh`/`executor_prompt.md`）。

## 3. 设计概览（数据流）

```
GitLab model:<tier> 标签
   └─(已有) reconcile → model_tier 整数 → resolve_model_tier → MODEL="pro"（行 1197，已 clamp 非 null）
                                                                  │
   trigger: model_settings_dir=/data/models/ifp-models           │
   └─ 格式校验(绝对路径) → carry-forward 持久化 campaign_state.json │
                                                                  ▼
   prepare_attempt.sh 建好/复用 worktree + 从 origin/dev 刷新 .claude/
                                                                  ▼
   【新】若 MODEL_SETTINGS_DIR 非空：
         msf="${MODEL_SETTINGS_DIR}/${MODEL}-settings.json"
         若 msf 不可读 → prep_blocked（blocked-dispatcher，跳过该 IID）
         否则 cp "${msf}" "${WORKTREE_DIR}/.claude/settings.json"   ← 复制即重命名为 settings.json
              git -C "${WORKTREE_DIR}" update-index --skip-worktree .claude/settings.json
                                                                  ▼
   run_acpx_attempt.sh: cd worktree → acpx claude exec（读取 .claude/settings.json）
```

## 4. 配置：`model_settings_dir` trigger 字段

- 类型：可选，**绝对目录路径**。例：`/data/models/ifp-models`。该目录在被测项目 repo 之外（不强制在 `${REPO_PATH}` 内），故用绝对路径而非 `ui_accounts_relpath` 式相对路径。
- ~~carry-forward 语义（照搬 `ui_accounts_relpath`）~~ → **已于 2026-06-09 改为 per-tick（见头部批注）**：trigger 提供则用于本 tick 并快照进 `campaign_state.json`（仅供同批 callback 同源）；trigger 省略即该 tick 未配置、退回原先逻辑，**不**从持久值恢复。下列原设计三条已作废，仅留作历史：
  - ~~trigger 提供 → 写入 `campaign_state.json` 并用于本 tick。~~
  - ~~trigger 省略 → 读取持久值（仅 §285-290 旁的 carry-forward 段；**不**进 §240-264 discover 段，理由见本节末条）。~~
  - ~~fresh 部署且无持久值 → 未配置（`null`），跳过整个分档复制流程。~~
- 格式校验（照搬 `claude_settings_path` 的绝对路径校验，行 1254-1262），违规一律 `emit_chat_failure "invalid_model_settings_dir"`（tick 级配置错误，整 tick fail）：
  - 必须以 `/` 开头；不得恰为 `/`。
  - 拒绝含 `.` / `..` 路径段（`/.`、`/./`、`/..`、`/../`）、`\n`/`\r`/`\t`/空格、`[A-Za-z0-9_./-]` 之外的字符。
- 注意：因是绝对路径，**不参与 `env_paths.sh` 的路径派生**，故 carry-forward 赋值后无需 re-source `env_paths.sh`（与 `result_basename`/`data_basename` 不同，与 `ui_accounts_relpath` 行 285-290 那段一致——纯赋值）。也因此**不需要进入行 240-264 的 discover 段**：那段是为在 basenames 未知时定位 `campaign_state.json` 文件本身，而 `model_settings_dir` 不影响该文件位置；等到行 285 的 carry-forward 段时 `CAMPAIGN_STATE_FILE` 已被正确定位，单点读取即可。

## 5. 文件命名约定与复制语义

- 目录内文件命名规则：`${tier}-settings.json`，其中 `tier` 取自 `model_tiers` 列表的**实际值**。默认 `model_tiers=["flash","pro","max"]` → 文件为 `flash-settings.json` / `pro-settings.json` / `max-settings.json`。若 trigger 把 `model_tiers` 改成自定义名字（如 `small,big`），则文件须相应命名 `small-settings.json` / `big-settings.json`。
- **复制即重命名**：`cp` 目标是具体文件路径 `.claude/settings.json` 而非目录，故源 `pro-settings.json` 落地后就是 claude code 默认读取的 `settings.json`。与现有 `claude_settings_path` 的 `cp "${csp}" "${WORKTREE_DIR_X}/.claude/settings.json"` 同样语义。
- 复制后 `git -C "${WORKTREE_DIR}" update-index --skip-worktree .claude/settings.json`，使覆盖物不会被 `stage_and_guard.sh` stage 进 issue MR。skip-worktree 是 per-worktree 索引位（linked worktrees 索引独立），并发 attempt 互不影响。
- 时机：必须在 `prepare_attempt.sh`（行 1217-1219）之后——`refresh_shared_config_from_dev` 会从 `origin/${DEV_BRANCH}` checkout `.claude/`（含 settings.json）并先清除 skip-worktree bit（`prepare_attempt.sh` 行 400-408）。复制是该刷新之后的最后覆盖，沿用现有 `claude_settings_path` 的插入位置（紧随行 1249 之后）。

## 6. 失败语义

| 情形 | 行为 |
|------|------|
| 未配 `model_settings_dir` | 跳过整个分档复制；acpx 用 worktree 自带 `.claude/settings.json`（与 `ui_accounts_relpath` 未配即跳过一致） |
| 字段格式非法（非绝对/`..`/空格/越界字符） | `emit_chat_failure "invalid_model_settings_dir"`（整 tick fail） |
| 配了但 `${MODEL}-settings.json` 不存在/不可读 | 该 IID `prep_blocked "model settings file not found or not readable: ${msf}"` → `blocked-dispatcher`，`continue` 跳过该 IID（per-IID 粒度，严守 no-fallback） |
| `cp` 失败 | 该 IID `prep_blocked "model settings copy failed"` → `blocked-dispatcher` |

目录不存在是"文件不可读"的子情形，自然落入 `prep_blocked`。per-IID 粒度比 tick 级更合理：不同 IID 的 `MODEL` 不同，缺失的档文件也不同。

## 7. `claude_settings_path` 的移除与兼容性

用户决策：分档机制**完全取代** `claude_settings_path`。

- 删除 trigger 字段 `claude_settings_path`（`trigger_command.md` 行 66）。
- 删除/替换 `dispatch_prepare_tick.sh` 行 1251-1273 整段为分档复制逻辑。
- 更新 `prepare_attempt.sh` 行 400-408 注释措辞（清 skip-worktree bit 的逻辑本身保留——分档机制同样 mark skip-worktree，下次 attempt 的刷新需先清除再 overlay）。
- 更新 `dispatcher_wrappers.md` 行 155 步骤措辞。
- 兼容性影响：若已有部署在 trigger 里传 `claude_settings_path`，该字段将被忽略（不再触发复制）。需在文档中标注此破坏性变更。若需保留"无分档单一覆盖"能力，做法是把三档文件填同一份内容，或配置 `model_settings_dir` 后让各档指向相同 settings。

## 8. 文件级改动清单（精确）

### `scripts/env_paths.sh`
- 在 `: "${UI_ACCOUNTS_RELPATH:=}"` 之后新增 `: "${MODEL_SETTINGS_DIR:=}"`，并把 `MODEL_SETTINGS_DIR` 加入 `export` 列表。**仅为 `set -u` 安全**——下游 state jq 的 `--arg model_settings_dir "${MODEL_SETTINGS_DIR}"` 是裸读（无 `:-`），未初始化会触发 unbound。不涉及任何路径派生。（这是相对最初设计的一处必要补充，见 §9。）

### `scripts/dispatch_prepare_tick.sh`
1. **行 215-229 旁**（`ui_accounts_relpath` 校验之后）：新增 `model_settings_dir` 格式校验块 + `export MODEL_SETTINGS_DIR`。绝对路径校验照行 1254-1262（拒绝 `/`、`.`/`..` 路径段即 `/.`/`/./`/`/..`/`/../`、空格、`[A-Za-z0-9_./-]` 之外的字符），违规用 `emit_chat_failure "invalid_model_settings_dir"`。
2. **行 285-290 旁**：新增 `model_settings_dir` 的 carry-forward 读取块（trigger 省略且 `campaign_state.json` 有持久值时 `export MODEL_SETTINGS_DIR`）。纯赋值，不 re-source `env_paths.sh`，不进 240-264 discover 段（见 §4）。
3. **行 466-528 的 state jq**：加 `--arg model_settings_dir "${MODEL_SETTINGS_DIR}"` 与对象内 `model_settings_dir: $model_settings_dir,`。
4. **行 1251-1273 整段**：`claude_settings_path` 复制 → 替换为：
   ```bash
   # model settings (tier 分档): copy ${MODEL}-settings.json → .claude/settings.json
   if [ -n "${MODEL_SETTINGS_DIR:-}" ]; then
     msf="${MODEL_SETTINGS_DIR}/${MODEL}-settings.json"
     if [ ! -r "${msf}" ]; then
       prep_blocked "model settings file not found or not readable: ${msf}"; continue
     fi
     WORKTREE_DIR_X="$(env "${iid_env[@]}" bash -c 'source "$0" >/dev/null; printf %s "$WORKTREE_DIR"' "${SCRIPT_DIR}/env_paths.sh")"
     if ! cp "${msf}" "${WORKTREE_DIR_X}/.claude/settings.json"; then
       prep_blocked "model settings copy failed"; continue
     fi
     git -C "${WORKTREE_DIR_X}" update-index --skip-worktree .claude/settings.json || true
   fi
   ```
   `MODEL` 在此点（行 1251）已由 `resolve_model_tier`（行 1197）算好且非 null。

### `scripts/prepare_attempt.sh`
- 行 400-408 注释：`A prior claude_settings_path override` → `A prior model-settings override`（功能不变）。

### `references/trigger_command.md`
- 删除 `claude_settings_path` 行。
- 新增 `model_settings_dir` 行：可选绝对目录路径；carry-forward；文件命名 `${tier}-settings.json`；未配跳过、格式非法 → `invalid_model_settings_dir`、缺档文件 → 该 IID `blocked`；说明复制即重命名为 `.claude/settings.json` 且 skip-worktree。

### `references/state_schema.md`
- `campaign_state.json` schema 加 `model_settings_dir` 字段（fresh-init 默认 `null`/未配，carry-forward）。

### `references/dispatcher_wrappers.md`
- 行 155 步骤 20.3 措辞：`claude_settings_path copy` → `model-settings (${tier}-settings.json) copy`。

### `statemachine.v2.md`
- 在 model tier 章节补一句：tier 现经复制 `${tier}-settings.json` → `.claude/settings.json` 真正生效（先前仅文本注入）。

### `SKILL.md`
- line 3 `[SKILL_VERSION=...]` bump 到 `2026-06-08.N`（同一 commit 内）。

### `CLAUDE.md`（项目根，不触发 SKILL_VERSION bump）
- 在描述 per-IID prep / acpx 调用的段落同步"model settings 分档复制"这一架构事实。

## 9. 不改动项
- `run_acpx_attempt.sh`：dispatcher 侧复制，subagent 保持无状态。
- `build_prompt.sh` / `references/executor_prompt.md`：`MODEL` 文本行已存在，保持聚焦。
- 注：`env_paths.sh` 最初列为不改动项（绝对路径无需派生），但实现时为 `set -u` 安全必须新增 `MODEL_SETTINGS_DIR` 空初始化，已上移至 §8。

## 10. 校验方式
- 每个改过的 `scripts/*.sh` 跑 `bash -n scripts/<name>.sh`（本仓库唯一的快速 sanity check）。
- 代码改动走 `code-reviewer` 子代理审查循环（CLAUDE.md §Code review workflow，最多 3 轮）。
- 清 Stop hook 阻塞：循环完成后写当前 diff 指纹到 `.claude/.review-done-sha`。

## 11. SKILL_VERSION
- 本次涉及 `workspace-acpx_auto_tester/` 下 `scripts/`、`references/`、`statemachine.v2.md` 与 `SKILL.md` 的改动，必须在同一 commit bump `SKILL.md` line 3 的 `[SKILL_VERSION=...]` 至 `2026-06-08.N`（按当日序号递增）。
