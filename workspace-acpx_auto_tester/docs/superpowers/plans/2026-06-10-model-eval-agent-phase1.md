# model-eval agent 阶段一 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `benchmark-test` 分支的 agent 能对同一 issue pin 不同 model 各跑一轮，产出 per-attempt 不可变分支 + 全量留档 + 效率/准确率指标 + 对比矩阵（阶段一只做行为变更，不删旧子系统的死代码——那是阶段二）。

**Architecture:** 在现有 dispatcher（thick orchestrator + anonymous subagent + async callback）之上做最小侵入改造：(1) 新增 `pin_model_tier` 触发字段绕过失败升档；(2) 新增 best-effort `collect_metrics.sh`（效率=掐表、准确率=解析 Robot Framework `output.xml`）；(3) `stage_and_guard.sh` 全量入库、`commit_and_push.sh` 推 per-attempt 不可变分支；(4) executor 跳过 MR/pr、终态 `done`，回执带 `metrics`；(5) Phase 6 把 `metrics` append 到 append-only ledger，新增 `aggregate_benchmark.sh` 出矩阵。

**Tech Stack:** bash + jq + python3（Robot Framework 运行环境必带 python3）+ glab CLI + git worktree。

### 本仓库的「测试」现实（替代 pytest 式 TDD）

这是 OpenClaw agent 部署工件，**无 build / 无 pytest / 不能在本机跑 acpx·glab**（见根 `CLAUDE.md`）。每个任务的验证手段按可行性分三档：

1. **本地 fixture 冒烟**（纯逻辑脚本：`collect_metrics.sh` / `aggregate_benchmark.sh`）——在本机用造好的 `output.xml` / `metrics.jsonl` 直接跑，断言输出。**这类必须先写失败的 fixture 测试再实现**（TDD）。
2. **`bash -n` 语法检查 + 人工走查锚点**（改动深耦合 dispatcher 脚本：`dispatch_*`、`_dispatch_lib.sh`、`commit_and_push.sh` 等，无法本机端到端执行）。
3. **`code-reviewer` 子代理审查循环**（每个 `workspace-acpx_auto_tester/` 改动必走，最多 3 轮，见根 `CLAUDE.md` §Code review workflow）。

每次 `workspace-acpx_auto_tester/` 下的改动都要 **bump `SKILL.md` 第 3 行的 `[SKILL_VERSION=...]`** 到 `2026-06-10.N`（同日递增 N）。

**约定：** `SKILL_DIR` = `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher`。所有相对路径以仓库根为准。

---

## Task 1: 新增 `collect_metrics.sh`（效率 + 准确率，best-effort）

**Files:**
- Create: `$SKILL_DIR/scripts/collect_metrics.sh`
- Create (test fixtures): `$SKILL_DIR/scripts/_test/fixtures/output_pass.xml`, `$SKILL_DIR/scripts/_test/fixtures/timing.txt`
- Create (test): `$SKILL_DIR/scripts/_test/test_collect_metrics.sh`

- [ ] **Step 1: 写失败的 fixture 测试**

创建 `$SKILL_DIR/scripts/_test/fixtures/output_pass.xml`（精简的 Robot Framework 输出，只保留 statistics）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<robot>
  <statistics>
    <total>
      <stat pass="18" fail="2" skip="0">All Tests</stat>
    </total>
  </statistics>
</robot>
```

创建 `$SKILL_DIR/scripts/_test/fixtures/timing.txt`：

```
start_epoch=1000
end_epoch=1842
```

创建 `$SKILL_DIR/scripts/_test/test_collect_metrics.sh`：

```bash
#!/usr/bin/env bash
# Local smoke test for collect_metrics.sh — runnable on the dev machine
# (no acpx / glab). Builds a throwaway LOG_DIR + OUTPUT_DIR from fixtures.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
LOG_DIR="${TMP}/log"; OUTPUT_DIR="${TMP}/out"
mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}/hulat-spec-issue14"
cp "${HERE}/fixtures/timing.txt"     "${LOG_DIR}/timing.txt"
cp "${HERE}/fixtures/output_pass.xml" "${OUTPUT_DIR}/hulat-spec-issue14/output.xml"

# collect_metrics.sh sources env_paths.sh which needs the full trigger env.
# To keep this an ISOLATED unit test we bypass env_paths by exporting the
# few vars collect_metrics actually consumes and stubbing the source line:
out="$(LOG_DIR="${LOG_DIR}" OUTPUT_DIR="${OUTPUT_DIR}" ISSUE_IID=14 ATTEMPT_NUMBER=3 MODEL=pro \
  COLLECT_METRICS_SKIP_ENV_PATHS=1 bash "${SCRIPTS}/collect_metrics.sh")"

