# Model 档位自动发现 + 智慧序 — 设计文档

> 移植批注（temporal 分支）：本文行号 / 分支 / commit 指 statemachine 原始实现；temporal 落位见本分支对应 commit。

- 日期：2026-06-09
- 分支：`statemachine`
- 承接：[2026-06-08-model-tier-settings-design.md](2026-06-08-model-tier-settings-design.md)（model_settings_dir 分档复制已落地，commit 09d6662）
- 状态：已通过设计澄清（方案 Y），待用户 review

## 1. 背景与问题

上一个改动落地了 `model_settings_dir`：dispatcher 按 `MODEL`（flash/pro/max）复制 `${MODEL}-settings.json` → `.claude/settings.json`，让 model tier 真正切换底层模型。但**"有哪些档、什么顺序"完全由 trigger 字段 `model_tiers` 的书写顺序决定**，系统不知道 flash/pro/max 的固有智慧序：

- 运维若把 `model_tiers` 配成 `max,pro`（顺序写反），系统会把 max 当第一档、pro 当升级档，违反 flash<pro<max。
- 运维必须手工保证 `model_tiers` 与 `model_settings_dir` 目录里实际放的文件一致。

需求（用户）：flash/pro/max 不一定都有，可能两个或一个。系统应**按目录里实际放了哪些 `${tier}-settings.json` 自动判断可用档**，并**严格按固有智慧序 flash<pro<max** 排成升级阶梯。例：只放 pro+max → 第一次 pro 失败升 max；只放 flash+max → 第一次 flash 失败升 max。

## 2. 目标与非目标

### 目标
- 档位**自动发现**：本部署可用档 = `model_settings_dir` 目录里实际有 `${tier}-settings.json` 的档。
- **智慧序**由 `model_tiers`（默认 `flash,pro,max`）承载，运维用默认即可，无需主动配置。
- 严格按智慧序排升级阶梯：第一档 = 最低智慧档，CC 侧失败升一档，封顶最高档。

### 非目标
- 不废弃 `model_tiers` 字段（方案 X 被否决）。它退居为"智慧序全集"，最小改动、向后兼容、可扩展。
- 不改 model 升档的触发条件（hard/soft trigger 不变）。
- 不支持"部署中途增减档位文件"导致已有 issue 的旧 model 标签与新档位集合不一致的场景（见 §7 边界）。

## 3. 核心设计：full / effective 双轨

`model_tiers`（持久配置）语义微调：从"可用档列表" → **"智慧序全集 / 优先级序"**，默认 `flash,pro,max`。运行时派生两个值：

| 名称 | 定义 | 消费者 | 用途 |
|------|------|--------|------|
| **full**（全集） | `model_tiers` 原值（默认 `flash,pro,max`） | `set_issue_label.sh` 的 `MODEL_TIERS` | model:* 互斥清除集——加 `model:X` 时移除全集里其他 `model:*`，确保清除迁移残留的旧档标签 |
| **effective**（有效阶梯） | full 中那些在 `model_settings_dir` 里**实际有 `${tier}-settings.json`** 的档，**保 full 顺序** | `reconcile.sh` 的 `MODEL_TIERS`、`resolve_model_tier` 的 `MODEL_TIERS_ARR_JSON` | 整数索引映射 + 升级阶梯 + `MODEL` 选择 |

**为什么 set_issue_label 用 full 而非 effective**：切档时要清除 issue 上**任何**配置内的旧 `model:*` 标签。迁移场景下已有 issue 带 `model:flash`，若新 effective=[pro,max] 用 effective 做互斥（清除集 [pro,max]）就清不掉 `model:flash` → 残留两个 model:* 标签污染状态机。用 full（默认 flash,pro,max）能清掉 flash。

**为什么 reconcile/resolve 用 effective**：决定"第一档是谁、升级走哪条阶梯、MODEL 选哪个文件"。effective 只含有文件的档，所以 `MODEL = effective[NEW_TIER]` 选出的 `${MODEL}-settings.json` **必然存在**（§6 副产品）。

### 派生逻辑（共享函数，放 `_dispatch_lib.sh`）

两条 trigger 路径（`dispatch_prepare_tick.sh` 主路径 + `dispatch_followup.sh` callback 窄 reconcile）都算 `MODEL_TIERS_CSV`，必须用**同一**派生逻辑，否则 callback 的整数索引与 prepare 漂移。故派生封装为共享函数：

下面是实际落地版本（注意两处易错点，均经隔离测试验证）：

