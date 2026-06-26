# req_dispatcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 104 OpenClaw 上新建独立 agent `req_dispatcher`，作为企微需求接入点：接收 114 转发的自由文本需求，跨 agent 异步派发给 `git_issuer` 建 issue，被动衔接 `acpx_auto_tester` 既有 issue 流程。

**Architecture:** 复用 acpx 的 thick-orchestrator + 两路径异步回调骨架，但极简：无 worktree、无 glab、无 campaign_state。一个 SKILL 处理"接入路径"（自由文本需求→spawn git_issuer→记 pending→ack）与"回调路径"（git_issuer 完成→按 run_id 匹配 pending→drain，失败则记录+可选 ops 通知）。state 仅一张以 `run_id` 为主键的 pending 表（flock 保护）。

**Tech Stack:** OpenClaw agent workspace（Markdown 提示契约 SOUL/AGENTS/USER/CLAUDE + 一个 SKILL.md）、bash 脚本（flock + jq + date）、env 配置。无应用代码、无 pytest。

## Global Constraints

- 语言/契约文件用中文为主，技术字面量（命令、路径、字段名）保持原文。
- **不碰 glab/GitLab**：req_dispatcher 不建 issue、不打标签（git_issuer 打）。
- **不解析需求文本**：整段原样透传给 git_issuer（project 由 git_issuer 解析）。
- **不触发 acpx**：被动等 acpx cron tick；不追踪测试结果；不主动给企微用户回状态。
- pending **主键 = `run_id`**；`correlation_id` 仅为可选回显兜底（默认不用）。
- 脚本静态检查统一用 `/opt/homebrew/bin/bash -n`（本机 /bin/bash 3.2.57 会误判）。**不在本机跑 agent**。
- SKILL 带 `SKILL_VERSION=2026-06-25.N`；workspace 内改动同提交 bump。
- 所有 workspace 改动走 **code-review 子代理循环**（≤3 轮），收尾写 `.claude/.review-done-sha`。
- 脚本无 `Date.now()` 限制（那是 Workflow JS 沙箱的限制）；bash 用 `date -u +%s` 取时间戳没问题。
- spawn 失败重试：同 payload 3 次、2s 固定退避（沿用 acpx）。
- 设计依据：`docs/superpowers/specs/2026-06-25-req_dispatcher-design.md`（本计划的每个任务对应 spec 的小节）。

---

## File Structure

| 文件 | 职责 |
|------|------|
| `SOUL.md` | agent 灵魂：两路径职责、no-fallback、回调按 run_id 匹配、极简回状态、stuck 兜底 |
| `AGENTS.md` | 工作区说明、agent 身份 `agent:req_dispatcher:main`、两 trigger 执行模型、跨 agent 原语依赖 |
| `USER.md` | 使用契约：114 怎么调、ack 文案、git_issuer 契约指针、配置项 |
| `CLAUDE.md` | Claude Code 工作区指南 + 自包含 SKILL_VERSION bump 规则 + review 闸说明 |
| `config/dispatcher.env` | 部署期 pin：git_issuer agent 名、跨 agent 原语连接参数、可选 ops channel、可选默认入口标签、STATE_ROOT |
| `config/README.md` | 配置说明与部署步骤 |
| `skills/requirement_dispatch/SKILL.md` | 唯一 SKILL：两路径算法（含 SKILL_VERSION） |
| `skills/requirement_dispatch/references/trigger_command.md` | 两条 trigger 字段契约 + 跨 agent 原语/回调形态（占位待补） |
| `docs/integration/gitissuer_contract.md` | git_issuer 创建契约 + 回传模板（跨团队对接文档，非运行时 reference） |
| `docs/integration/gitissuer_change_request.md` | git_issuer 需求变更对接契约（跨团队对接文档） |
| `skills/requirement_dispatch/references/state_schema.md` | pending.json / ledger schema |
| `skills/requirement_dispatch/scripts/env_paths.sh` | 路径自举（每脚本顶部 source） |
| `skills/requirement_dispatch/scripts/record_pending.sh` | 接入路径：记一条 pending（flock） |
| `skills/requirement_dispatch/scripts/drain_pending.sh` | 回调路径：按 run_id 匹配 + drain + 写 ledger（flock） |
| `skills/requirement_dispatch/scripts/evict_stuck.sh` | 兜底：扫超时 pending → 合成失败 + drain（flock） |
| `.claude/settings.json` | 注册 Stop hook（review 闸） |
| `.claude/settings.local.json` | 本地权限（bash -n 等） |
| `.claude/hooks/require-workspace-review.sh` | Stop hook：未审查/未提交 workspace 改动时 block |

