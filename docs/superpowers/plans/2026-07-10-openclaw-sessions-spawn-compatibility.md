# OpenClaw 子代理派发兼容性实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `workspace-acpx_auto_tester`、`workspace-req_executor` 与 `workspace-req_dispatcher` 的运行契约兼容 OpenClaw 2026.6.11，并彻底移除 `run_timeout_seconds` 这一逐次运行上限接口。

**Architecture:** 两个直接派发子代理的工作区统一把 `spawn_payload.txt` 内容作为 `sessions_spawn.task`，只传当前工具支持的匿名 run-mode 参数。内部 acpx 仍由 `acpx_timeout_seconds` 限时，stuck 默认值改为从该内部预算派生；旧状态只做删除迁移，旧 trigger 字段明确拒绝。`req_dispatcher` 继续使用合法的 `openclaw agent --timeout`，只同步跨工作区文档边界。

**Tech Stack:** Bash、jq、GNU coreutils、ripgrep、Markdown、OpenClaw 2026.6.11

## Global Constraints

- `sessions_spawn` 的任务正文参数必须是 `task`，不得使用 `payload` 参数名。
- `sessions_spawn` 不得逐次传入 `timeoutSeconds` 或 `runTimeoutSeconds`。
- `runtime="subagent"`、`mode="run"`、`cleanup="keep"`、`context="isolated"` 与 `label` 必须显式固定。
- `run_timeout_seconds` 不再是 trigger、状态或 envelope 字段；旧 trigger 明确拒绝，旧状态仅删除迁移。
- `agents.defaults.subagents.runTimeoutSeconds` 为可选部署配置，缺失或为 `0` 均不得阻断任务。
- `stuck_after_minutes` 缺省值必须为 `ceil((acpx_timeout_seconds + 120) / 60) + 30`。
- 不修改 tracked 蓝区 GitLab 地址、令牌注入契约、`/data` clone root、回调目标或持久化根目录。
- 不删除或改写 `workspace-req_dispatcher` 的 `openclaw agent --timeout` 行为。
- 不运行 `rm`；测试临时目录沿用现有 trap／系统清理模式，不新增 shell 删除命令。
- 三个工作区的技能版本都更新为 `SKILL_VERSION=2026-07-10.1`。

---

### Task 1: 修复 `workspace-acpx_auto_tester` 子代理派发与 timeout 状态

**Files:**
- Create: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/tests/test_openclaw_spawn_contract.sh`
- Create: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/tests/test_timeout_state_migration.sh`
- Modify: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md`
- Modify: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh`
- Modify: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_prepare_tick.sh`
- Modify: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_followup.sh`
- Modify: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/dispatcher_wrappers.md`
- Modify: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md`
- Modify: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/state_schema.md`
- Modify: `workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`
- Modify: `workspace-acpx_auto_tester/CLAUDE.md`
- Modify: `workspace-acpx_auto_tester/SOUL.md`
- Modify: `workspace-acpx_auto_tester/AGENTS.md`
- Modify: `workspace-acpx_auto_tester/config/README.md`
- Modify: `workspace-acpx_auto_tester/docs/ACPX_AUTO_TESTER_USAGE.md`
- Modify: `workspace-acpx_auto_tester/docs/statemachine/statemachine.md`

**Interfaces:**
- Consumes: `dispatch_prepare_tick.sh` 返回的 `dispatch_entries[].payload_path` 与 `child_label`。
- Produces: `sessions_spawn(task=<file contents>, label=<child_label>, runtime="subagent", mode="run", cleanup="keep", context="isolated")`；不含逐次 timeout 参数的启动确认。
- Produces: `derive_stuck_after_minutes <acpx_timeout_seconds>`，stdout 为十进制分钟数。
- Produces: `load_state` 与 `fresh_init_state` 均不暴露 `.run_timeout_seconds`。

- [ ] **Step 1: 写派发契约失败测试**

新增 `test_openclaw_spawn_contract.sh`，使用以下完整测试骨架：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${SKILL_DIR}/../.." && pwd)"

fail() { echo "$1" >&2; exit 1; }

grep -Fq 'task=payload,' "${SKILL_DIR}/SKILL.md" || fail "sessions_spawn must pass the rendered text as task"
grep -Fq 'runtime="subagent"' "${SKILL_DIR}/SKILL.md" || fail "sessions_spawn must pin runtime=subagent"
grep -Fq 'mode="run"' "${SKILL_DIR}/SKILL.md" || fail "sessions_spawn must pin mode=run"
grep -Fq 'context="isolated"' "${SKILL_DIR}/SKILL.md" || fail "sessions_spawn must pin isolated context"

for forbidden in \
  'sessions_spawn(payload=' \
  'payload=payload' \
  'timeoutSeconds=' \
  'runTimeoutSeconds='
do
  if rg -n -F "${forbidden}" \
    "${SKILL_DIR}/SKILL.md" \
    "${SKILL_DIR}/references" \
    "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh" \
    "${WORKSPACE_DIR}/CLAUDE.md" \
    "${WORKSPACE_DIR}/SOUL.md" \
    "${WORKSPACE_DIR}/AGENTS.md" \
    "${WORKSPACE_DIR}/docs"; then
    fail "active spawn contract still contains forbidden form: ${forbidden}"
  fi
done

echo "ok acpx_auto_tester uses the OpenClaw 2026.6.11 spawn contract"
```

