# 状态机 v2 标签语义落地 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `statemachine.v2.md` 的标签语义落到真实实现：拆 `blocked`/`failed` 为 cc/dispatcher 两侧、`pr` 替换 `done`、`model:{tier}` 文件式自动升档、`quality:low` 软信号。

**Architecture:** 全 bash 脚本 + markdown 契约（无 Temporal/无测试框架）。侧归因靠在 reply JSON 里贯穿一个 `block_side` 字段：dispatcher 合成 = `dispatcher`，子代理解析成功 = `cc`，强制降级 = `dispatcher`。model 升档复用现有 `claude_settings_path` 的"复制 settings 文件进 worktree"机制，dispatcher 只按档位选文件、零硬编码 model id。

**Tech Stack:** bash、jq、glab CLI；语法检查 `/opt/homebrew/bin/bash -n`（本机 /bin/bash 3.2.57 会误判，必须用 homebrew bash）。

**关键参考：** spec 在 [docs/superpowers/specs/2026-06-15-statemachine-v2-labels-design.md](../specs/2026-06-15-statemachine-v2-labels-design.md)。

---

## 全局约定（每个任务都适用）

- **路径前缀**：除非特别说明，脚本在 `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/`（下称 `<SKILL>/`）。
- **语法检查**：每改一个 `.sh` 后跑 `/opt/homebrew/bin/bash -n <file>`，期望无输出、退出码 0。
- **无测试框架**：本仓无 pytest/单测。验证 = `bash -n` + 任务内的"场景核对表"（人工/审查逐条比对）+ 收尾 code-review 子代理循环。不要新建测试框架。
- **SKILL_VERSION**：本计划所有改动都在 `workspace-acpx_auto_tester/` 下，**最后一个文档任务统一 bump 一次** `SKILL.md` 第 3 行的 `[SKILL_VERSION=...]` 到 `2026-06-15.N`（见 Task 14）。中途任务不各自 bump。
- **提交粒度**：每个 Task 末尾一次 commit，中文 commit message。
- **命名锁定**：连字符 `blocked-cc` / `blocked-dispatcher` / `failed-cc` / `failed-dispatcher`；档位标签 `model:<tier>`；软信号 `quality:low`。
- **旧标签**：不迁移、不删除项目定义（项目无遗留 issue）。`ensure_labels.sh` 不再创建单一 `blocked`/`failed`；但 `set_issue_label.sh` 的 work 组**保留** `blocked`/`failed` 字面量，使 `add <新状态>` 仍能清掉偶发残留；`reconcile.sh` 兼容识别。

---

# 阶段一：标签底座（Task 1–2）

### Task 1：ensure_labels.sh 创建新标签

**Files:**
- Modify: `<SKILL>/scripts/ensure_labels.sh`

- [ ] **Step 1：改 REQUIRED_LABELS**

把第 32 行：
```bash
REQUIRED_LABELS=(todo retry new doing pr done blocked failed timeout continue)
```
改为（删 `blocked failed`，加四个新工作标签 + `quality:low`）：
```bash
REQUIRED_LABELS=(todo retry new doing pr done blocked-cc blocked-dispatcher failed-cc failed-dispatcher timeout continue quality:low)
```

- [ ] **Step 2：按 model_tiers 动态创建 model:<tier>**

在第 32 行之后、`existing=...`（第 34 行）之前，插入一段：从 trigger `MODEL_TIERS` 环境变量（dispatcher 渲染为 JSON 字符串）解析出每个 tier，追加 `model:<tier>` 到 `REQUIRED_LABELS`。`MODEL_TIERS` 缺省/空 → 不追加任何 model 标签。
```bash
# model:{tier} 档位标签按 trigger model_tiers 动态创建（缺省=不创建，特性关）。
if [ -n "${MODEL_TIERS:-}" ]; then
  while IFS= read -r _tier; do
    [ -n "${_tier}" ] && REQUIRED_LABELS+=("model:${_tier}")
  done < <(printf '%s' "${MODEL_TIERS}" | jq -r '.[].tier // empty' 2>/dev/null || true)
fi
```

- [ ] **Step 3：更新顶部注释**

第 9 行注释 `# Workflow labels: todo retry new doing pr done blocked failed timeout continue` 改为：
```bash
# Workflow labels: todo retry new doing pr done blocked-cc blocked-dispatcher failed-cc failed-dispatcher timeout continue
# Orthogonal: model:<tier> (created from trigger model_tiers; persistent), quality:low (one-shot soft signal)
```

- [ ] **Step 4：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/ensure_labels.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 5：场景核对**

确认：`MODEL_TIERS` 未设时 `jq` 那段不报错（`|| true` 兜底）、不追加 model 标签；`MODEL_TIERS='[{"tier":"flash"},{"tier":"pro"}]'` 时追加 `model:flash model:pro`。`quality:low` 含冒号但 glab label create 接受任意字符串名，无需转义（`-f name=...` 自动处理）。

- [ ] **Step 6：commit**
```bash
git add <SKILL>/scripts/ensure_labels.sh
git commit -m "拆分标签：ensure_labels 创建 blocked-cc/dispatcher、failed-cc/dispatcher、model:<tier>、quality:low"
```

---

### Task 2：set_issue_label.sh work 组与 keep 例外

**Files:**
- Modify: `<SKILL>/scripts/set_issue_label.sh`

> 背景：`model:*` / `quality:*` 不在 `WORKFLOW_LABELS` 内 → `is_workflow_label` 返回 false → 加它们时 `workflow_conflicts_for_add` 直接返回空（只单纯 add，不移除任何标签）。这正是"正交、互不影响"所需，**无需为 model/quality 增加分组代码**。model 组内互斥由 `resolve_model_tier`（Task 12）显式 remove 旧档处理。本任务只动 work 组列表与 keep 例外。

- [ ] **Step 1：扩展 WORKFLOW_LABELS（work 组）**

第 35 行：
```bash
WORKFLOW_LABELS=(todo retry new doing pr done blocked failed timeout continue contiune)
```
改为（加四个新标签；**保留** `blocked failed` 用于清残留）：
```bash
WORKFLOW_LABELS=(todo retry new doing pr done blocked-cc blocked-dispatcher failed-cc failed-dispatcher blocked failed timeout continue contiune)
```

- [ ] **Step 2：改 keep 例外（pr 替换 done + 新 blocked 对）**