---

## Task 1: workspace 骨架 + .claude + config

**Files:**
- Create: `workspace-req_dispatcher/.claude/settings.json`
- Create: `workspace-req_dispatcher/.claude/settings.local.json`
- Create: `workspace-req_dispatcher/.claude/hooks/require-workspace-review.sh`
- Create: `workspace-req_dispatcher/config/dispatcher.env`
- Create: `workspace-req_dispatcher/config/README.md`

**Interfaces:**
- Produces: `STATE_ROOT`（默认 `/data/req_dispatcher`）、`GIT_ISSUER_AGENT`、可选 `OPS_NOTIFY_CHANNEL` / `DEFAULT_ENTRY_LABEL` 等 env 名，后续脚本/SKILL 引用。

- [ ] **Step 1: 写 `config/dispatcher.env`**

```bash
# req_dispatcher 部署期配置（pin）。group/project 不在此处——随需求文本传入，由 git_issuer 解析。
# 下游目标 agent
GIT_ISSUER_AGENT=git_issuer
# 运行时 state 根目录（pending.json / ledger / 锁 / 日志）
STATE_ROOT=/data/req_dispatcher
# 可选：失败通知 channel（留空则不通知）
OPS_NOTIFY_CHANNEL=
# 可选：若将来需要 req_dispatcher 向 git_issuer 显式指定 acpx 入口标签（默认空＝由 git_issuer 自决）
DEFAULT_ENTRY_LABEL=
# 跨 agent 调用原语连接参数：待 §10.1 对齐后补（如 gateway-url / token，如该原语需要）
```

- [ ] **Step 2: 写 `config/README.md`**

内容：解释每个字段；强调 group/project 不在此处；强调 STATE_ROOT 须是 server 上可写持久目录；跨 agent 原语参数对齐前留空。给出部署校验清单（目录可写、git_issuer agent 在线、原语参数已填）。

- [ ] **Step 3: 写 `.claude/hooks/require-workspace-review.sh`**

以 acpx 的 `workspace-acpx_auto_tester/.claude/hooks/require-workspace-review.sh` 为蓝本，改路径常量为 `workspace-req_dispatcher`，sentinel 为 `workspace-req_dispatcher/.claude/.review-done-sha`。先读 acpx 版逐行适配，不臆造。

- [ ] **Step 4: 写 `.claude/settings.json` 与 `settings.local.json`**

以 acpx 的两个 settings 为蓝本：`settings.json` 注册 Stop hook 指向上面的脚本；`settings.local.json` 放本地允许的命令（`/opt/homebrew/bin/bash -n ...` 等）。先读 acpx 版适配。

- [ ] **Step 5: 校验**

Run: `/opt/homebrew/bin/bash -n workspace-req_dispatcher/.claude/hooks/require-workspace-review.sh`
Expected: 无输出（语法 OK）。
Run: `python3 -c "import json;json.load(open('workspace-req_dispatcher/.claude/settings.json'));json.load(open('workspace-req_dispatcher/.claude/settings.local.json'));print('ok')"`
Expected: `ok`

- [ ] **Step 6: Checkpoint**（实际 git commit 推迟到用户要求；此处仅逻辑分段）

---

## Task 2: state 底座（schema + 三脚本）

**Files:**
- Create: `skills/requirement_dispatch/references/state_schema.md`
- Create: `skills/requirement_dispatch/scripts/env_paths.sh`
- Create: `skills/requirement_dispatch/scripts/record_pending.sh`
- Create: `skills/requirement_dispatch/scripts/drain_pending.sh`
- Create: `skills/requirement_dispatch/scripts/evict_stuck.sh`