- [ ] **Step 2: 运行派发契约测试并确认按预期失败**

Run:

```bash
bash workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/tests/test_openclaw_spawn_contract.sh
```

Expected: FAIL，首个失败为 `sessions_spawn must pass the rendered text as task`，证明测试捕获的是现有错误接口。

- [ ] **Step 3: 把所有活跃派发说明改为兼容调用形状**

在 `SKILL.md` 主循环中使用以下完整参数集合，并在重试规则、executor prompt、wrapper 说明、脚本注释、`CLAUDE.md`、`SOUL.md`、`AGENTS.md`、使用文档和状态机中保持一致：

```text
ack = sessions_spawn(
  task=payload,
  label=entry.child_label,
  runtime="subagent",
  mode="run",
  cleanup="keep",
  context="isolated"
)
```

删除所有把 `timeoutSeconds=30` 描述为启动确认等待、或把 `runTimeoutSeconds` 描述为逐次运行上限的内容。保留“三次相同参数重试、两秒退避、同时校验 `runId` 与 `childSessionKey`、严格串行派发”的既有语义。

- [ ] **Step 4: 运行派发契约测试并确认通过**

Run:

```bash
bash workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/tests/test_openclaw_spawn_contract.sh
```

Expected: PASS，输出 `ok acpx_auto_tester uses the OpenClaw 2026.6.11 spawn contract`。

- [ ] **Step 5: 写 timeout 状态迁移失败测试**

新增 `test_timeout_state_migration.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/acpx-timeout-migration.XXXXXX")"

export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign_state.json"
export DISPATCHER_LOG_DIR="${TEST_ROOT}/logs"
export ISSUES_ROOT="${TEST_ROOT}/issues"
export PROJECT_URI="group%2Fproject"
export PROJECT="project"
export REPO_PARENT_PATH="${TEST_ROOT}/repos"
export RESULT_BASENAME="ifp-result"
export DATA_BASENAME="ifp-data"
export UI_ACCOUNTS_RELPATH=""

source "${SKILL_DIR}/scripts/_dispatch_lib.sh"

printf '%s\n' '{"project":"project","run_timeout_seconds":18120}' >"${CAMPAIGN_STATE_FILE}"
load_state | jq -e 'has("run_timeout_seconds") | not' >/dev/null
fresh_init_state | jq -e 'has("run_timeout_seconds") | not' >/dev/null

[ "$(derive_stuck_after_minutes 18000)" = "332" ]
[ "$(derive_stuck_after_minutes 21600)" = "392" ]

grep -Fq 'unsupported trigger field: run_timeout_seconds' \
  "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh"
if rg -n 'run_timeout_seconds:\s*\$|--argjson run_timeout|RUN_TIMEOUT' \
  "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh" \
  "${SKILL_DIR}/scripts/_dispatch_lib.sh"; then
  echo "removed run timeout is still persisted or emitted" >&2
  exit 1
fi

echo "ok acpx_auto_tester removes legacy run timeout state"
```

- [ ] **Step 6: 运行 timeout 状态迁移测试并确认按预期失败**

Run:

```bash
bash workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/tests/test_timeout_state_migration.sh
```