mf="${LOG_DIR}/metrics.json"
[ -f "${mf}" ] || { echo "FAIL: metrics.json not written"; exit 1; }
wall="$(jq -r '.wall_clock_seconds' "${mf}")"
passed="$(jq -r '.accuracy.passed' "${mf}")"
rate="$(jq -r '.accuracy.pass_rate' "${mf}")"
[ "${wall}" = "842" ]   || { echo "FAIL: wall=${wall} expected 842"; exit 1; }
[ "${passed}" = "18" ]  || { echo "FAIL: passed=${passed} expected 18"; exit 1; }
[ "${rate}" = "0.9" ]   || { echo "FAIL: pass_rate=${rate} expected 0.9"; exit 1; }
echo "PASS test_collect_metrics"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash $SKILL_DIR/scripts/_test/test_collect_metrics.sh`
Expected: 非零退出，报 `collect_metrics.sh: No such file or directory`（脚本还没建）。

- [ ] **Step 3: 实现 `collect_metrics.sh`**

创建 `$SKILL_DIR/scripts/collect_metrics.sh`：

```bash
#!/usr/bin/env bash
# collect_metrics.sh — BEST-EFFORT observation script. Writes ${LOG_DIR}/metrics.json
# with efficiency (wall_clock_seconds from ${LOG_DIR}/timing.txt) and accuracy
# (robot pass rate parsed from Robot Framework output.xml under ${OUTPUT_DIR}).
#
# It NEVER fails the attempt: missing/garbled inputs → the relevant field is
# null / available:false and the script still exits 0. This is a DELIBERATE
# exception to the strict no-fallback policy because metrics are observational,
# not a work product. Only a genuine bash/IO fault (e.g. unwritable LOG_DIR)
# is fatal.
#
# Required env: LOG_DIR, OUTPUT_DIR, ISSUE_IID, ATTEMPT_NUMBER
# Optional env: MODEL (the pinned tier name)
#               COLLECT_METRICS_SKIP_ENV_PATHS=1  (unit-test escape hatch:
#                   skip sourcing env_paths.sh so the script can run from
#                   fixtures without the full trigger env)
#
# Output: writes ${LOG_DIR}/metrics.json and prints its path on stdout.

# NOTE: intentionally NOT `set -e` — best-effort. Keep -u/-o pipefail off too
# so a missing optional var never aborts.
set +e

if [ "${COLLECT_METRICS_SKIP_ENV_PATHS:-0}" != "1" ]; then
  # __source_env_paths_marker__ — bootstrap env from minimum trigger inputs.
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"
fi

: "${LOG_DIR:?collect_metrics: LOG_DIR required}"
: "${OUTPUT_DIR:?collect_metrics: OUTPUT_DIR required}"
: "${ISSUE_IID:?collect_metrics: ISSUE_IID required}"
: "${ATTEMPT_NUMBER:?collect_metrics: ATTEMPT_NUMBER required}"
MODEL="${MODEL:-}"

mkdir -p "${LOG_DIR}"
metrics_file="${LOG_DIR}/metrics.json"

# ── efficiency: wall_clock_seconds from timing.txt ───────────────────────────
wall="null"
timing="${LOG_DIR}/timing.txt"
if [ -f "${timing}" ]; then
  s="$(sed -n 's/^start_epoch=//p' "${timing}" | head -n1)"
  e="$(sed -n 's/^end_epoch=//p'   "${timing}" | head -n1)"
  case "${s}${e}" in
    ''|*[!0-9]*) : ;;                       # non-numeric → leave null
    *) [ "${e}" -ge "${s}" ] && wall="$(( e - s ))" ;;
  esac
fi

# ── accuracy: robot pass rate from Robot Framework output.xml ─────────────────
acc_json='{"available":false}'
if command -v python3 >/dev/null 2>&1; then
  parsed="$(python3 - "${OUTPUT_DIR}" <<'PY'
import sys, os, json, glob
import xml.etree.ElementTree as ET
out_dir = sys.argv[1]
files = glob.glob(os.path.join(out_dir, "**", "output.xml"), recursive=True)
passed = failed = skipped = 0
found = False
for f in files:
    try:
        root = ET.parse(f).getroot()
    except Exception:
        continue
    stat = None
    for s in root.findall("./statistics/total/stat"):
        stat = s  # the LAST total/stat is Robot Framework's "All Tests" row
    if stat is None:
        continue
    found = True
    passed  += int(stat.get("pass", 0) or 0)
    failed  += int(stat.get("fail", 0) or 0)
    skipped += int(stat.get("skip", 0) or 0)
if not found:
    print(json.dumps({"available": False}))
else:
    denom = passed + failed
    rate = round(passed / denom, 4) if denom else None
    print(json.dumps({"available": True, "passed": passed, "failed": failed,
                      "skipped": skipped, "total": passed + failed + skipped,
                      "pass_rate": rate, "robot_files": len(files)}))