**Interfaces:**
- Consumes: `STATE_ROOT`、`GIT_ISSUER_AGENT`（来自 dispatcher.env / env）。
- Produces: `pending.json` schema、`ledger.jsonl` 追加格式；脚本入参契约（见各脚本）。

- [ ] **Step 1: 写 `references/state_schema.md`**

定义：
```
pending.json  （主键 = run_id）
{
  "pending": {
    "<run_id>": {
      "child_session_key": "string|null",
      "correlation_id": "string|null",
      "spawned_at": 1719300000,        // epoch 秒
      "req_digest": "string"           // 需求前 N 字摘要，仅供人读/审计
    }
  }
}

ledger.jsonl  （每行一条终态记录，append-only）
{"run_id":"...","outcome":"success|failed|launch_failed|stuck_evicted","issue_iid":null|int,"issue_url":null|"...","reason":null|"...","drained_at":169...}
```
说明：pending 是唯一可变状态，flock 保护；ledger 仅审计。无 campaign_state。

- [ ] **Step 2: 写 `scripts/env_paths.sh`**

```bash
#!/usr/bin/env bash
# 路径自举：每个脚本顶部 `source` 本文件。要求 STATE_ROOT 在 env（dispatcher.env 提供，或调用方导出）。
set -euo pipefail

: "${STATE_ROOT:?STATE_ROOT is required (set in config/dispatcher.env or export before call)}"

DISPATCHER_DIR="${STATE_ROOT}/_dispatcher"
PENDING_FILE="${DISPATCHER_DIR}/pending.json"
LEDGER_FILE="${DISPATCHER_DIR}/ledger.jsonl"
SEQ_FILE="${DISPATCHER_DIR}/seq"
LOCK_FILE="${DISPATCHER_DIR}/pending.lock"
LOG_DIR="${DISPATCHER_DIR}/log"

export DISPATCHER_DIR PENDING_FILE LEDGER_FILE SEQ_FILE LOCK_FILE LOG_DIR

ensure_state_dirs() {
  mkdir -p "${DISPATCHER_DIR}" "${LOG_DIR}"
  [ -f "${PENDING_FILE}" ] || printf '%s\n' '{"pending":{}}' > "${PENDING_FILE}"
  [ -f "${LEDGER_FILE}" ] || : > "${LEDGER_FILE}"
}
```

- [ ] **Step 3: 写 `scripts/record_pending.sh`**

```bash
#!/usr/bin/env bash
# 接入路径：记一条 pending。入参（env）：RUN_ID(必), CHILD_SESSION_KEY?, CORRELATION_ID?, REQ_DIGEST?
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${RUN_ID:?RUN_ID required}"
CHILD_SESSION_KEY="${CHILD_SESSION_KEY:-}"
CORRELATION_ID="${CORRELATION_ID:-}"
REQ_DIGEST="${REQ_DIGEST:-}"
SPAWNED_AT="$(date -u +%s)"

exec 9>"${LOCK_FILE}"
flock 9
tmp="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
jq --arg rid "${RUN_ID}" \
   --arg csk "${CHILD_SESSION_KEY}" \
   --arg cid "${CORRELATION_ID}" \
   --arg dig "${REQ_DIGEST}" \
   --argjson ts "${SPAWNED_AT}" \
   '.pending[$rid] = {child_session_key:($csk|select(.!="")//null), correlation_id:($cid|select(.!="")//null), spawned_at:$ts, req_digest:$dig}' \
   "${PENDING_FILE}" > "${tmp}"
mv "${tmp}" "${PENDING_FILE}"
flock -u 9
printf 'recorded run_id=%s\n' "${RUN_ID}"
```

- [ ] **Step 4: 写 `scripts/drain_pending.sh`**