Expected: FAIL，因为 `load_state` 仍返回 `.run_timeout_seconds`，且 `derive_stuck_after_minutes` 尚不存在。

- [ ] **Step 7: 实现旧状态删除与新 stuck 派生公式**

在 `_dispatch_lib.sh` 增加并使用：

```bash
derive_stuck_after_minutes() {
  local acpx_timeout_seconds="$1"
  printf '%s\n' "$(( (acpx_timeout_seconds + 120 + 59) / 60 + 30 ))"
}

load_state() {
  if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
    jq 'del(.run_timeout_seconds)' "${CAMPAIGN_STATE_FILE}"
  else
    fresh_init_state
  fi
}
```

从 `fresh_init_state` 删除 `run_timeout_seconds`。在 `dispatch_prepare_tick.sh` 解析 trigger 后增加：

```bash
if [ "${T[run_timeout_seconds]+present}" = "present" ]; then
  emit_chat_failure "unsupported trigger field: run_timeout_seconds; configure agents.defaults.subagents.runTimeoutSeconds globally if desired"
fi
```

删除 `RUN_TIMEOUT`、`MIN_RUN_TIMEOUT`、逐次 headroom 校验、state merge 参数与 envelope 字段；默认 stuck 改为：

```bash
[ -z "${STUCK_AFTER}" ] && STUCK_AFTER="$(derive_stuck_after_minutes "${ACPX_TIMEOUT}")"
```

state merge 末尾必须包含 `del(.run_timeout_seconds)`，从而兼容同一 tick 内加载的旧对象。`dispatch_followup.sh` 只把“运行时逐次 timeout”措辞改成“运行时终止或内部 timeout”，不改变基于 `acpx_timeout_seconds` 的分类代码。

- [ ] **Step 8: 同步 timeout 文档、部署说明和技能版本**

在 trigger、state、wrapper、prompt、使用文档中删除 `run_timeout_seconds` 的正向字段定义；把 stuck 默认公式改为 `ceil((acpx_timeout_seconds + 120) / 60) + 30`。在 `config/README.md` 增加以下可选部署说明：

```text
OpenClaw 2026.6.11 不接受逐次 timeout 参数。部署可不设置
agents.defaults.subagents.runTimeoutSeconds，或设为 0；若设置正数，建议至少为
acpx_timeout_seconds + 120。该配置不由 agent 自动写入。
```

把 `SKILL.md` 中的版本标记改为 `SKILL_VERSION=2026-07-10.1`。

- [ ] **Step 9: 运行 acpx 工作区测试和静态检查**

Run:

```bash
find workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/tests -type f -name '*.sh' -exec bash {} \;
git diff --check -- workspace-acpx_auto_tester
```

Expected: 两个测试均 PASS；`git diff --check` 无输出。

- [ ] **Step 10: 提交 acpx 工作区改动**

```bash
git add workspace-acpx_auto_tester
git commit -F - <<'COMMIT_EOF'
修复：兼容 OpenClaw 子代理派发参数

背景：
- OpenClaw 2026.6.11 要求 sessions_spawn 使用 task，并拒绝逐次 timeout 参数。

变更：
- 统一匿名 run-mode 派发契约，删除 run_timeout_seconds 状态与触发接口。
- 保留 acpx 内部超时，并从该预算派生 stuck 默认值。
- 增加派发契约和旧状态迁移回归测试。

Codex 标注：
- 本提交由 Codex 生成并执行。

注意：
- 全局子代理运行上限仍是可选部署项，不由 agent 强制设置。

本次改动由 Codex 生成。

Co-Authored-By: Codex Opus 4.7 <noreply@anthropic.com>
COMMIT_EOF
```

---

### Task 2: 修复 `workspace-req_executor` 子代理派发与单 issue timeout 接口