PY
)"
  if [ -n "${parsed}" ] && echo "${parsed}" | jq -e . >/dev/null 2>&1; then
    acc_json="${parsed}"
  fi
fi

# ── assemble metrics.json ─────────────────────────────────────────────────────
jq -nc \
  --argjson iid "${ISSUE_IID}" \
  --argjson attempt "${ATTEMPT_NUMBER}" \
  --arg model "${MODEL}" \
  --argjson wall "${wall}" \
  --argjson accuracy "${acc_json}" \
  '{iid:$iid, attempt_number:$attempt,
    model:(if $model=="" then null else $model end),
    wall_clock_seconds:$wall,
    accuracy:$accuracy}' > "${metrics_file}"

echo "${metrics_file}"
exit 0
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash $SKILL_DIR/scripts/_test/test_collect_metrics.sh`
Expected: `PASS test_collect_metrics`

- [ ] **Step 5: 语法检查 + 缺数据降级冒烟**

Run: `bash -n $SKILL_DIR/scripts/collect_metrics.sh`
Run（删掉 fixtures 模拟缺 output.xml，断言 `accuracy.available=false` 且退出 0）：
```bash
TMP=$(mktemp -d); mkdir -p "$TMP/log" "$TMP/out"
LOG_DIR="$TMP/log" OUTPUT_DIR="$TMP/out" ISSUE_IID=1 ATTEMPT_NUMBER=1 \
  COLLECT_METRICS_SKIP_ENV_PATHS=1 bash $SKILL_DIR/scripts/collect_metrics.sh
jq -r '.accuracy.available, .wall_clock_seconds' "$TMP/log/metrics.json"; rm -rf "$TMP"
```
Expected: 打印 `false` 和 `null`，退出码 0。

- [ ] **Step 6: bump SKILL_VERSION 并提交**

读 `SKILL.md` 第 3 行，按 `2026-06-10.N` 规则改 `[SKILL_VERSION=...]`。
```bash
git add $SKILL_DIR/scripts/collect_metrics.sh $SKILL_DIR/scripts/_test/ $SKILL_DIR/SKILL.md
git commit  # 用 git-commit-chinese skill，中文提交信息
```

---

## Task 2: `run_acpx_attempt.sh` 写 `timing.txt`（效率掐表）

**Files:**
- Modify: `$SKILL_DIR/scripts/run_acpx_attempt.sh`（锚点：`mkdir -p "${LOG_DIR}"` 在第 64 行；acpx 启动在 139–144；`wait` 在 153；`cleanup()` 在 121–135）

- [ ] **Step 1: 在 acpx 启动前写 start_epoch**

在第 98 行 `cd "${WORKTREE_DIR}"` 之后、第 100 行注释之前插入：
```bash
# Benchmark efficiency stamp: record wall-clock start before acpx launches.
# collect_metrics.sh reads timing.txt to compute wall_clock_seconds.
printf 'start_epoch=%s\n' "$(date +%s)" > "${LOG_DIR}/timing.txt"
```

- [ ] **Step 2: 正常返回路径写 end_epoch**

在第 154 行 `acpx_exit=$?` 之后插入：
```bash
printf 'end_epoch=%s\n' "$(date +%s)" >> "${LOG_DIR}/timing.txt"
```

- [ ] **Step 3: timeout/cleanup 路径也写 end_epoch**

在 `cleanup()` 函数体内、第 134 行 `exit 124` 之前插入：
```bash
  printf 'end_epoch=%s\n' "$(date +%s)" >> "${LOG_DIR}/timing.txt" 2>/dev/null || true
```

- [ ] **Step 4: 语法检查**

Run: `bash -n $SKILL_DIR/scripts/run_acpx_attempt.sh`
Expected: 无输出，退出 0。

- [ ] **Step 5: bump SKILL_VERSION 并提交**（同 Task 1 Step 6 模式）

---

## Task 3: `stage_and_guard.sh` 全量入库

**Files:**
- Modify: `$SKILL_DIR/scripts/stage_and_guard.sh`（锚点：continue-mode 的 `git reset -- log/` 在 58–66；两文件 force-add 循环在 88–92）

- [ ] **Step 1: 移除 continue-mode 的 log 子树 reset**

`benchmark-test` 强制 fresh、每 attempt 独立分支，不存在「prior-attempt log 被覆盖」问题；且全量留档要求 `log/` 全部入库。删除第 58–66 行整段（从注释 `# In continue mode the worktree is checked out...` 到 `git reset -q -- "${RESULT_BASENAME}/issue-${ISSUE_IID}/log/" 2>/dev/null || true`）。

- [ ] **Step 2: 把两文件 force-add 改成整 LOG_DIR force-add**