```bash
#!/usr/bin/env bash
# 回调路径：按 run_id 匹配 + drain + 写 ledger。入参（env）：
#   RUN_ID(必，主匹配键), OUTCOME(必: success|failed|launch_failed),
#   ISSUE_IID?, ISSUE_URL?, REASON?
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${RUN_ID:?RUN_ID required}"
: "${OUTCOME:?OUTCOME required}"
ISSUE_IID="${ISSUE_IID:-}"
ISSUE_URL="${ISSUE_URL:-}"
REASON="${REASON:-}"
DRAINED_AT="$(date -u +%s)"

exec 9>"${LOCK_FILE}"
flock 9
present="$(jq --arg rid "${RUN_ID}" 'if .pending[$rid] then "yes" else "no" end' "${PENDING_FILE}" -r)"
# 追加 ledger（即便 pending 已不在也记，便于审计重复回调）
jq -nc --arg rid "${RUN_ID}" --arg oc "${OUTCOME}" \
   --arg iid "${ISSUE_IID}" --arg url "${ISSUE_URL}" --arg rsn "${REASON}" \
   --argjson ts "${DRAINED_AT}" --arg present "${present}" \
   '{run_id:$rid, outcome:$oc, issue_iid:($iid|select(.!="")//null), issue_url:($url|select(.!="")//null), reason:($rsn|select(.!="")//null), drained_at:$ts, was_pending:($present=="yes")}' \
   >> "${LEDGER_FILE}"
tmp="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
jq --arg rid "${RUN_ID}" 'del(.pending[$rid])' "${PENDING_FILE}" > "${tmp}"
mv "${tmp}" "${PENDING_FILE}"
flock -u 9
printf 'drained run_id=%s outcome=%s was_pending=%s\n' "${RUN_ID}" "${OUTCOME}" "${present}"
```

- [ ] **Step 5: 写 `scripts/evict_stuck.sh`**

```bash
#!/usr/bin/env bash
# 兜底：扫超时 pending → 合成 stuck_evicted 写 ledger + 从 pending 删除。
# 入参（env）：STUCK_AFTER_MINUTES(必)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_paths.sh
source "${SCRIPT_DIR}/env_paths.sh"
ensure_state_dirs

: "${STUCK_AFTER_MINUTES:?STUCK_AFTER_MINUTES required}"
NOW="$(date -u +%s)"
CUTOFF=$(( NOW - STUCK_AFTER_MINUTES * 60 ))

exec 9>"${LOCK_FILE}"
flock 9
# 找出过期 run_id
mapfile -t expired < <(jq -r --argjson cutoff "${CUTOFF}" '.pending | to_entries[] | select(.value.spawned_at < $cutoff) | .key' "${PENDING_FILE}")
for rid in "${expired[@]}"; do
  jq -nc --arg rid "${rid}" --argjson ts "${NOW}" \
     '{run_id:$rid, outcome:"stuck_evicted", issue_iid:null, issue_url:null, reason:"no callback before stuck_after_minutes", drained_at:$ts, was_pending:true}' \
     >> "${LEDGER_FILE}"
done
if [ "${#expired[@]}" -gt 0 ]; then
  tmp="$(mktemp "${DISPATCHER_DIR}/pending.XXXXXX")"
  jq --argjson cutoff "${CUTOFF}" '.pending |= (to_entries | map(select(.value.spawned_at >= $cutoff)) | from_entries)' "${PENDING_FILE}" > "${tmp}"
  mv "${tmp}" "${PENDING_FILE}"
fi
flock -u 9
printf 'evicted %d stuck pending\n' "${#expired[@]}"
```

- [ ] **Step 6: 静态检查全部脚本**

Run: `for f in workspace-req_dispatcher/skills/requirement_dispatch/scripts/*.sh; do /opt/homebrew/bin/bash -n "$f" && echo "OK $f"; done`
Expected: 每个脚本 `OK ...`，无语法报错。

- [ ] **Step 7: Checkpoint**

---

## Task 3: SKILL.md 两路径算法 + references 契约

**Files:**
- Create: `skills/requirement_dispatch/SKILL.md`
- Create: `skills/requirement_dispatch/references/trigger_command.md`
- Create: `skills/requirement_dispatch/references/gitissuer_contract.md`

**Interfaces:**
- Consumes: Task 2 的三脚本入参契约 + state_schema。
- Produces: 两条 trigger 名（占位 `RUN_REQUIREMENT_INTAKE` / `RUN_GITISSUER_CALLBACK`，§10.1 对齐时以实际为准）、orchestrator 调用脚本的精确 env 行。