```bash
# derive_effective_model_tiers <full_csv> <model_settings_dir>
#   stdout: effective CSV (full ∩ 目录实际有 ${tier}-settings.json 的档，保序)
#   未配 dir（空串）→ 原样返回 full（退化为现有行为）
#   配了 dir → 逐档 [ -r "${dir}/${t}-settings.json" ] 过滤
#   返回空（配了但无任何匹配文件）→ 返回空串，由调用方决定处置
derive_effective_model_tiers() {
  local full_csv="$1" msd="$2"
  if [ -z "${msd}" ]; then printf '%s' "${full_csv}"; return 0; fi
  # 字符串累加（非 bash 数组）：空结果在 set -u 下安全（避免 ${out[*]} unbound）。
  # read 守卫 `|| [ -n "${t}" ]` 必需：tr 在最后一档后不输出换行，裸 while read
  # 会静默丢掉它——而最后一档是最高/封顶档，丢了会悄悄截断升级阶梯。
  local out="" t
  while IFS= read -r t || [ -n "${t}" ]; do
    [ -n "${t}" ] || continue
    if [ -r "${msd}/${t}-settings.json" ]; then
      if [ -z "${out}" ]; then out="${t}"; else out="${out},${t}"; fi
    fi
  done < <(printf '%s' "${full_csv}" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  printf '%s' "${out}"
}
```

> 易错点（隔离测试暴露并修复）：(1) 裸 `while IFS= read -r t` 会丢失 `tr` 产出的无尾换行的**最高档**；(2) 空 bash 数组 `${out[*]}` 在 `set -u` 下报 unbound。上面用 read 守卫 + 字符串累加规避。

## 4. 注入点

> 注：以下行号为撰写时近似值，实现落地后整体下移约 10–20 行（实际：EFFECTIVE 派生 ~688、reconcile ~699、ensure_labels ~805、iid_env ~1135、resolve ~1176）。定位以"紧邻 XXX"的锚点描述为准。

### `scripts/_dispatch_lib.sh`
- 新增 `derive_effective_model_tiers` 函数（§3）。

### `scripts/dispatch_prepare_tick.sh`
1. **第 678 附近**：保留 `MODEL_TIERS_CSV`（= full，给 set_issue_label）。新增 `EFFECTIVE_TIERS_CSV="$(derive_effective_model_tiers "${MODEL_TIERS_CSV}" "${MODEL_SETTINGS_DIR:-}")"`。
2. **空集校验**：`if [ -n "${MODEL_SETTINGS_DIR:-}" ] && [ -z "${EFFECTIVE_TIERS_CSV}" ]; then emit_chat_failure "no_model_settings_files: model_settings_dir 配置了但目录里没有任何 <tier>-settings.json"; fi`。
3. **RECONCILE_ARGS（第 684 的 reconcile.sh）**：`MODEL_TIERS` 从 `MODEL_TIERS_CSV` 改为 `EFFECTIVE_TIERS_CSV`。
4. **ensure_labels.sh（第 790）**：`MODEL_TIERS` **保持** full `MODEL_TIERS_CSV`——GitLab 标签按**全集**创建（`model:flash`/`pro`/`max` 都建出来），迁移/未来切档时标签才存在可用。
5. **iid_env（第 1120）**：`MODEL_TIERS` **保持** `MODEL_TIERS_CSV`（full，给 set_issue_label 互斥清除集）。
6. **resolve_model_tier（第 1156）**：`MODEL_TIERS_ARR_JSON` 从读 `STATE_JSON.model_tiers` 改为由 `EFFECTIVE_TIERS_CSV` 转 JSON（`printf '%s' "${EFFECTIVE_TIERS_CSV}" | jq -Rc 'split(",")'`）。下游 `MODEL_MAX_TIER` / `HAS_ANY_MODEL` / `MODEL_TIER_LABEL` / `MODEL`（第 1230-1231）自动基于 effective。

### `scripts/dispatch_followup.sh`
7. **第 56-64 附近**：保留全集 `MODEL_TIERS_CSV`（从 `CAMPAIGN_STATE_FILE` 读）。新增从 `CAMPAIGN_STATE_FILE` 读 `model_settings_dir`，`derive_effective_model_tiers` 得 effective。
8. **第 73 窄 reconcile**：`MODEL_TIERS` 改用 effective CSV。
9. **空集处置（followup 路径）**：callback 路径的 reconcile 是 best-effort（失败不 abort）。effective 空 → **退化用 full**（不报错），保证 callback 继续处理。正常稳定部署下 effective 必非空（能 spawn 说明 prepare 时非空）。
10. **followup 的 set_issue_label 不受影响**：Phase 6 的 `set_issue_label.sh` 调用只同步 workflow 标签（`pr`/`blocked-*`/`failed-*`/`timeout`），不碰 `model:*` 维度（model 标签只在 prepare 阶段打），故 followup 无需向 set_issue_label 传 full/effective 的 `MODEL_TIERS`。

### 持久层
- `campaign_state.json.model_tiers` 仍存**全集**（carry-forward 配置），不被 effective 污染。effective 是纯运行时派生值，不持久化。

## 5. 行为验证（用户场景）

| `model_settings_dir` 目录内容 | full（默认） | effective | 第一档 | 失败升级 |
|------|------|------|------|------|
| `pro-settings.json` + `max-settings.json` | flash,pro,max | pro,max | pro | pro→max 封顶 |
| `flash-settings.json` + `max-settings.json` | flash,pro,max | flash,max | flash | flash→max 封顶 |
| 只放 `max-settings.json` | flash,pro,max | max | max | 单档不升 |
| 三个都放 | flash,pro,max | flash,pro,max | flash | flash→pro→max |
| 未配 `model_settings_dir` | flash,pro,max | flash,pro,max（退化） | flash | flash→pro→max（仅文本提示，不复制） |
| 配了但目录空 | flash,pro,max | （空）→ `emit_chat_failure` | — | — |