把第 83–92 行（注释 + `for log_file in ... prompt.txt claude_result.txt ... git add -f` 循环）替换为：
```bash
# eval mode: force-add the ENTIRE attempt log dir so every artifact
# (acpx_raw.log, git_diff.patch, acpx_command.txt, timing.txt, metrics.json,
# prompt.txt, claude_result.txt) lands in the per-attempt branch for
# benchmarking. The ${RESULT_BASENAME}/ line in .git/info/exclude would
# otherwise hide all of it; -f bypasses that.
if [ -d "${LOG_DIR}" ] && [ -n "$(find "${LOG_DIR}" -type f -print -quit)" ]; then
  git add -f "${LOG_DIR}"
fi
```

- [ ] **Step 3: 语法检查 + 评审锚点**

Run: `bash -n $SKILL_DIR/scripts/stage_and_guard.sh`
人工确认：删除守卫（第 47–54、68–75 的 deleted-paths 检查）仍在，未被本次改动破坏。

- [ ] **Step 4: bump SKILL_VERSION 并提交**

---

## Task 4: `commit_and_push.sh` 推 per-attempt 不可变分支

**Files:**
- Modify: `$SKILL_DIR/scripts/commit_and_push.sh`（锚点：force-push 在 32–39，使用 `LOCAL_ATTEMPT_BRANCH` / `WORK_BRANCH`）

- [ ] **Step 1: 在 force-push WORK_BRANCH 之外，新增 per-attempt 不可变分支推送**

在第 39 行（`fi` 关闭 force-push 分支）之后、第 41 行 `git rev-parse HEAD` 之前插入：
```bash
# eval mode: also push an IMMUTABLE per-attempt remote branch so every attempt
# (= every pinned model run) is preserved and never overwritten. LOCAL_ATTEMPT_BRANCH
# is "issue/<iid>-auto-fix-att<NNN>" (unique per attempt); push it to the same
# name on the remote (NOT force — it must never already exist for a fresh attempt).
git push origin "${LOCAL_ATTEMPT_BRANCH}:${LOCAL_ATTEMPT_BRANCH}"
```

> 注：阶段一保留 `WORK_BRANCH` force-push（无害的「最新指针」）；阶段二确认无消费者后移除。

- [ ] **Step 2: 语法检查**

Run: `bash -n $SKILL_DIR/scripts/commit_and_push.sh`
Expected: 无输出。

- [ ] **Step 3: bump SKILL_VERSION 并提交**

---

## Task 5: 新增 `pin_model_tier` 触发字段（parse / validate / 必填）

**Files:**
- Modify: `$SKILL_DIR/scripts/dispatch_prepare_tick.sh`（锚点：`model_upgrade_continue_threshold` parse 在 527–532；统一 jq 状态写入在 534–601，新字段绑定加进去）

- [ ] **Step 1: 解析 + 校验 + 必填**

在第 532 行（`MODEL_CONTINUE_THRESHOLD` 校验块的 `fi`）之后插入：
```bash
# pin_model_tier (eval branch): the operator-pinned model tier for THIS tick.
# REQUIRED on benchmark-test — without it there is nothing to benchmark and we
# refuse to fall back to the (now-removed-in-spirit) escalation ladder.
# Per-tick, NOT carry-forward. Membership in the EFFECTIVE tier list is checked
# later in the per-IID resolve block (where EFFECTIVE_TIERS_CSV is known); here
# we only enforce presence + a safe label-segment charset.
PIN_MODEL_TIER="${T[pin_model_tier]:-}"
if [ -z "${PIN_MODEL_TIER}" ]; then
  emit_chat_failure "pin_model_tier_required: benchmark-test requires an explicit pin_model_tier on every tick"
fi
case "${PIN_MODEL_TIER}" in
  *[!A-Za-z0-9_.-]*) emit_chat_failure "invalid_pin_model_tier: must match [A-Za-z0-9_.-]+" ;;
esac
export PIN_MODEL_TIER
```

- [ ] **Step 2: 把 pin 快照写进 campaign_state.json（便于审计/回调一致性）**

在第 558 行 `--arg model_settings_dir "${MODEL_SETTINGS_DIR}" \` 之后插入一行绑定：
```bash
  --arg pin_model_tier "${PIN_MODEL_TIER}" \
```
在 jq body 的 `model_settings_dir: $model_settings_dir,`（约第 569 行）之后插入：
```bash
    pin_model_tier: $pin_model_tier,