- [ ] **Step 1: 写 `SKILL.md`**

`description:` 内含 `[SKILL_VERSION=2026-06-25.1]`。正文写：
- 路径判定（结构化回调→回调路径；否则→接入路径）。
- 接入路径 5 步（spec §6）：取需求原文 → 跨 agent 异步 spawn git_issuer（payload `{requirement_text}`，可选 correlation_id）→ 失败 3 次退避→ launch_failed → 成功拿 run_id → `bash scripts/record_pending.sh`（给出精确 env 行：`STATE_ROOT=... RUN_ID=... CHILD_SESSION_KEY=... REQ_DIGEST=... bash scripts/record_pending.sh`）→ 回最小 ack → `waiting_for_callback`。
- 回调路径 5 步：解析 git_issuer 终态 → 按 run_id `bash scripts/drain_pending.sh`（精确 env 行，含 OUTCOME/ISSUE_IID/ISSUE_URL/REASON）→ 成功收尾/失败记录+可选 ops 通知。
- 兜底：接入路径开头先 `bash scripts/evict_stuck.sh`（精确 env 行）。
- §No-Fallback：不碰 glab、不解析 project、不触发 acpx、不去重、git_issuer 失败不自动重试。
- §Working Directory：每次 `cd "<SKILL_DIR 绝对路径>" && STATE_ROOT=... bash scripts/<name>.sh`（沿用 acpx 的"cd && env && bash 同一次 exec"铁律）。
- 跨 agent 原语调用形态指向 `references/trigger_command.md`。

- [ ] **Step 2: 写 `references/trigger_command.md`**

两条 trigger 字段契约 + **跨 agent 调用原语形态占位块**：显式标注"待对齐（§10.1）"，列出需要确认的点：工具名、如何指定 target=git_issuer、如何传 payload、如何拿 run_id/child_session_key、回调 trigger 名与字段（run_id / worker_result_json 在哪、git_issuer 终态如何承载）。给出"匹配以 run_id 为主、correlation_id 回显为兜底"的二选一确认清单。

- [ ] **Step 3: 写 `references/gitissuer_contract.md`**

git_issuer I/O 契约占位：入参字段（requirement_text 必，其它待定）、回调成功/失败表达、issue IID/URL 字段、git_issuer 是否负责解析 project 与打 acpx 入口标签。显式标注"与同事对齐"。

- [ ] **Step 4: 一致性核对**

核对：SKILL 里调用脚本的 env 变量名与 Task 2 脚本实际读取的变量名逐一对齐（RUN_ID/CHILD_SESSION_KEY/CORRELATION_ID/REQ_DIGEST/OUTCOME/ISSUE_IID/ISSUE_URL/REASON/STUCK_AFTER_MINUTES/STATE_ROOT）。列出并修正任何不一致。

- [ ] **Step 5: Checkpoint**

---

## Task 4: 提示契约 SOUL/AGENTS/USER/CLAUDE

**Files:**
- Create: `SOUL.md`, `AGENTS.md`, `USER.md`, `CLAUDE.md`（均在 `workspace-req_dispatcher/`）

**Interfaces:**
- Consumes: SKILL.md 两路径 + state_schema + 三脚本。
- Produces: agent 身份 `agent:req_dispatcher:main`；对外可读的使用契约。

- [ ] **Step 1: 写 `SOUL.md`**

灵魂：req_dispatcher 是薄派发器；两路径职责；no-fallback（同 SKILL）；回调按 run_id 匹配、对 git_issuer 零侵入；极简回状态（不主动回企微用户）；stuck 兜底；Global Rules（不碰 GitLab、不解析、不触发 acpx、不去重）。指针指向 SKILL 与 references。**不要照搬 acpx 的 worktree/UI 账号/campaign 段落**——那些在本 agent 不存在。

- [ ] **Step 2: 写 `AGENTS.md`**