第 69–76 行的 `case` 块：
```bash
  case "${label}" in
    pr)
      keep=(done pr)
      ;;
    blocked)
      keep=(done blocked)
      ;;
  esac
```
改为：
```bash
  case "${label}" in
    pr)
      keep=(pr)
      ;;
    blocked-cc)
      keep=(done blocked-cc)
      ;;
    blocked-dispatcher)
      keep=(done blocked-dispatcher)
      ;;
  esac
```
说明：`pr→(pr)` 实现 C（加 pr 即移除 done）；`blocked-cc`/`blocked-dispatcher` 保留 `{done, 自身}` 瞬态对（建 MR 前失败）。旧 `blocked` 不再有 keep 例外（agent 不再 add 它）。

- [ ] **Step 3：更新顶部注释**

第 17 行 `... except for the allowed done+pr and done+blocked pairs.` 改为：
```bash
# also removes conflicting workflow labels to keep the issue in a single
# workflow state. Allowed transient pairs: done+blocked-cc and done+blocked-dispatcher
# (failure after `done` wiki, before `pr`). `pr` replaces `done` (done removed when pr added).
# model:<tier> and quality:low are orthogonal (not in WORKFLOW_LABELS) — adding/removing
# them never disturbs work labels, and adding a work label never disturbs them.
```

- [ ] **Step 4：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/set_issue_label.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 5：场景核对表**（逐条人工/审查比对 `workflow_conflicts_for_add` 输出）

| add 的标签 | 应移除（work 组减 keep） | 不应动 |
|-----------|------------------------|--------|
| `doing` | todo retry new pr done blocked-cc blocked-dispatcher failed-cc failed-dispatcher blocked failed timeout continue contiune | model:* quality:* 人工标签 |
| `pr` | 除 `pr` 外全部 work 标签（含 `done`） | model:* quality:* |
| `blocked-cc` | 除 `done`/`blocked-cc` 外全部 work 标签 | done（保留）、model:* quality:* |
| `blocked-dispatcher` | 除 `done`/`blocked-dispatcher` 外全部 work 标签 | done（保留） |
| `model:pro`（非 work）| 无（is_workflow_label=false，直通） | 一切 |
| `quality:low`（非 work）| 无（直通） | 一切 |

- [ ] **Step 6：commit**
```bash
git add <SKILL>/scripts/set_issue_label.sh
git commit -m "拆分标签：set_issue_label work 组扩展 + pr 替换 done + blocked-cc/dispatcher 瞬态对"
```

---

# 阶段二：侧归因贯通（Task 3–7）

### Task 3：phase6 synth/normalize 注入 block_side

**Files:**
- Modify: `<SKILL>/scripts/_dispatch_lib.sh`（`phase6_synthesize_reply` ~181-209，`phase6_normalize_reply` ~235-299）

- [ ] **Step 1：synth reply 带 block_side=dispatcher**

`phase6_synthesize_reply`（~187-208）的 jq 对象里，在 `log_dir: ""` 后加一行 `block_side` 字段（所有合成回复都是 dispatcher 侧）：
```bash
    '{
      iid: $iid,
      attempt_number: $attempt_number,
      status: $status,
      mode_actual: "",
      work_branch: "",
      local_branch: "",
      commit_sha: "",
      merge_request_url: "",
      mr_action: "none",
      wiki_url: "",
      labels_added: [],
      labels_removed: [],
      summary_posted: false,
      block_reason: $block_reason,
      log_dir: "",
      block_side: "dispatcher"
    }'
```

- [ ] **Step 2：normalize 推导 block_side**

`phase6_normalize_reply` 的 jq（~261-298）：在最终对象里加 `block_side`。规则：解析成功且 status 合法 → `cc`；被 coerce（unparseable / 不支持的 status）→ `dispatcher`。

(a) 解析失败分支（~248-251）走的是 `phase6_synthesize_reply`，已带 `dispatcher`，无需改。

(b) 主 jq 对象（~261-277）末尾 `log_dir: (.log_dir | s)` 后加：
```bash
      log_dir: (.log_dir | s),
      block_side: "cc"
```
（默认 cc——真实子代理回复。）

(c) coerce 分支（~278-290，status 非法时 `.status = $synth_status`）那段，在 `.status = $synth_status` 后追加把 side 改 dispatcher：
```bash
        .status = $synth_status
        | .block_side = "dispatcher"
        | (if (.block_reason | length) == 0 then
             .block_reason = ("subagent reply carried unsupported status " + ($st | tostring) + " — coerced to " + $synth_status)
           else . end)
```
（`no_changes → blocked` 那段 ~291-294 **不改 side**：no_changes 是子代理真实产出 = cc。）

- [ ] **Step 3：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/_dispatch_lib.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 4：场景核对**
  - 合成 blocked/timeout → `block_side=dispatcher`。
  - 真实回复 `status=blocked` → `block_side=cc`。
  - 真实回复 `status=done`/`failed`/`timeout` → `block_side=cc`（无害，sync 只在 blocked/failed 用它）。
  - 不可解析 / 不支持 status → `block_side=dispatcher`。

- [ ] **Step 5：commit**
```bash
git add <SKILL>/scripts/_dispatch_lib.sh
git commit -m "侧归因：phase6 synth=dispatcher、normalize 解析=cc/降级=dispatcher 注入 block_side"
```

---

### Task 4：phase6_sync_labels 按侧选标签 + pr 替换 done

**Files:**
- Modify: `<SKILL>/scripts/_dispatch_lib.sh`（`phase6_sync_labels` 304-339）

- [ ] **Step 1：函数签名加 block_side**

第 304-305 行：
```bash
phase6_sync_labels() {
  local iid="$1" final_status="$2"
```
改为：
```bash
phase6_sync_labels() {
  local iid="$1" final_status="$2" block_side="${3:-dispatcher}"
  case "${block_side}" in cc|dispatcher) ;; *) block_side="dispatcher" ;; esac
```

- [ ] **Step 2：重写四个 case 分支**（307-332）为：