```

- [ ] **Step 3: 语法检查**

Run: `bash -n $SKILL_DIR/scripts/dispatch_prepare_tick.sh`
Expected: 无输出。

- [ ] **Step 4: bump SKILL_VERSION 并提交**

---

## Task 6: pin 绕过升档阶梯 + 强制 fresh

**Files:**
- Modify: `$SKILL_DIR/scripts/dispatch_prepare_tick.sh`（锚点：mode 决策 1226–1238；resolve_model_tier 内联块 1240–1343，其中 `MODEL`/`MODEL_TIER_LABEL` 在 1342–1343）

- [ ] **Step 1: 强制 fresh**

在第 1238 行（`fi` 关闭 continue 判定）之后插入：
```bash
  # eval branch: every attempt runs FRESH from the clean DEV_BRANCH baseline so
  # different pinned models are compared on identical inputs. continue/resume is
  # disabled here (the `continue` label is ignored for mode selection).
  ISSUE_MODE="fresh"
```

- [ ] **Step 2: pin 短路升档逻辑**

把升档主体（第 1271 行 `MODEL_TIERS_ARR_JSON=...` 到第 1343 行 `MODEL="..."`）整体包进 `if PIN else <原逻辑> fi`。即在第 1271 行之前插入：
```bash
  if [ -n "${PIN_MODEL_TIER:-}" ]; then
    # PINNED: model chosen by the operator. Bypass the entire hard/soft upgrade
    # ladder AND the monotonic-raise invariant. set_issue_label.sh's model:*
    # mutual exclusion clears any other model:<tier> in the same update, so
    # pinning a LOWER tier than the issue's current label works (no monotonic
    # constraint). EFFECTIVE_TIERS_CSV was derived at the top of the tick.
    case ",${EFFECTIVE_TIERS_CSV}," in
      *",${PIN_MODEL_TIER},"*) ;;
      *) prep_blocked "pin_model_tier '${PIN_MODEL_TIER}' not in effective tiers (${EFFECTIVE_TIERS_CSV})"; continue ;;
    esac
    MODEL="${PIN_MODEL_TIER}"
    MODEL_TIER_LABEL="model:${PIN_MODEL_TIER}"
    CONSUME_QUALITY_LOW=false
    # Also set NEW_TIER to the pinned tier's 0-based index so the cached integer
    # model_tier written into issue state.json (the `model_tier:$model_tier`
    # binding in the issue-state init below) stays consistent with the pin and
    # does not leak a stale value from a prior loop iteration. Membership was
    # just confirmed above, so grep always matches.
    NEW_TIER="$(printf '%s' "${EFFECTIVE_TIERS_CSV}" | tr ',' '\n' | grep -nxF "${PIN_MODEL_TIER}" | head -n1 | cut -d: -f1)"
    NEW_TIER=$(( NEW_TIER - 1 ))
  else
```
并在第 1343 行（`MODEL="$(printf '%s' "${MODEL_TIERS_ARR_JSON}" | jq -r --argjson k "${NEW_TIER}" '.[$k]')"`）之后插入闭合：
```bash
  fi
```

> 缩进：`else` 分支内原有代码保持原缩进即可（bash 不计缩进）；只要 `if/else/fi` 配对正确。

- [ ] **Step 3: 语法检查**

Run: `bash -n $SKILL_DIR/scripts/dispatch_prepare_tick.sh`
Expected: 无输出（重点验证 if/else/fi 配对）。

- [ ] **Step 4: bump SKILL_VERSION 并提交**

---

## Task 7: executor prompt —— Step 1.5 采指标、跳过 MR/pr、回执带 metrics

**Files:**
- Modify: `$SKILL_DIR/references/executor_prompt.md`（锚点：Step 1 结束于 ~203；Step 2 在 205；Step 6 在 247–261；Step 7 在 263–287；Step 8 在 289–299；Step 10 reply JSON 在 320）

- [ ] **Step 1: 插入 Step 1.5（采集指标）**

在第 204 行（Step 1 末尾空行）与第 205 行 `Step 2 — STAGE` 之间插入：
```
Step 1.5 — COLLECT METRICS (best-effort; MUST NOT fail the attempt)
  Run exactly: bash {SCRIPTS_DIR}/collect_metrics.sh
  This writes {LOG_DIR}/metrics.json (efficiency = wall-clock seconds; accuracy =
  Robot Framework pass rate). If it exits non-zero OR metrics.json is absent,
  NOTE it and CONTINUE to Step 2 — metrics are observational and must never block
  staging / commit / push. Read {LOG_DIR}/metrics.json (or treat as {} if missing)
  and keep its JSON object for Step 10's `metrics` field.

```

- [ ] **Step 2: Step 6 标注为终态成功**

在第 247 行 `Step 6 — TRANSITION doing → done` 的步骤体里（紧跟标题行后）补一句说明：
```
  On the benchmark-test branch `done` is the TERMINAL SUCCESS label — there is no
  MR and no `pr`. Steps 7 and 8 are removed below; go straight from here to Step 9.