**Files:**
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_openclaw_spawn_contract.sh`
- Create: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_timeout_state_migration.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_executor_prompt_generic_issue.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_dispatch_single_issue_minimal_config.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/SKILL.md`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/_dispatch_lib.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_prepare_tick.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_followup.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/scripts/dispatch_single_issue.sh`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/executor_prompt.md`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/state_schema.md`
- Modify: `workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/references/trigger_command.md`
- Modify: `workspace-req_executor/config/README.md`
- Modify: `workspace-req_executor/docs/REQ_EXECUTOR_USAGE.md`

**Interfaces:**
- Consumes: `dispatch_prepare_tick.sh` 返回的 `dispatch_entries[].payload_path` 与 `child_label`。
- Produces: `sessions_spawn(task=<file contents>, label=<child_label>, runtime="subagent", mode="run", cleanup="keep", context="isolated")`。
- Produces: `RUN_SINGLE_ISSUE` 合成 trigger 中不存在 `run_timeout_seconds`。

- [ ] **Step 1: 写 req_executor 派发契约失败测试**

新增 `test_openclaw_spawn_contract.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${SKILL_DIR}/../.." && pwd)"

fail() { echo "$1" >&2; exit 1; }

grep -Fq 'task=payload,' "${SKILL_DIR}/SKILL.md" || fail "sessions_spawn must pass the rendered text as task"
grep -Fq 'runtime="subagent"' "${SKILL_DIR}/SKILL.md" || fail "sessions_spawn must pin runtime=subagent"
grep -Fq 'mode="run"' "${SKILL_DIR}/SKILL.md" || fail "sessions_spawn must pin mode=run"
grep -Fq 'context="isolated"' "${SKILL_DIR}/SKILL.md" || fail "sessions_spawn must pin isolated context"

for forbidden in \
  'sessions_spawn(payload=' \
  'payload=payload' \
  'timeoutSeconds=' \
  'runTimeoutSeconds='
do
  if rg -n -F "${forbidden}" \
    "${SKILL_DIR}/SKILL.md" \
    "${SKILL_DIR}/references" \
    "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh" \
    "${WORKSPACE_DIR}/docs/REQ_EXECUTOR_USAGE.md"; then
    fail "active spawn contract still contains forbidden form: ${forbidden}"
  fi
done