```bash
  case "${final_status}" in
    done)
      # C: pr 替换 done —— 终态只留 pr。
      _label_op "${iid}" remove doing              || rc=$?
      _label_op "${iid}" remove blocked-cc         || rc=$?
      _label_op "${iid}" remove blocked-dispatcher || rc=$?
      _label_op "${iid}" remove failed-cc          || rc=$?
      _label_op "${iid}" remove failed-dispatcher  || rc=$?
      _label_op "${iid}" remove blocked            || rc=$?
      _label_op "${iid}" remove failed             || rc=$?
      _label_op "${iid}" remove timeout            || rc=$?
      _label_op "${iid}" add pr                    || rc=$?
      _label_op "${iid}" remove done               || rc=$?
      ;;
    blocked)
      _label_op "${iid}" remove doing              || rc=$?
      _label_op "${iid}" remove timeout            || rc=$?
      _label_op "${iid}" remove failed-cc          || rc=$?
      _label_op "${iid}" remove failed-dispatcher  || rc=$?
      _label_op "${iid}" remove failed             || rc=$?
      _label_op "${iid}" remove blocked            || rc=$?
      if [ "${block_side}" = "cc" ]; then
        _label_op "${iid}" remove blocked-dispatcher || rc=$?
        _label_op "${iid}" add blocked-cc            || rc=$?
      else
        _label_op "${iid}" remove blocked-cc         || rc=$?
        _label_op "${iid}" add blocked-dispatcher    || rc=$?
      fi
      ;;
    failed)
      _label_op "${iid}" remove doing              || rc=$?
      _label_op "${iid}" remove blocked-cc         || rc=$?
      _label_op "${iid}" remove blocked-dispatcher || rc=$?
      _label_op "${iid}" remove blocked            || rc=$?
      _label_op "${iid}" remove failed             || rc=$?
      _label_op "${iid}" remove timeout            || rc=$?
      if [ "${block_side}" = "cc" ]; then
        _label_op "${iid}" remove failed-dispatcher || rc=$?
        _label_op "${iid}" add failed-cc            || rc=$?
      else
        _label_op "${iid}" remove failed-cc         || rc=$?
        _label_op "${iid}" add failed-dispatcher    || rc=$?
      fi
      ;;
    timeout)
      _label_op "${iid}" remove doing              || rc=$?
      _label_op "${iid}" remove blocked-cc         || rc=$?
      _label_op "${iid}" remove blocked-dispatcher || rc=$?
      _label_op "${iid}" remove blocked            || rc=$?
      _label_op "${iid}" remove failed-cc          || rc=$?
      _label_op "${iid}" remove failed-dispatcher  || rc=$?
      _label_op "${iid}" remove failed             || rc=$?
      _label_op "${iid}" add timeout               || rc=$?
      ;;
    *)
      echo "phase6_sync_labels: unsupported final_status=${final_status}" >&2
      return 2
      ;;
  esac
```

> 说明：保留 `remove blocked`/`remove failed`（旧标签）做清残留。`done` 分支末尾 `remove done` 放在 `add pr` 之后（`add pr` 经 set_issue_label `pr→keep(pr)` 已会移除 done，这里再显式 remove 一次幂等兜底）。

- [ ] **Step 3：更新函数头注释**（301-303）说明新增 `$3=block_side`。

- [ ] **Step 4：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/_dispatch_lib.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 5：commit**
```bash
git add <SKILL>/scripts/_dispatch_lib.sh
git commit -m "侧归因：phase6_sync_labels 按 block_side 选 blocked-/failed- 标签 + pr 替换 done"
```

---

### Task 5：phase6_process / write_state_files 贯穿 block_side + 按侧提升

**Files:**
- Modify: `<SKILL>/scripts/_dispatch_lib.sh`（`phase6_write_state_files` 378-466，`phase6_process` 581-668）

- [ ] **Step 1：write_state_files 增 block_side 入参并持久化**

`phase6_write_state_files` 签名（379-380）加第 7 个位置参数：
```bash
phase6_write_state_files() {
  local iid="$1" attempt_number="$2" reply="$3" final_status="$4" \
        prior_issue_state="$5" is_launch_synth="$6" block_side="${7:-}"
```
在 ISSUE_STATE 的 jq（437-462）里，给 `--arg` 增 `block_side`，并在对象里写入（仅当 final_status 是 blocked/failed 时记侧，否则置 null）：
- jq 调用前加 `--arg block_side "${block_side}"` 与 `--arg final_status_for_side "${final_status}"`（final_status 已有 `--arg final_status`，复用即可）。
- 对象里 `updated_at: $now` 后加：
```bash
        updated_at: $now,
        block_side: (if ($final_status == "blocked" or $final_status == "failed") and ($block_side != "") then $block_side else ($prior.block_side // null) end)
```
ATTEMPT_STATE 的 jq（413-432）同样在 `block_reason:` 后加：
```bash
        block_reason: (if ($reply.block_reason // "") == "" then null else $reply.block_reason end),
        block_side: (if ($final_status == "blocked" or $final_status == "failed") and ($block_side != "") then $block_side else null end)
```
（ATTEMPT 的 jq 需把 `--arg final_status` / `--arg block_side` 传入——检查它已有 `--arg final_status`，补 `--arg block_side "${block_side}"`。）

- [ ] **Step 2：phase6_process 读 block_side 并贯穿**

`phase6_process`（582-586）在读 `reply_status` 后加：
```bash
  local block_side
  block_side="$(printf '%s' "${reply_json}" | jq -r '.block_side // "dispatcher"')"
```

- [ ] **Step 3：首次 sync 传 block_side**

第 602 行：
```bash
  if ! _err="$(phase6_sync_labels "${iid}" "${final_status}" 2>&1 >/dev/null)"; then
```
改为：
```bash
  if ! _err="$(phase6_sync_labels "${iid}" "${final_status}" "${block_side}" 2>&1 >/dev/null)"; then
```

- [ ] **Step 4：label-sync 失败降级 = dispatcher 侧**

降级 blocked 分支（615-625）：把 `final_status="blocked"` 后补 `block_side="dispatcher"`，并给 best-effort sync 传侧：
```bash
    elif [ "${final_status}" != "failed" ]; then
      final_status="blocked"
      block_side="dispatcher"
      reply_json="$(printf '%s' "${reply_json}" | jq -c \
        --arg le "phase6 label sync failed: ${label_err}" '
        .status = "blocked"
        | .block_side = "dispatcher"
        | (.block_reason = (if .block_reason == "" then $le else (.block_reason + "; " + $le) end))
      ')"
      phase6_sync_labels "${iid}" blocked "dispatcher" >/dev/null 2>&1 || true
    fi
```
timeout 的 best-effort 重试 sync（614）`phase6_sync_labels "${iid}" timeout` 不需要侧（timeout 不拆），保持原样。

- [ ] **Step 5：write_state_files 调用传 block_side（两处）**

第 632-633：
```bash
  new_retry_count="$(phase6_write_state_files "${iid}" "${attempt_number}" "${reply_json}" \
    "${final_status}" "${prior_issue_state}" "${is_launch_synth}" "${block_side}")"
```
提升后重写（642-643）：
```bash
    phase6_write_state_files "${iid}" "${attempt_number}" "${reply_json}" \
      "${final_status}" "${prior_issue_state}" "${is_launch_synth}" "${block_side}" >/dev/null
```