```

- [ ] **Step 3: 移除 Step 7（create MR）与 Step 8（add pr）的动作体**

把第 263–287 行 `Step 7 — CREATE / rotate the MR` 整步体替换为：
```
Step 7 — (REMOVED on benchmark-test)
  No merge request is created. Evaluation runs are never merged. Skip to Step 9.
```
把第 289–299 行 `Step 8 — ADD ``pr`` label` 整步体替换为：
```
Step 8 — (REMOVED on benchmark-test)
  No `pr` label. `done` from Step 6 is the terminal success label. Skip to Step 9.
```

- [ ] **Step 4: Step 10 reply 加 `metrics` 字段并修正 done 标签语义**

把第 320 行的 compact JSON 模板末尾 `..."log_dir":"{LOG_DIR}"}` 改为在 `log_dir` 后追加 `metrics`：
```
...,"log_dir":"{LOG_DIR}","metrics":<contents of {LOG_DIR}/metrics.json, or {} if absent>}
```
并把 `labels_added / labels_removed` 规则里关于 done 的那条（约第 327 行）从：
```
  - labels_added / labels_removed: ... For done: ["pr"] added, ["doing","done"] removed (pr replaces the transient done). ...
```
改为：
```
  - labels_added / labels_removed: the actual transitions you performed. For done (terminal success on this branch): ["done"] added, ["doing"] removed. There is no `pr` on benchmark-test. For blocked before `done`: ["blocked-cc"] added, ["doing"] removed. For timeout: ["timeout"] added, ["doing"] removed.
```
并把 `mr_action` 规则补一句：benchmark-test 上 `mr_action` 恒为 `"none"`、`merge_request_url` 恒为 `""`。

- [ ] **Step 5: 校验 end-sentinel 完好**

Run（确认渲染终止哨兵仍在最后一行）：
```bash
grep -n 'ACPX_AUTO_TESTER_EXECUTOR_PROMPT_V1_END' $SKILL_DIR/references/executor_prompt.md
```
Expected: 命中一行，且仍是 fenced block 内最后一行（编辑未误删）。

- [ ] **Step 6: bump SKILL_VERSION 并提交**

---

## Task 8: 回执 schema 加 `metrics` + Phase 6 写 ledger + done 不补 pr

**Files:**
- Modify: `$SKILL_DIR/references/state_schema.md`（compact reply schema 328–348、字段表 352–369）
- Modify: `$SKILL_DIR/scripts/_dispatch_lib.sh`（`phase6_sync_labels` done 分支 ~328–331；`phase6_write_state_files` 写完 state.json 后 ~489–491）

- [ ] **Step 1: state_schema 文档加 metrics 字段**

在 schema JSON（第 346 行 `"log_dir": ...`）之后加一行：
```
,
  "metrics": {"iid":14,"attempt_number":3,"model":"pro","wall_clock_seconds":842,"accuracy":{"available":true,"passed":18,"failed":2,"skipped":0,"total":20,"pass_rate":0.9,"robot_files":5}}
```
在字段表（第 369 行 `log_dir` 行）之后加一行：
```
| `metrics`            | object/absent   | Benchmark metrics from `collect_metrics.sh` (`wall_clock_seconds`, `accuracy.{available,passed,failed,pass_rate,...}`). Best-effort: may be `{}` or absent. Phase 6 appends it to the benchmark ledger. |
```

- [ ] **Step 2: `phase6_sync_labels` 的 done 分支不再补 pr**

把 `_dispatch_lib.sh` 第 328–331 行：
```bash
    done)
      # pr replaces done: add pr last so the issue ends with only `pr`.
      _label_op "${iid}" remove doing || rc=$?
      _label_op "${iid}" add pr       || rc=$?
```
改为：
```bash
    done)
      # eval branch: `done` is the terminal success label; MR/pr flow removed.
      _label_op "${iid}" remove doing || rc=$?
      _label_op "${iid}" add done     || rc=$?
```

- [ ] **Step 3: `phase6_write_state_files` 末尾 append ledger**

在 `_dispatch_lib.sh` 第 489 行（`state.json` 的 `atomic_write_json "${issue_state_file}"`）之后、第 491 行 `echo "${new_retry_count}"` 之前插入：
```bash
  # ─── benchmark metrics ledger (append-only) ───
  # The compact reply may carry a `metrics` object (collect_metrics.sh). Append
  # one line per terminal attempt so aggregate_benchmark.sh builds the
  # issue × model matrix without depending on per-attempt branches. Best-effort:
  # a write failure NEVER fails the callback.
  local _metrics
  _metrics="$(printf '%s' "${reply}" | jq -c '.metrics // null' 2>/dev/null || echo null)"
  if [ "${_metrics}" != "null" ] && [ -n "${_metrics}" ]; then
    local _ledger_dir="${RESULT_ROOT}/_dispatcher/benchmark"
    mkdir -p "${_ledger_dir}" 2>/dev/null || true
    printf '%s' "${_metrics}" | jq -c \
      --argjson iid "${iid}" --argjson att "${attempt_number}" \
      --arg status "${final_status}" --arg ts "${now}" \
      '. + {iid:$iid, attempt_number:$att, status:$status, ts:$ts}' \
      >> "${_ledger_dir}/metrics.jsonl" 2>/dev/null || true
  fi