echo "ok req_executor uses the OpenClaw 2026.6.11 spawn contract"
```

同时在 `test_executor_prompt_generic_issue.sh` 增加正向断言：完整 `SKILL.md` 必须包含 `task=payload`；完整 `executor_prompt.md` 不得包含 `timeoutSeconds=`、`runTimeoutSeconds=` 或 `sessions_spawn(payload=`。

- [ ] **Step 2: 运行派发契约测试并确认按预期失败**

Run:

```bash
bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_openclaw_spawn_contract.sh
bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_executor_prompt_generic_issue.sh
```

Expected: 至少一个测试因缺失 `task=payload` 失败，另一个测试报告旧逐次 timeout 调用形状。

- [ ] **Step 3: 修改 req_executor 派发契约**

把 `SKILL.md` 主循环改为以下六参数调用：

```text
ack = sessions_spawn(
  task=payload,
  label=entry.child_label,
  runtime="subagent",
  mode="run",
  cleanup="keep",
  context="isolated"
)
```

同步 `executor_prompt.md` 和 `dispatch_prepare_tick.sh` 注释；保留串行、三次相同参数重试和启动确认字段校验。

- [ ] **Step 4: 运行派发契约测试并确认通过**

Run:

```bash
bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_openclaw_spawn_contract.sh
bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_executor_prompt_generic_issue.sh
```

Expected: 两个测试均 PASS。

- [ ] **Step 5: 写 timeout 状态与单 issue 删除接口失败测试**

新增 `test_timeout_state_migration.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/req-executor-timeout-migration.XXXXXX")"

export CAMPAIGN_STATE_FILE="${TEST_ROOT}/campaign_state.json"
export DISPATCHER_LOG_DIR="${TEST_ROOT}/logs"
export ISSUES_ROOT="${TEST_ROOT}/issues"
export PROJECT_URI="group%2Fproject"
export PROJECT="project"
export REPO_PARENT_PATH="${TEST_ROOT}/repos"

source "${SKILL_DIR}/scripts/_dispatch_lib.sh"

printf '%s\n' '{"project":"project","run_timeout_seconds":18120}' >"${CAMPAIGN_STATE_FILE}"
load_state | jq -e 'has("run_timeout_seconds") | not' >/dev/null
fresh_init_state | jq -e 'has("run_timeout_seconds") | not' >/dev/null

[ "$(derive_stuck_after_minutes 18000)" = "332" ]
[ "$(derive_stuck_after_minutes 21600)" = "392" ]

grep -Fq 'unsupported trigger field: run_timeout_seconds' \
  "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh"
if rg -n 'run_timeout_seconds:\s*\$|--argjson run_timeout|RUN_TIMEOUT' \
  "${SKILL_DIR}/scripts/dispatch_prepare_tick.sh" \
  "${SKILL_DIR}/scripts/_dispatch_lib.sh"; then
  echo "removed run timeout is still persisted or emitted" >&2
  exit 1
fi
if rg -n 'RUN_TIMEOUT|run_timeout_seconds=' \
  "${SKILL_DIR}/scripts/dispatch_single_issue.sh"; then
  echo "RUN_SINGLE_ISSUE still synthesizes removed run timeout" >&2
  exit 1
fi

echo "ok req_executor removes legacy run timeout state"
```

在 `test_dispatch_single_issue_minimal_config.sh` 增加：

```bash
if grep -q '^run_timeout_seconds=' "${TEST_ROOT}/stdout"; then
  echo "synthesized trigger must not expose run_timeout_seconds" >&2
  exit 1
fi
```

- [ ] **Step 6: 运行 timeout 测试并确认按预期失败**

Run:

```bash
bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_timeout_state_migration.sh
```

Expected: FAIL，因为状态仍包含旧字段、派生函数不存在，且 `dispatch_single_issue.sh` 仍包含 `RUN_TIMEOUT_EFF`。

- [ ] **Step 7: 实现 req_executor timeout 状态迁移**

在 `_dispatch_lib.sh` 增加：

```bash
derive_stuck_after_minutes() {
  local acpx_timeout_seconds="$1"
  printf '%s\n' "$(( (acpx_timeout_seconds + 120 + 59) / 60 + 30 ))"
}

load_state() {
  if [ -f "${CAMPAIGN_STATE_FILE}" ]; then
    jq 'del(.run_timeout_seconds)' "${CAMPAIGN_STATE_FILE}"
  else
    fresh_init_state
  fi
}
```

从 `fresh_init_state` 删除旧字段。在 `dispatch_prepare_tick.sh` 解析 trigger 后增加：

```bash
if [ "${T[run_timeout_seconds]+present}" = "present" ]; then
  emit_chat_failure "unsupported trigger field: run_timeout_seconds; configure agents.defaults.subagents.runTimeoutSeconds globally if desired"
fi
```

删除 `RUN_TIMEOUT`、`MIN_RUN_TIMEOUT`、逐次 headroom 校验、state merge 参数和 envelope 字段；默认 stuck 使用：

```bash
[ -z "${STUCK_AFTER}" ] && STUCK_AFTER="$(derive_stuck_after_minutes "${ACPX_TIMEOUT}")"
```

state merge 末尾增加 `del(.run_timeout_seconds)`。从 `dispatch_single_issue.sh` 删除：

```bash
RUN_TIMEOUT_EFF=""
[ -n "${RUN_TIMEOUT_EFF}" ] && SYNTH_TRIGGER="${SYNTH_TRIGGER}"$'\n'"run_timeout_seconds=${RUN_TIMEOUT_EFF}"
```

保留 `ACPX_TIMEOUT_EFF=18000` 和生成的 `acpx_timeout_seconds=`。

- [ ] **Step 8: 同步 req_executor 文档和技能版本**

从 trigger、state 和使用文档删除旧字段定义；记录可选的 `agents.defaults.subagents.runTimeoutSeconds` 部署建议，但不得把它写进 `campaign_defaults.env`。把 `SKILL.md` 版本更新为 `SKILL_VERSION=2026-07-10.1`。

- [ ] **Step 9: 运行 req_executor 全量测试**

Run:

```bash
find workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests -type f -name '*.sh' -exec bash {} \;
git diff --check -- workspace-req_executor
```

Expected: 所有 shell 测试 PASS；蓝区配置安全测试仍确认 `/data`、GitLab pin 和 token 约定未改变；`git diff --check` 无输出。

- [ ] **Step 10: 提交 req_executor 改动**

```bash
git add workspace-req_executor
git commit -F - <<'COMMIT_EOF'
修复：更新 req_executor 子代理派发契约

背景：
- req_executor 首次派发会因 OpenClaw 不支持逐次 timeout 参数而在启动前失败。

变更：
- 改用 task 传递外层执行提示，并固定匿名 run-mode 参数。
- 删除 run_timeout_seconds 的状态、trigger、envelope 和单 issue 合成逻辑。
- 增加派发契约、状态迁移与最小配置回归测试。

Codex 标注：
- 本提交由 Codex 生成并执行。

注意：
- campaign_defaults.env 仍只保存 clone parent，不加入工作站或运行时 timeout 配置。

本次改动由 Codex 生成。

Co-Authored-By: Codex Opus 4.7 <noreply@anthropic.com>
COMMIT_EOF
```

---

### Task 3: 同步 `workspace-req_dispatcher` 跨工作区契约

**Files:**
- Create: `workspace-req_dispatcher/skills/requirement_dispatch/tests/test_openclaw_subagent_contract_docs.sh`
- Modify: `workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md`
- Modify: `workspace-req_dispatcher/config/README.md`
- Modify: `workspace-req_dispatcher/docs/superpowers/specs/2026-06-25-req_dispatcher-design.md`
- Modify: `workspace-req_dispatcher/docs/superpowers/plans/2026-06-25-req_dispatcher.md`
- Modify: `workspace-req_dispatcher/docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md`
- Modify: `workspace-req_dispatcher/docs/superpowers/plans/2026-06-29-req_dispatcher-active-orchestration.md`

**Interfaces:**
- Consumes: 当前 `run_agent_turn.sh` 的 `openclaw agent --agent ... --session-key ... --message ... --timeout ...` 调用，不修改实现。
- Produces: 清晰区分 req_dispatcher CLI timeout 与 req_executor 内部子代理可选全局 timeout 的部署说明。

- [ ] **Step 1: 写跨工作区文档契约失败测试**

新增：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${SKILL_DIR}/../.." && pwd)"

fail() { echo "$1" >&2; exit 1; }

if grep -Fq 'sessions_spawn' "${SKILL_DIR}/SKILL.md"; then
  fail "req_dispatcher runtime skill must not call sessions_spawn"
fi
grep -Fq 'openclaw agent --timeout' "${WORKSPACE_DIR}/config/README.md" || \
  fail "deployment docs must preserve the req_dispatcher CLI timeout"
grep -Fq 'agents.defaults.subagents.runTimeoutSeconds' "${WORKSPACE_DIR}/config/README.md" || \
  fail "deployment docs must describe the optional downstream subagent timeout"

for historical in \
  "${WORKSPACE_DIR}/docs/superpowers/specs/2026-06-25-req-dispatcher-design.md" \
  "${WORKSPACE_DIR}/docs/superpowers/plans/2026-06-25-req-dispatcher.md" \
  "${WORKSPACE_DIR}/docs/superpowers/specs/2026-06-29-req-dispatcher-active-orchestration-design.md" \
  "${WORKSPACE_DIR}/docs/superpowers/plans/2026-06-29-req-dispatcher-active-orchestration.md"
do
  grep -Fq '2026-07-10 兼容性说明' "${historical}" || \
    fail "historical orchestration doc lacks compatibility notice: ${historical}"
done

echo "ok req_dispatcher distinguishes CLI and subagent timeout contracts"
```

- [ ] **Step 2: 运行文档契约测试并确认按预期失败**

Run:

```bash
bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_openclaw_subagent_contract_docs.sh
```

Expected: FAIL，原因是 `config/README.md` 尚未说明可选全局子代理 timeout，历史设计也没有兼容性标记。

- [ ] **Step 3: 更新历史和当前部署说明**

在四个历史设计／计划顶部加入：

```markdown
> **2026-07-10 兼容性说明：** 本文记录历史决策，不再作为当前运行时调用契约。req_dispatcher 当前通过 `openclaw agent --agent ... --session-key ... --message ... --timeout ...` 调用命名下游 agent；它不调用 `sessions_spawn`。req_executor 内部若派发匿名子代理，任务正文使用 `task`，不传逐次 timeout 参数。
```

在 2026-06-29 当前跨工作区流程段落补充兼容调用形状；在 `config/README.md` 部署检查中明确：

```text
req_dispatcher 的 EXECUTOR_AGENT_TIMEOUT_SECONDS 继续控制 openclaw agent CLI 等待；
它与 agents.defaults.subagents.runTimeoutSeconds 不是同一参数。后者只影响
req_executor 内部子代理，允许缺失或为 0，若为正数建议至少覆盖
acpx_timeout_seconds + 120。
```

只把 `SKILL.md` 版本标记更新为 `SKILL_VERSION=2026-07-10.1`，不添加 `sessions_spawn` allowed-tool。

- [ ] **Step 4: 运行 req_dispatcher 文档及运行时回归测试**

Run:

```bash
bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_openclaw_subagent_contract_docs.sh
bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_run_agent_turn_openclaw.sh
bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_queue_drain.sh
bash workspace-req_dispatcher/skills/requirement_dispatch/tests/test_executor_queue_launch_failure_retries.sh
git diff --check -- workspace-req_dispatcher
```

Expected: 全部 PASS；CLI 测试继续证明 `--timeout` 被传递；`git diff --check` 无输出。

- [ ] **Step 5: 提交 req_dispatcher 改动**

```bash
git add workspace-req_dispatcher
git commit -F - <<'COMMIT_EOF'
文档：对齐 req_dispatcher 与子代理超时边界

背景：
- 历史设计仍把 sessions_spawn 描述为命名下游 agent 调用原语，容易误导后续修改。

变更：
- 标记已被 CLI 实现取代的历史契约，并补充 req_executor 子代理兼容参数。
- 明确保留 openclaw agent --timeout，区分可选的全局子代理运行上限。
- 增加跨工作区文档契约测试并更新技能版本。

Codex 标注：
- 本提交由 Codex 生成并执行。

注意：
- req_dispatcher 运行时代码未改用 sessions_spawn，队列和 CLI 超时语义保持不变。

本次改动由 Codex 生成。

Co-Authored-By: Codex Opus 4.7 <noreply@anthropic.com>
COMMIT_EOF
```

---

### Task 4: 跨工作区全量验证

**Files:**
- Verify: `workspace-acpx_auto_tester/**`
- Verify: `workspace-req_executor/**`
- Verify: `workspace-req_dispatcher/**`

**Interfaces:**
- Consumes: Tasks 1–3 的三个独立提交。
- Produces: 可部署的统一 OpenClaw 2026.6.11 契约和干净工作树。

- [ ] **Step 1: 运行三个工作区全部 shell 测试**

Run:

```bash
find workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/tests -type f -name '*.sh' -exec bash {} \;
find workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests -type f -name '*.sh' -exec bash {} \;
find workspace-req_dispatcher/skills/requirement_dispatch/tests -type f -name '*.sh' -exec bash {} \;
```

Expected: 每个测试以 `ok` 或零退出码结束，无失败堆栈。

- [ ] **Step 2: 检查活跃调用中没有旧参数**

Run:

```bash
rg -n 'sessions_spawn\(payload=|payload=payload|timeoutSeconds=|runTimeoutSeconds=' \
  workspace-acpx_auto_tester workspace-req_executor
```

Expected: 无输出。可选全局配置完整路径 `agents.defaults.subagents.runTimeoutSeconds` 不匹配这些逐次赋值模式。

- [ ] **Step 3: 检查 `run_timeout_seconds` 只剩迁移与拒绝代码**

Run:

```bash
rg -n 'run_timeout_seconds' workspace-acpx_auto_tester workspace-req_executor
```

Expected: 仅允许出现于旧 trigger 拒绝、`del(.run_timeout_seconds)` 迁移和对应测试；不得出现在 `SKILL.md`、trigger/state schema、使用文档、state 初始化或 envelope 构造中。

- [ ] **Step 4: 验证技能版本与配置安全**

Run:

```bash
rg -n 'SKILL_VERSION=2026-07-10\.1' \
  workspace-acpx_auto_tester/skills/gitlab_issue_campaign_dispatcher/SKILL.md \
  workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/SKILL.md \
  workspace-req_dispatcher/skills/requirement_dispatch/SKILL.md
bash workspace-req_executor/skills/gitlab_issue_campaign_dispatcher/tests/test_blue_deploy_config_sanity.sh
git diff --check HEAD~3..HEAD
git status --short
```

Expected: 三个版本均命中；蓝区配置测试 PASS；diff check 无输出；工作树干净。