- [ ] **Step 6：提升 blocked→failed 用同侧**

第 639-640：
```bash
    final_status="failed"
    phase6_sync_labels "${iid}" failed >/dev/null 2>&1 || true
```
改为（提升保持原 block_side：cc→failed-cc，dispatcher→failed-dispatcher）：
```bash
    final_status="failed"
    phase6_sync_labels "${iid}" failed "${block_side}" >/dev/null 2>&1 || true
```

- [ ] **Step 7：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/_dispatch_lib.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 8：场景核对**
  - cc 侧 blocked 超限 → failed-cc。
  - dispatcher 侧 blocked 超限 → failed-dispatcher。
  - label-sync 失败 → 强制 dispatcher 侧 blocked。
  - state.json / attempt_state.json 落 `block_side`。

- [ ] **Step 9：commit**
```bash
git add <SKILL>/scripts/_dispatch_lib.sh
git commit -m "侧归因：phase6_process 贯穿 block_side、按侧提升 failed-cc/dispatcher、持久化 block_side"
```

---

### Task 6：reconcile.sh 信号拆侧 + pr 替换 done + 读 model

**Files:**
- Modify: `<SKILL>/scripts/reconcile.sh`

- [ ] **Step 1：has_blocked / has_failed 改为新标签并集（兼容旧）**

第 122-123 行：
```bash
      (($labels | index("blocked") != null)) as $has_blocked |
      (($labels | index("failed") != null)) as $has_failed |
```
改为：
```bash
      (($labels | index("blocked-cc") != null) or ($labels | index("blocked-dispatcher") != null) or ($labels | index("blocked") != null)) as $has_blocked |
      (($labels | index("failed-cc") != null) or ($labels | index("failed-dispatcher") != null) or ($labels | index("failed") != null)) as $has_failed |
```

- [ ] **Step 2：完成判定 pr 替换 done**

第 117 行：
```bash
      (($labels | index("done") != null) and ($labels | index("pr") != null)) as $done_with_pr |
```
改为（C：完成 = 有 pr；done 变纯瞬态）：
```bash
      (($labels | index("pr") != null)) as $done_with_pr |
```
（保留变量名 `$done_with_pr` 与字段名 `has_done_pr` / `is_done_on_gitlab` 不动，避免牵连 dispatch_prepare_tick.sh 的消费端。语义改为"有 pr 即完成"。）

- [ ] **Step 3：user_reopened 排除集补全新标签**

第 139-140 行：
```bash
          ($labels | index("failed") == null) and
          ($labels | index("blocked") == null) and
```
改为：
```bash
          ($labels | index("failed") == null) and
          ($labels | index("failed-cc") == null) and
          ($labels | index("failed-dispatcher") == null) and
          ($labels | index("blocked") == null) and
          ($labels | index("blocked-cc") == null) and
          ($labels | index("blocked-dispatcher") == null) and
```

- [ ] **Step 4：新增 model_tier 信号**

在 digest 对象里（124-146，`needs_continue:` 后、`missing:` 前）加一个字段，从 labels 里捞 `model:` 前缀（`"model:"` 长度 6，故取 `.[6:]` 去前缀）：
```bash
        needs_continue: (($closed | not) and $needs_continue),
        model_tier: (($labels // []) | map(select(startswith("model:"))) | (.[0] // null) | (if . == null then null else (.[6:]) end)),
        missing: false
```
missing 分支（149 行）的 `jq -nc` 对象也加 `model_tier:null`：
```bash
... needs_continue:false, model_tier:null, missing:true}')"
```

- [ ] **Step 5：更新顶部注释**

第 31-39 行字段说明：`has_done_pr` 改注"labels include `pr`（pr 替换 done 后，有 pr 即完成）"；`has_blocked`/`has_failed` 注"任一 cc/dispatcher 变体或旧单一标签"；补 `model_tier` 字段说明。

- [ ] **Step 6：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/reconcile.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 7：场景核对**
  - 仅 `pr` → has_done_pr=true（完成）。仅 `done`（无 pr）→ has_done_pr=false（未完成，瞬态）。
  - `blocked-cc` → has_blocked=true。`failed-dispatcher` → has_failed=true。
  - `model:pro` → model_tier="pro"。无 model 标签 → null。
  - `blocked-dispatcher` 在场 → user_reopened=false。

- [ ] **Step 8：commit**
```bash
git add <SKILL>/scripts/reconcile.sh
git commit -m "侧归因：reconcile has_blocked/has_failed 拆侧并集 + pr 替换 done + 读 model_tier 信号"
```

---

### Task 7：executor_prompt.md 子代理打 blocked-cc + pr 替换 done

**Files:**
- Modify: `<SKILL>/references/executor_prompt.md`

> 子代理失败一律 CC 侧 → 把所有 live-label `add blocked` 改为 `add blocked-cc`；compact JSON 的 `status` 枚举**保持 `blocked`**（侧由 dispatcher 据来源推导），仅改 `labels_added` 报告值。

- [ ] **Step 1：fail_flow 改 blocked-cc**（~357）

```
         bash {SCRIPTS_DIR}/set_issue_label.sh add blocked
```
改为：
```
         bash {SCRIPTS_DIR}/set_issue_label.sh add blocked-cc
```
并把第 359 行 "leave the issue as `done` + `blocked`" 改为 "`done` + `blocked-cc`"。

- [ ] **Step 2：B4 blocked_push 改 blocked-cc**（~423, ~428）

第 423 行 `add blocked` → `add blocked-cc`；第 427-428 "labels_added (include \"blocked\")" → "include \"blocked-cc\""。

- [ ] **Step 3：blocked_push 终态 JSON**（~452）

```
    labels_added      = ["blocked"]      (plus any other successfully-added)
```
改为：
```
    labels_added      = ["blocked-cc"]   (plus any other successfully-added)
```

- [ ] **Step 4：labels 文档行**（~324）

```
  - labels_added / labels_removed: ... For done: ["done","pr"] added, ["doing"] removed. For blocked before `done`: ["blocked"] added, ["doing"] removed. For blocked after `done` but before `pr`: include both "done" and "blocked" in labels_added, and do NOT include "pr". For timeout: ["timeout"] added, ["doing"] removed.
```
改为（done 端 pr 替换；blocked 端 cc）：
```
  - labels_added / labels_removed: ... For done: ["pr"] added, ["doing","done"] removed (pr replaces done — done was a transient set in Step 6 then removed when pr is added). For blocked before `done`: ["blocked-cc"] added, ["doing"] removed. For blocked after `done` but before `pr`: include both "done" and "blocked-cc" in labels_added, and do NOT include "pr". For timeout: ["timeout"] added, ["doing"] removed.
```