```

> `RESULT_ROOT` 由 `env_paths.sh` 导出，`dispatch_followup.sh` 已 source，函数内可见。

- [ ] **Step 4: 语法检查**

Run: `bash -n $SKILL_DIR/scripts/_dispatch_lib.sh`
Expected: 无输出。

- [ ] **Step 5: bump SKILL_VERSION 并提交**

---

## Task 9: 新增 `aggregate_benchmark.sh`（issue × model 矩阵）

**Files:**
- Create: `$SKILL_DIR/scripts/aggregate_benchmark.sh`
- Create (test): `$SKILL_DIR/scripts/_test/test_aggregate_benchmark.sh`, fixture `$SKILL_DIR/scripts/_test/fixtures/metrics.jsonl`

- [ ] **Step 1: 写失败的 fixture 测试**

`$SKILL_DIR/scripts/_test/fixtures/metrics.jsonl`：
```
{"iid":14,"attempt_number":1,"model":"flash","wall_clock_seconds":620,"accuracy":{"available":true,"pass_rate":0.75},"status":"done","ts":"2026-06-10T01:00:00Z"}
{"iid":14,"attempt_number":2,"model":"pro","wall_clock_seconds":842,"accuracy":{"available":true,"pass_rate":0.9},"status":"done","ts":"2026-06-10T02:00:00Z"}
{"iid":15,"attempt_number":1,"model":"flash","wall_clock_seconds":500,"accuracy":{"available":false},"status":"done","ts":"2026-06-10T03:00:00Z"}
```

`$SKILL_DIR/scripts/_test/test_aggregate_benchmark.sh`：
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
out="$(LEDGER_FILE="${HERE}/fixtures/metrics.jsonl" bash "${SCRIPTS}/aggregate_benchmark.sh")"
echo "${out}"
echo "${out}" | grep -q "flash" || { echo "FAIL: no flash column"; exit 1; }
echo "${out}" | grep -q "pro"   || { echo "FAIL: no pro column"; exit 1; }
echo "${out}" | grep -q "#14"   || { echo "FAIL: no issue 14 row"; exit 1; }
echo "${out}" | grep -q "90%"   || { echo "FAIL: pro pass_rate 90% missing"; exit 1; }
echo "${out}" | grep -q "n/a"   || { echo "FAIL: unavailable accuracy not shown as n/a"; exit 1; }
echo "PASS test_aggregate_benchmark"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash $SKILL_DIR/scripts/_test/test_aggregate_benchmark.sh`
Expected: 非零，报脚本不存在。

- [ ] **Step 3: 实现 `aggregate_benchmark.sh`**

```bash
#!/usr/bin/env bash
# aggregate_benchmark.sh — read the benchmark metrics ledger and print an
# issue × model matrix (wall_clock_seconds / pass_rate) as markdown to stdout.
# For each (iid, model) the LATEST record wins.
#
# Env: LEDGER_FILE overrides the default ledger path (used by the unit test).
#      Otherwise env_paths.sh derives ${RESULT_ROOT}/_dispatcher/benchmark/metrics.jsonl.
set -euo pipefail

if [ -n "${LEDGER_FILE:-}" ]; then
  ledger="${LEDGER_FILE}"
else
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env_paths.sh"
  ledger="${RESULT_ROOT}/_dispatcher/benchmark/metrics.jsonl"
fi

if [ ! -f "${ledger}" ]; then
  echo "no benchmark ledger at ${ledger}" >&2
  exit 0
fi

jq -rs '
  (group_by([.iid, .model]) | map(.[-1])) as $rows
  | ($rows | map(.model) | unique) as $models
  | ($rows | map(.iid)   | unique | sort) as $iids
  | "# benchmark matrix (wall_clock_seconds / pass_rate)",
    "",
    ("| issue | " + ($models | join(" | ")) + " |"),
    ("|---|" + ($models | map("---") | join("|")) + "|"),
    ( $iids[] as $i
      | "| #\($i) | "
        + ( [ $models[] as $m
              | ( [ $rows[] | select(.iid==$i and .model==$m) ] | first ) as $r
              | if $r == null then "-"
                else "\($r.wall_clock_seconds)s / "
                     + ( if ($r.accuracy.available == true) and ($r.accuracy.pass_rate != null)
                         then "\(($r.accuracy.pass_rate * 100) | floor)%"
                         else "n/a" end )
                end
            ] | join(" | ") )
        + " |" )
' "${ledger}"
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash $SKILL_DIR/scripts/_test/test_aggregate_benchmark.sh`
Expected: 打印矩阵 + `PASS test_aggregate_benchmark`。