工作区说明：唯一 SKILL `requirement_dispatch`；agent 身份与 orchestrator session `agent:req_dispatcher:main`；两 trigger 执行模型；跨 agent 原语依赖（指向 trigger_command.md）；state 布局（STATE_ROOT 下 pending.json/ledger.jsonl）；Deployment pin（dispatcher.env）。

- [ ] **Step 3: 写 `USER.md`**

使用契约：114 如何调（`agent run --agent req_dispatcher "<需求原文>" --deliver`）；ack 文案（如"需求已受理，正在创建 issue；结果将由后续流程通知"）；git_issuer 契约指针；配置项指针；强调 project 写在需求文本里。

- [ ] **Step 4: 写 `CLAUDE.md`**

Claude Code 工作区指南：本工作区是什么、不在本机跑、bash -n 用 homebrew、code-review 子代理循环、**自包含 SKILL_VERSION bump 规则**（`2026-06-25.N`，同提交 bump）、Stop hook 说明、where-to-look 指针。

- [ ] **Step 5: 一致性核对**

跨 SOUL/AGENTS/USER/CLAUDE/SKILL 核对：agent 名、session 名、trigger 名、脚本路径、字段名一致；无残留 acpx 专有概念（worktree/glab/UI 账号/campaign_state/model tier）误入。

- [ ] **Step 6: Checkpoint**

---

## Task 5: 收口（静态检查 + code-review 循环 + 版本/sentinel）

**Files:**
- Modify: `skills/requirement_dispatch/SKILL.md`（如 review 有改动则 bump SKILL_VERSION）
- Create: `workspace-req_dispatcher/.claude/.review-done-sha`（收尾 sentinel）

- [ ] **Step 1: 全量静态检查**

Run: `for f in $(find workspace-req_dispatcher -name '*.sh'); do /opt/homebrew/bin/bash -n "$f" && echo "OK $f"; done`
Expected: 全部 OK。
Run: `for j in workspace-req_dispatcher/.claude/settings.json workspace-req_dispatcher/.claude/settings.local.json; do python3 -c "import json,sys;json.load(open(sys.argv[1]));print('ok',sys.argv[1])" "$j"; done`
Expected: 全部 ok。

- [ ] **Step 2: code-review 子代理循环（≤3 轮）**

Dispatch `Agent(subagent_type="code-reviewer")`，prompt 指明 diff 范围（`workspace-req_dispatcher/` 全部新文件），检查：脚本正确性/flock 原子性/jq 用法/no-fallback 一致性/跨文件契约一致性/有无误入 acpx 专有概念。按反馈修正，重跑直到零问题或满 3 轮。

- [ ] **Step 3: 若 review 改动了 workspace 文件 → bump SKILL_VERSION**

将 `SKILL.md` 的 `[SKILL_VERSION=2026-06-25.N]` 自增 N。

- [ ] **Step 4: 写 review sentinel 解 Stop hook（若本会话 hook 生效）**

按 hook reason 输出的 `printf %s '<hash>' > <sentinel>` 指令写入 `.claude/.review-done-sha`。

- [ ] **Step 5: 汇报 + 询问是否 commit**

向用户汇报完成情况与 §10 待对齐项；按全局规则，**等用户确认再 git commit**。

---

## Self-Review（对照 spec）

- **Spec §3 范围/边界** → Task 1（config 不含 project）+ Task 3/4（no-fallback 段落）。
- **Spec §5 目录结构** → Task 1/2/3/4 文件清单逐一覆盖。
- **Spec §6 两路径算法** → Task 3 SKILL.md。
- **Spec §7 状态并发** → Task 2 schema + 三脚本 + Task 3 兜底调用。
- **Spec §8 错误处理** → Task 2 drain/evict + Task 3 SKILL no-fallback。
- **Spec §9 config** → Task 1 dispatcher.env。
- **Spec §10 待对齐契约** → Task 3 references 占位块。
- **Spec §11 acpx 衔接依赖** → 记入 AGENTS.md/CLAUDE.md（Task 4）。
- **Spec §12 测试运维** → Task 1 hook/settings + Task 5 review 循环。
- **类型/字段一致性** → Task 3 Step 4 + Task 4 Step 5 双重核对脚本 env 变量名。