- [ ] **Step 5：Step 8 add pr 说明**（~295）

```
  After this step the live issue should carry both `done` and `pr`. Set ATTEMPT_STATUS=done. CAPTURE labels_added includes "pr".
```
改为：
```
  After this step the live issue should carry `pr` only — `set_issue_label.sh add pr` removes `done` (pr replaces done). Set ATTEMPT_STATUS=done. CAPTURE labels_added includes "pr"; labels_removed includes "done".
```

- [ ] **Step 6：fail_flow 列表行 B4/T4 引用**（~347）

该行提到 "in the exact form used at Step 6 / B4 / T4" 无需改（仍指向同样的形式）。确认 fail_flow 三步里 add 的是 `blocked-cc`（Step 1 已改）。

- [ ] **Step 7：sanity（无 bash -n，markdown）**

`grep -n "add blocked\b" <SKILL>/references/executor_prompt.md` 应**无**残留裸 `add blocked`（只剩 `add blocked-cc`）。`grep -n "set_issue_label.sh add blocked-cc"` 应有 2 处（fail_flow + B4）。

- [ ] **Step 8：commit**
```bash
git add <SKILL>/references/executor_prompt.md
git commit -m "侧归因：executor 子代理失败一律打 blocked-cc + Step 8 pr 替换 done"
```

---

# 阶段三：dispatch_prepare_tick 进 doing 清除集（Task 8）

### Task 8：dispatch_prepare_tick.sh REMOVE_LBLS 扩展

**Files:**
- Modify: `<SKILL>/scripts/dispatch_prepare_tick.sh`（第 1239 行）

> prep_blocked / scope-evict / launch_failed 三条路径都走 `phase6_synthesize_blocked` → reply 带 `block_side=dispatcher`（Task 3 已实现）→ 自动落 `blocked-dispatcher`，**无需改这些路径**。本任务只补"进 doing 清除集"。

- [ ] **Step 1：扩展 REMOVE_LBLS**

第 1239 行：
```bash
  REMOVE_LBLS=(todo retry new continue contiune blocked done pr timeout)
```
改为（加四个新标签；保留旧 blocked/failed 清残留；**不含** model:* / quality:low）：
```bash
  REMOVE_LBLS=(todo retry new continue contiune blocked blocked-cc blocked-dispatcher failed failed-cc failed-dispatcher done pr timeout)
```

- [ ] **Step 2：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/dispatch_prepare_tick.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 3：场景核对**
  - 进 doing 时移除所有 work 标签变体；`model:*` / `quality:low` **不在列表** → 保留（model 持久；quality:low 由 resolve_model_tier 决定消费）。

- [ ] **Step 4：commit**
```bash
git add <SKILL>/scripts/dispatch_prepare_tick.sh
git commit -m "侧归因：dispatch_prepare_tick 进 doing 清除集补全 blocked-/failed- 变体"
```

---

# 阶段四：model 文件式升档 + quality:low（Task 9–12）

### Task 9：trigger 字段 model_tiers / continue_upgrade_threshold

**Files:**
- Modify: `<SKILL>/references/trigger_command.md`（optional 字段表，参考 `claude_settings_path` 行 66）

- [ ] **Step 1：新增字段说明**

在 optional 字段表里 `claude_settings_path` 行之后加两行：
```
| `model_tiers`               | Optional ordered JSON array of `{"tier":"<suffix>","settings":"<abs path to .claude/settings.json>"}`. Defines the model:{tier} dimension: array order = tier order (first = lowest/default TIER_0, last = cap). When set, `ensure_labels.sh` creates `model:<tier>` per element and `resolve_model_tier` (Phase 4) auto-upgrades per issue and copies the resolved tier's `settings` file into `${WORKTREE_DIR}/.claude/settings.json` (same copy+skip-worktree mechanism as `claude_settings_path`). Each `settings` path is validated like `claude_settings_path` (absolute, chars in `[A-Za-z0-9_./-]`, no `..`, must exist+readable at copy time, else the IID is blocked). Omitted/empty → the model dimension is disabled (no model:* labels, resolve_model_tier skipped, settings fall back to claude_settings_path → committed). Carry-forward persisted in campaign_state.json. |
| `continue_upgrade_threshold`| Optional positive integer (default 2). Soft trigger for model upgrade: when an issue's cumulative `continue`-mode runs (`state.json.continue_count`) reach this value, resolve_model_tier upgrades one tier. Carry-forward persisted. |
```

- [ ] **Step 2：settings 注入优先级说明**

在 `claude_settings_path` 行的描述末尾补一句：
```
When `model_tiers` is also configured, the resolved tier's settings file takes precedence over `claude_settings_path` for the worktree `.claude/settings.json`.
```

- [ ] **Step 3：commit**
```bash
git add <SKILL>/references/trigger_command.md
git commit -m "model 升档：trigger 新增 model_tiers / continue_upgrade_threshold 字段"
```

---

### Task 10：campaign_state 持久 model_tiers / continue_upgrade_threshold

**Files:**
- Modify: `<SKILL>/scripts/_dispatch_lib.sh`（`fresh_init_state` 118-163）
- Modify: `<SKILL>/scripts/dispatch_prepare_tick.sh`（trigger override / carry-forward 段）

- [ ] **Step 1：fresh_init_state 加字段**

`fresh_init_state` 的 jq 对象（125-163）里，在 `ui_accounts_relpath: $ui_accounts_relpath,` 后加：
```bash
      ui_accounts_relpath: $ui_accounts_relpath,
      model_tiers: null,
      continue_upgrade_threshold: 2,
```
并在 jq 顶部 `--arg ...` 区域无需加（默认值是字面量，不来自 env）。

- [ ] **Step 2：trigger override / carry-forward**

在 dispatch_prepare_tick.sh 处理 trigger 覆盖 campaign_state 的段落（与 `ui_accounts_relpath` / `result_basename` 同类，用 grep 定位 `ui_accounts_relpath` 在 dispatch_prepare_tick.sh 的覆盖处），按相同模式加 `model_tiers`（来自 `T[model_tiers]`，JSON 透传；缺省保留旧值=carry-forward）与 `continue_upgrade_threshold`（来自 `T[continue_upgrade_threshold]`，整数；缺省保留旧值）。