- [ ] **Step 5: 语法检查 + bump SKILL_VERSION 并提交**

Run: `bash -n $SKILL_DIR/scripts/aggregate_benchmark.sh`

---

## Task 10: 文档同步 + 触发字段说明 + 代码审查闭环

**Files:**
- Modify: `$SKILL_DIR/references/trigger_command.md`（字段表加 `pin_model_tier` 行，锚点：`model_tiers` 在第 67 行）
- Modify: `$SKILL_DIR/SKILL.md`（§Dispatcher Algorithm 增补 pin 分支 / 跳过 MR / Step 1.5 / ledger；终态 done）
- Modify: `statemachine.v2.md`（仓库根，非 workspace —— 记录 benchmark 偏离：pin 放宽单调、done 无 pr；**不触发 SKILL_VERSION bump**）

- [ ] **Step 1: trigger_command 加 `pin_model_tier` 字段行**

在第 67 行 `model_tiers` 行之后插入（对齐表格样式）：
```
| `pin_model_tier`            | **benchmark-test only, REQUIRED, per-tick (NOT carry-forward).** The model tier name (an element of `model_tiers`, and present in the EFFECTIVE tier set under `model_settings_dir`) that THIS tick pins for every batch IID. Bypasses the failure-escalation ladder and the `model:{tier}` monotonic-raise invariant entirely: the issue is stamped exactly `model:<pin_model_tier>` (down-shifts allowed via set_issue_label's model:* mutual exclusion). Missing → tick aborts with `"pin_model_tier_required"`. Bad charset → `"invalid_pin_model_tier"`. A value absent from the effective tiers marks that IID `blocked-dispatcher`. Used to sweep one issue across candidate models for benchmarking. |
```

- [ ] **Step 2: SKILL.md 增补**

在 §Dispatcher Algorithm 的 Phase 4 描述里增补：pin 分支取代 resolve_model_tier 升档、强制 fresh、subagent 新增 Step 1.5 调 `collect_metrics.sh`、跳过 Step 7/8、终态 `done`、Phase 6 append `metrics.jsonl`。具体增补点由实现者按 SKILL.md 现有结构插入（保持中文/英文风格一致）。

- [ ] **Step 3: statemachine.v2.md 记录偏离**

在 statemachine.v2.md 末尾追加一节「benchmark-test 分支偏离」：pin 放弃单调上升、`done` 为终态成功（无 `pr`）、continue 禁用（强制 fresh）、全量留档 + per-attempt 分支。

- [ ] **Step 4: bump SKILL_VERSION 并提交（含 trigger_command + SKILL.md；statemachine.v2.md 单独或同 commit 均可，但它不触发 bump）**

- [ ] **Step 5: 代码审查闭环（强制）**

Spawn `Agent(subagent_type="code-reviewer")`，prompt 传「review the uncommitted/committed changes on benchmark-test for the model-eval phase-1 改造」。按 §Code review workflow 最多 3 轮处理反馈。通过后写审查指纹清除 Stop hook：
```bash
printf %s '<current-diff-hash>' > .claude/.review-done-sha
```
（确切的 `printf` 行见 hook 的 reason 文本。）

---

## 验收（阶段一完成判据）

1. 对同一 issue 用 `pin_model_tier=flash/pro/max` 触发三轮，远端出现三个互不覆盖的 `issue/<iid>-auto-fix-att<NNN>` 分支，各含完整 `log/`（含 `metrics.json` / `acpx_raw.log`）。
2. `${RESULT_ROOT}/_dispatcher/benchmark/metrics.jsonl` 累积三条，每条含 `model` / `wall_clock_seconds` / `accuracy`。
3. `aggregate_benchmark.sh` 输出 `issue × model` 矩阵。
4. 评测不产生 MR、不打 `pr`；缺 `pin_model_tier` 触发即 abort `pin_model_tier_required`。
5. 两个本地 fixture 测试（`test_collect_metrics.sh` / `test_aggregate_benchmark.sh`）通过；所有改动脚本 `bash -n` 通过；code-reviewer 闭环通过。

## 外部依赖（实现期需测试团队确认，否则 accuracy 降级为 available:false）

- `executor.md` 产出的 Robot Framework `output.xml` 在 `OUTPUT_DIR` 下的真实相对路径（`collect_metrics.sh` 用 `**/output.xml` 递归匹配，路径不同也能命中，但需确认确实生成）。
- 候选模型清单：`model_settings_dir` 下各 `<tier>-settings.json` 对应的真实模型。