## 6. 失败/边界语义

- **未配 `model_settings_dir`** → effective = full，退化为上一个改动的现有行为（model tier 仅文本提示，不复制 settings）。
- **配了但目录无任何 `${tier}-settings.json`** → prepare 路径 `emit_chat_failure "no_model_settings_files"`（整 tick fail，no-fallback）；followup 路径退化用 full（best-effort，不 abort）。
- **副产品**：配了目录时 effective 只含有文件的档，`MODEL = effective[NEW_TIER]` 的 `${MODEL}-settings.json` 必然存在 → 上一个改动里"缺档文件 → blocked-dispatcher"在配了目录时几乎不触发；该检查保留为竞态/权限防御。
- **目录里有 flash/pro/max 之外的 `*-settings.json`**：不在 full（model_tiers）→ 派生时天然忽略（只遍历 full 的档名）。

## 7. 不支持的边界（明确声明）

- **部署中途增减档位文件**：档位文件集合应在首次配置时确定。中途增减会改变 effective 的整数索引语义，导致已有 issue 缓存的 `model_tier` 整数漂移（reconcile 每 tick 从 live `model:<tier>` 标签重算整数兜底，但若旧标签的档**跳出了** effective——如 effective=[flash,max] 而 issue 带 `model:pro`——`resolve_model_tier` 会视为"无有效 model 标签"并重打最低档，可能造成**降级**）。
- **迁移安全保证**：从"全三档"迁到"目录子集"时，只要 effective 是 full 的**前缀或保序子集且不跳过 issue 当前所在档**，就只会升级或持平、不降级（effective ⊆ full 且保序）。set_issue_label 用 full 做互斥确保清除旧档标签。跳过中间档（如 [flash,max] 跳过 pro）且已有 issue 恰在被跳档（model:pro）属上一条不支持场景，需人工清标签。

## 8. 文件级改动清单

| 文件 | 改动 |
|------|------|
| `scripts/_dispatch_lib.sh` | 新增 `derive_effective_model_tiers` 函数 |
| `scripts/dispatch_prepare_tick.sh` | 派生 `EFFECTIVE_TIERS_CSV` + 空集校验 + reconcile(第684)与 resolve_model_tier(第1156)改用 effective；ensure_labels(第790)/iid_env(第1120) 保持 full |
| `scripts/dispatch_followup.sh` | 读 `model_settings_dir` + 派生 effective + 窄 reconcile(第73)改用 effective + 空集退化 full |
| `references/trigger_command.md` | `model_tiers` 语义更新为"智慧序全集"；`model_settings_dir` 补"档位自动发现"说明 |
| `references/state_schema.md` | `model_tiers` 字段说明更新（全集 + effective 派生）；补 `no_model_settings_files` 失败 |
| `references/dispatcher_wrappers.md` | resolve_model_tier 步骤补 effective 派生 |
| `statemachine.v2.md` | model:{tier} 维度补"档位由 model_settings_dir 自动发现、按 model_tiers 智慧序排" |
| `CLAUDE.md` | Model-tier 段补 full/effective 双轨 |
| `SKILL.md` | line 3 `[SKILL_VERSION=...]` bump 到 `2026-06-09.N` |

## 9. 不改动项
- `reconcile.sh` / `set_issue_label.sh` / `ensure_labels.sh`：消费传入的 `MODEL_TIERS` env，逻辑不变——只是 dispatcher 传给它们的值改了（reconcile 收 effective；set_issue_label 与 ensure_labels 收 full）。
- `prepare_attempt.sh` / `env_paths.sh` / `build_prompt.sh` / `run_acpx_attempt.sh`：与档位发现无关。
- 复制段（上一个改动）：保留缺档防御检查不变。

## 10. 校验方式
- 每个改过的 `scripts/*.sh` 跑 `bash -n`。
- `derive_effective_model_tiers` 用隔离 bash 测试：建临时目录放部分 `${tier}-settings.json`，断言各场景输出（pro,max / flash,max / 单档 / 空 / 未配退化）。
- 代码改动走 `code-reviewer` 子代理审查循环（最多 3 轮），重点核 full/effective 两轨注入无串、callback 与 prepare 派生一致、空集两路径处置正确。
- 清 Stop hook：写 diff 指纹到 `.claude/.review-done-sha`。

## 11. SKILL_VERSION
- 本次改 `workspace-acpx_auto_tester/` 下 `scripts/` 与 `references/` 及 `SKILL.md`，必须同 commit bump `SKILL.md` line 3 的 `[SKILL_VERSION=...]` 至当日 `2026-06-09.N`（按序号递增；当前为 `2026-06-09.1`，本次 → `2026-06-09.2`）。