> 实现者：先 `grep -n "ui_accounts_relpath" <SKILL>/scripts/dispatch_prepare_tick.sh` 找到 carry-forward 写法，对 `model_tiers` / `continue_upgrade_threshold` 照搬。`model_tiers` 用 `--argjson`（JSON 数组），缺省时 `// $prior.model_tiers`；`continue_upgrade_threshold` 用 `--argjson`（整数），校验 ≥1，非法 → abort `"invalid_continue_upgrade_threshold: must be >= 1"`。

- [ ] **Step 3：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/_dispatch_lib.sh && /opt/homebrew/bin/bash -n <SKILL>/scripts/dispatch_prepare_tick.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 4：commit**
```bash
git add <SKILL>/scripts/_dispatch_lib.sh <SKILL>/scripts/dispatch_prepare_tick.sh
git commit -m "model 升档：campaign_state 持久 model_tiers / continue_upgrade_threshold（carry-forward）"
```

---

### Task 11：state.json 写入 model_tier / continue_count

**Files:**
- Modify: `<SKILL>/scripts/dispatch_prepare_tick.sh`（state.json 初始化 1290-1316）

> `block_side` 由 Task 5 在 Phase 6 写。本任务在 Phase 4 init（status=in_progress）写 `model_tier`（来自 Task 12 的 resolve）与 `continue_count`（continue 模式累计）。

- [ ] **Step 1：continue_count 递增**

在 state.json 初始化处（~1305-1316，写 `{iid:$iid, session:$session, status:"in_progress", mode:$mode, ...}`），读 prior state.json 的 `continue_count`，当 `MODE_ACTUAL=continue` 时 +1，否则保留：
```bash
  PRIOR_CONTINUE_COUNT="$( [ -f "${ISSUE_STATE_X}" ] && jq -r '.continue_count // 0' "${ISSUE_STATE_X}" || echo 0 )"
  NEW_CONTINUE_COUNT="${PRIOR_CONTINUE_COUNT}"
  [ "${MODE_ACTUAL}" = "continue" ] && NEW_CONTINUE_COUNT=$(( PRIOR_CONTINUE_COUNT + 1 ))
```
在该 jq 的 `--arg` 区加 `--argjson continue_count "${NEW_CONTINUE_COUNT}"` 与 `--arg model_tier "${RESOLVED_MODEL_TIER:-}"`，对象里加：
```bash
      status:"in_progress", mode:$mode,
      continue_count:$continue_count,
      model_tier:(if $model_tier == "" then (.model_tier // null) else $model_tier end),
```
（`RESOLVED_MODEL_TIER` 由 Task 12 在本 IID 循环内、init 之前 export/赋值；model_tiers 未启用时为空 → 保留旧值/null。）

- [ ] **Step 2：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/dispatch_prepare_tick.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 3：commit**
```bash
git add <SKILL>/scripts/dispatch_prepare_tick.sh
git commit -m "model 升档：state.json 写入 continue_count 与 model_tier 缓存"
```

---

### Task 12：resolve_model_tier + settings 注入

**Files:**
- Modify: `<SKILL>/scripts/dispatch_prepare_tick.sh`（per-IID 循环内，~1140 之后、claude_settings 块 ~1195 之前）

- [ ] **Step 1：写 resolve_model_tier 逻辑**

在 per-IID 循环里、ISSUE_MODE 解析（~1140）之后，claude_settings_path 块（~1195）之前，插入（gated on `T[model_tiers]` 非空）。`RESOLVED_MODEL_TIER` 默认空（特性关）：
```bash
  # ── resolve_model_tier（D：model:{tier} 文件式自动升档；仅当 model_tiers 配置）──
  RESOLVED_MODEL_TIER=""
  MODEL_SETTINGS_SRC=""
  if [ -n "${T[model_tiers]:-}" ]; then
    MT_JSON="${T[model_tiers]}"
    # 有序档位数组
    mapfile -t MT_TIERS < <(printf '%s' "${MT_JSON}" | jq -r '.[].tier')
    if [ "${#MT_TIERS[@]}" -eq 0 ]; then
      prep_blocked "model_tiers configured but empty/invalid"; continue
    fi
    DEFAULT_TIER="${MT_TIERS[0]}"
    CAP_TIER="${MT_TIERS[$(( ${#MT_TIERS[@]} - 1 ))]}"
    # 当前档：live model 标签（reconcile evidence）→ 否则 state.json 缓存 → 否则 TIER_0
    CUR_TIER="$(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '.[] | select(.iid==$i) | .model_tier // empty')"
    [ -n "${CUR_TIER}" ] || CUR_TIER="$( [ -f "${ISSUES_ROOT}/issue-${iid}/state.json" ] && jq -r '.model_tier // empty' "${ISSUES_ROOT}/issue-${iid}/state.json" || true )"
    [ -n "${CUR_TIER}" ] || CUR_TIER="${DEFAULT_TIER}"
    # 上一轮 outcome（CC 侧硬触发）+ 软触发
    PRIOR_STATE="$( [ -f "${ISSUES_ROOT}/issue-${iid}/state.json" ] && cat "${ISSUES_ROOT}/issue-${iid}/state.json" || echo '{}' )"
    PRIOR_STATUS="$(printf '%s' "${PRIOR_STATE}" | jq -r '.status // ""')"
    PRIOR_SIDE="$(printf '%s' "${PRIOR_STATE}" | jq -r '.block_side // ""')"
    CONT_COUNT="$(printf '%s' "${PRIOR_STATE}" | jq -r '.continue_count // 0')"
    CONT_THRESHOLD="$(printf '%s' "${STATE_JSON}" | jq -r '.continue_upgrade_threshold // 2')"
    HAS_QUALITY_LOW="$(printf '%s' "${EVIDENCE_JSON}" | jq -r --argjson i "${iid}" '.[] | select(.iid==$i) | (.labels // []) | index("quality:low") != null')"
    UPGRADE="no"
    # 硬触发：CC 侧 {blocked-cc, timeout, failed-cc}（timeout 恒 CC）
    case "${PRIOR_STATUS}" in
      timeout) UPGRADE="yes" ;;
      blocked|failed) [ "${PRIOR_SIDE}" = "cc" ] && UPGRADE="yes" ;;
    esac
    # 软触发：quality:low ∨ continue 累计 ≥ 阈值（自动评分=占位 no-op）
    [ "${HAS_QUALITY_LOW}" = "true" ] && UPGRADE="yes"
    [ "${CONT_COUNT}" -ge "${CONT_THRESHOLD}" ] && [ "${CONT_THRESHOLD}" -ge 1 ] && UPGRADE="yes"
    # 求新档（单调升、封顶）
    NEW_TIER="${CUR_TIER}"
    if [ "${UPGRADE}" = "yes" ] && [ "${CUR_TIER}" != "${CAP_TIER}" ]; then
      cur_idx=-1
      for i_t in "${!MT_TIERS[@]}"; do [ "${MT_TIERS[$i_t]}" = "${CUR_TIER}" ] && cur_idx="${i_t}"; done
      if [ "${cur_idx}" -ge 0 ] && [ "$(( cur_idx + 1 ))" -lt "${#MT_TIERS[@]}" ]; then
        NEW_TIER="${MT_TIERS[$(( cur_idx + 1 ))]}"
      fi
    fi
    RESOLVED_MODEL_TIER="${NEW_TIER}"
    # 取该档 settings 文件路径
    MODEL_SETTINGS_SRC="$(printf '%s' "${MT_JSON}" | jq -r --arg t "${NEW_TIER}" '.[] | select(.tier==$t) | .settings // empty')"
    # 写 model:{新档} 标签：先 remove 所有其它档（知道全集），再 add 新档
    iid_env=(PROJECT="${PROJECT}" GROUP="${GROUP}" GITLAB_TOKEN="${GITLAB_TOKEN}" REPO_PARENT_PATH="${REPO_PARENT_PATH}" RESULT_BASENAME="${RESULT_BASENAME}" DATA_BASENAME="${DATA_BASENAME}" ISSUE_IID="${iid}" ATTEMPT_NUMBER="${ATTEMPT_NUM}")
    for t_other in "${MT_TIERS[@]}"; do
      [ "${t_other}" = "${NEW_TIER}" ] && continue
      env "${iid_env[@]}" bash "${SCRIPT_DIR}/set_issue_label.sh" remove "model:${t_other}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1 || true
    done
    env "${iid_env[@]}" bash "${SCRIPT_DIR}/set_issue_label.sh" add "model:${NEW_TIER}" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1 || true
    # 软触发用过的 quality:low 消费掉（升档或封顶都移除，避免长期残留）
    if [ "${HAS_QUALITY_LOW}" = "true" ]; then
      env "${iid_env[@]}" bash "${SCRIPT_DIR}/set_issue_label.sh" remove "quality:low" >>"${DISPATCHER_LOG_DIR}/wrapper.log" 2>&1 || true
    fi
  fi
```

> 实现者注意：`ATTEMPT_NUM` / `iid_env` / `EVIDENCE_JSON` / `ISSUES_ROOT` / `STATE_JSON` / `ATTEMPT_NUM` 是否已在循环作用域内可用——用 `grep -n` 核对变量名（循环里已构造过 `iid_env`/`ATTEMPT_NUM` 用于 set_issue_label doing 转换，复用即可；若名字不同照实际改）。`RESOLVED_MODEL_TIER` 供 Task 11 的 state.json init 读取。

- [ ] **Step 2：settings 注入优先级（改 claude_settings_path 块）**

claude_settings_path 块（1196-1216）的逻辑改为：**先看 model_tiers 解析出的 `MODEL_SETTINGS_SRC`，有则用它；否则回退 claude_settings_path**。即在 1196 的 `if [ -n "${T[claude_settings_path]:-}" ]; then` 之前加一个分支：
```bash
  # model_tiers 档位 settings 优先（D）
  if [ -n "${MODEL_SETTINGS_SRC}" ]; then
    case "${MODEL_SETTINGS_SRC}" in
      /) prep_blocked "model_tiers settings must not be /"; continue ;;
      /*) : ;;
      *) prep_blocked "model_tiers settings must be absolute: ${MODEL_SETTINGS_SRC}"; continue ;;
    esac
    case "${MODEL_SETTINGS_SRC}" in
      *..*|*' '*|*[!A-Za-z0-9_./-]*) prep_blocked "invalid model_tiers settings path: ${MODEL_SETTINGS_SRC}"; continue ;;
    esac
    if [ ! -r "${MODEL_SETTINGS_SRC}" ]; then
      prep_blocked "model_tiers settings file not found or not readable: ${MODEL_SETTINGS_SRC}"; continue
    fi
    if ! cp "${MODEL_SETTINGS_SRC}" "${WORKTREE_DIR_X}/.claude/settings.json"; then
      prep_blocked "model_tiers settings copy failed"; continue
    fi
    git -C "${WORKTREE_DIR_X}" update-index --skip-worktree .claude/settings.json || true
  elif [ -n "${T[claude_settings_path]:-}" ]; then
    # ……原有 claude_settings_path 逻辑保持不变……
```
（把原 `if [ -n "${T[claude_settings_path]:-}" ]; then` 改成 `elif`，其余原样。校验逻辑与 claude_settings_path 对齐。）

- [ ] **Step 3：语法检查**

Run: `/opt/homebrew/bin/bash -n <SKILL>/scripts/dispatch_prepare_tick.sh`
Expected: 无输出，退出码 0。

- [ ] **Step 4：场景核对**
  - model_tiers 未配 → `RESOLVED_MODEL_TIER=""`、`MODEL_SETTINGS_SRC=""` → 不打 model 标签、settings 回退 claude_settings_path/committed。
  - 上一轮 blocked-cc / timeout / failed-cc → 升一档。
  - 上一轮 blocked-dispatcher / failed-dispatcher → 不升。
  - quality:low 在场 → 升一档 + 移除 quality:low。
  - continue_count ≥ 阈值 → 升一档。
  - 已在 CAP_TIER → 保持封顶。
  - 新档 settings 文件复制进 worktree + skip-worktree。

- [ ] **Step 5：commit**
```bash
git add <SKILL>/scripts/dispatch_prepare_tick.sh
git commit -m "model 升档：resolve_model_tier 求档位 + 写 model 标签 + 档位 settings 注入优先级 + 消费 quality:low"
```

---

# 阶段五：文档 + 版本（Task 13–14）

### Task 13：references / 状态 schema / 设计稿同步

**Files:**
- Modify: `<SKILL>/references/state_schema.md`
- Modify: `<SKILL>/references/label_lifecycle.md`
- Modify: `<SKILL>/references/continue_mode.md`（如提到单一 blocked/failed/done+pr）
- Modify: `statemachine.v2.md`（仓库根，非 workspace）

- [ ] **Step 1：state_schema.md**
  - `state.json` 增 `model_tier`(string|null) / `block_side`(string|null: cc|dispatcher) / `continue_count`(int)。
  - `campaign_state.json` 增 `model_tiers`(array|null) / `continue_upgrade_threshold`(int, default 2)。
  - reconcile evidence digest 增 `model_tier` 字段；`has_done_pr` 语义改注"有 pr 即完成"。
  - status 枚举说明：保持 `done|no_changes|blocked|failed|timeout`（compact reply 不变）；补一段"侧由 dispatcher 据来源推导，reply 不含 block_side（dispatcher 内部在 normalize/synth 时注入）"。
  - Phase 6 Write Mapping：blocked/failed 按 block_side 落 `blocked-cc`/`blocked-dispatcher`/`failed-cc`/`failed-dispatcher`；done → pr（替换）。

- [ ] **Step 2：label_lifecycle.md**
  - Required project labels 列表替换为新标签集 + model:<tier> + quality:low。
  - 规则 1（pr additive）改写为"pr 替换 done"。规则 3（done+pr 才完成）改为"pr 即完成"。规则 6/8 的 done+pr / done+blocked 对改为 done+blocked-cc / done+blocked-dispatcher。
  - 转换表：`doing→blocked` 拆为 `doing→blocked-cc`（子代理）与 `doing→blocked-dispatcher`（调度器合成）；`blocked→failed` 拆为同侧；`done→done+pr` 改 `done→pr`。
  - 新增 model:<tier> 维度与 quality:low 一节。

- [ ] **Step 3：continue_mode.md** —— grep `blocked\|failed\|done.*pr`，凡提到处同步（多半只需把 done+pr 改 pr、blocked 改 blocked-cc 语境）。

- [ ] **Step 4：statemachine.v2.md** —— §4「实现状态（未落地）」改为「已落地」，落地点列真实文件（ensure_labels/set_issue_label/reconcile/_dispatch_lib/dispatch_prepare_tick/executor_prompt）；§0 顶部"更早版本已确立"那句更正为"本次落地"。

- [ ] **Step 5：sanity** —— `grep -rn "done.*+.*pr\|additive" <SKILL>/references/label_lifecycle.md` 确认无"pr additive"残留。

- [ ] **Step 6：commit**
```bash
git add <SKILL>/references/state_schema.md <SKILL>/references/label_lifecycle.md <SKILL>/references/continue_mode.md statemachine.v2.md
git commit -m "文档：references/state_schema/label_lifecycle/continue_mode/statemachine.v2 同步 v2 标签语义"
```

---

### Task 14：SKILL.md / SOUL.md / AGENTS.md / CLAUDE.md + SKILL_VERSION bump

**Files:**
- Modify: `<SKILL>/SKILL.md`（含 SKILL_VERSION bump）
- Modify: `workspace-acpx_auto_tester/SOUL.md`
- Modify: `workspace-acpx_auto_tester/AGENTS.md`
- Modify: `CLAUDE.md`（仓库根，非 workspace，不触发 bump，但需同步描述）

- [ ] **Step 1：SKILL.md 算法描述同步**
  - Phase 6 分类、outcome→label 按侧拆（blocked-cc/dispatcher、failed-cc/dispatcher）。
  - pr 替换 done（completion = pr）。
  - 新增 model:{tier} 维度 + resolve_model_tier（Phase 4）+ model_tiers/continue_upgrade_threshold trigger 字段 + quality:low。
  - §Source-of-Truth：reconcile model_tier 信号、has_blocked/has_failed 拆侧并集。

- [ ] **Step 2：SKILL_VERSION bump**

把 SKILL.md 第 3 行 `description:` 内的 `[SKILL_VERSION=YYYY-MM-DD.N]` 改为今天日期序号：
```
先 grep -n "SKILL_VERSION" <SKILL>/SKILL.md 看现值。
若日期非 2026-06-15 → 改为 [SKILL_VERSION=2026-06-15.1]。
若已是 2026-06-15.N → N+1。
```

- [ ] **Step 3：SOUL.md / AGENTS.md** —— 标签模型、侧归因、pr 替换 done、model 维度同步（grep `blocked\|failed\|done` 定位）。

- [ ] **Step 4：CLAUDE.md** —— 仓库根，描述 Path B Phase 6（done+pr → pr；blocked → blocked-cc/dispatcher；failed 提升拆侧）、Phase 4（resolve_model_tier）、Concurrency/source-of-truth 同步。注：CLAUDE.md 非 workspace，不触发 bump，orchestrator 不读它（见记忆 [[feedback_orchestrator_prompt_sources]]），但保持与代码一致。

- [ ] **Step 5：commit**
```bash
git add <SKILL>/SKILL.md workspace-acpx_auto_tester/SOUL.md workspace-acpx_auto_tester/AGENTS.md CLAUDE.md
git commit -m "文档：SKILL/SOUL/AGENTS/CLAUDE 同步 v2 标签语义 + bump SKILL_VERSION"
```

---

# 收尾：code-review 循环

### Task 15：code-review 子代理循环

- [ ] **Step 1：全量语法检查**
```bash
for f in <SKILL>/scripts/*.sh; do /opt/homebrew/bin/bash -n "$f" || echo "SYNTAX FAIL: $f"; done
```
Expected: 无 "SYNTAX FAIL" 输出。

- [ ] **Step 2：spawn code-reviewer 子代理**

`Agent(subagent_type="code-reviewer")`，prompt 传 diff 范围："review 本分支 feat/statemachine-v2-labels 相对 master 的全部改动，重点：标签互斥正确性、block_side 贯穿、pr 替换 done 的完成判定一致性、resolve_model_tier 边界（封顶/缺省/索引）、bash 引用与 set -u 安全。"

- [ ] **Step 3：处理反馈**，最多 3 轮。第 3 轮后仍有问题 → 停，把报告给用户决策（CLAUDE.md 规定）。

- [ ] **Step 4：解除 Stop hook**

review 通过后，按 hook 提示把当前 diff 指纹写入 `.claude/.review-done-sha`（hook 的 reason 文本里给出确切 `printf %s '<hash>' > .claude/.review-done-sha` 命令）。

---

## 自检（写计划后回看 spec 的覆盖）

| spec 要求 | 对应 Task |
|----------|----------|
| A 拆 blocked（cc/dispatcher）| 1,2,3,4,5,6,7,8 |
| B 拆 failed（cc/dispatcher）| 1,2,4,5,6,8 |
| C pr 替换 done | 2,4,6,7,13 |
| D model:{tier} 文件式升档 | 1,9,10,11,12,13,14 |
| E quality:low | 1,12,13 |
| 侧归因 block_side 贯穿 | 3,4,5,6,7 |
| 三组互斥（前缀直通）| 2,8 |
| 旧标签兼容（不迁移）| 1,2,4,6 |
| 状态 schema 变更 | 5,10,11,13 |
| SKILL_VERSION + 文档 + review | 13,14,15 |
