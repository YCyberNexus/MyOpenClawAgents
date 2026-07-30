#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${SKILL_DIR}/../.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

if grep -Fq 'sessions_spawn' "${SKILL_DIR}/SKILL.md"; then
  fail "req_dispatcher runtime skill must not call sessions_spawn"
fi
grep -Fq 'RUN_DRIVEN_BATCH_RESULT_ACK_ONLY' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must route the ack-only callback marker"
grep -Fq 'ack_instruction=只调用 handle_executor_batch_event.sh；不得写任何临时文件；最终 assistant 内容必须逐字等于其唯一一行 stdout JSON；禁止任何前后缀、prose、Markdown、解释或总结。' \
  "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must include the exact third-line callback instruction"
grep -Fq '最终 assistant 内容必须严格等于' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must require an exact handler stdout final response"
grep -Fq '禁止添加任何前后缀、Markdown' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "dispatcher agent rules must forbid callback ack prose and Markdown"
grep -Fq "<<'CALLBACK_EOF'" "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "dispatcher agent rules must require the fixed callback stdin heredoc"
grep -Fq '不得把 callback 或 nonce' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "dispatcher agent rules must forbid temporary callback files"
grep -Fq '旧 `RUN_DRIVEN_BATCH_RESULT` 首行继续兼容' "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "dispatcher agent rules must preserve the old callback marker"
grep -Fq 'openclaw agent --timeout' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must preserve the req_dispatcher CLI timeout"
grep -Fq '`timeout:<exec_tool_timeout_seconds>` 与 `yieldMs:120000`' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must use the runtime-derived OpenClaw exec lifetime"
grep -Fq 'get_executor_timeout_budget.sh' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must resolve the timeout budget before executor intake"
grep -Fq 'source scripts/source_executor_timeout_budget.sh' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher execution and recovery must load the runtime timeout budget"
grep -Fq '回调路径只加载基础部署配置' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher callback handling must remain independent of executor timeout state"
grep -Fq '禁止再次调用 `submit_executor_batch.sh`' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must not allocate a second batch after an ambiguous exec result"
grep -Fq 'agents.defaults.subagents.runTimeoutSeconds' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must describe the optional downstream subagent timeout"
grep -Fq '仅允许 `agent:req_dispatcher:<safe-session>`' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must pin callback delivery to req_dispatcher and a safe session"
grep -Fq '`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must define the safe callback session grammar"
if grep -Fq '或裸 agent 名' "${WORKSPACE_DIR}/config/README.md"; then
  fail "deployment docs must not advertise an unpinned bare callback agent"
fi
grep -Fq 'SKILL_VERSION=2026-07-30.1' "${SKILL_DIR}/SKILL.md" \
  || fail "req_dispatcher skill version must match the current release version"
grep -Fq 'agent:req_dispatcher:intake-<origin_sha256>' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must document origin-scoped intake sessions"
grep -Fq '`reply_agent + conversation + user` 三元组取 SHA-256' \
  "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "dispatcher agent rules must define the intake session identity tuple"
grep -Fq '`agent:req_dispatcher:main`；只作为 executor callback、恢复 tick' \
  "${WORKSPACE_DIR}/AGENTS.md" \
  || fail "dispatcher agent rules must reserve main for the control plane"
[ "$(cat "${WORKSPACE_DIR}/HEARTBEAT.md")" = 'RUN_EXECUTOR_BATCH_TICK' ] \
  || fail "dispatcher deployment artifact must keep batch recovery heartbeat active"
grep -Fq '完整原请求逐字保留' "${SKILL_DIR}/SKILL.md" \
  || fail "create_and_execute must preserve the complete original request"
grep -Fq '否则会丢失“完成后直接合并”及其否定语义' "${SKILL_DIR}/SKILL.md" \
  || fail "create_and_execute must document automatic-merge intent preservation"
grep -Fq '/timeout-executor <时长>' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must route runtime acpx timeout commands"
if grep -Eq '/(acpx-timeout|executor-timeout)' "${SKILL_DIR}/SKILL.md"; then
  fail "dispatcher skill must not use superseded timeout commands"
fi
grep -Fq 'EXECUTOR_SCHEDULER_STATE_FILE=/data/req_executor/_scheduler/scheduler_state.json' \
  "${WORKSPACE_DIR}/config/dispatcher.env" \
  || fail "dispatcher must derive timeout budgets from executor scheduler state"
grep -Fq 'STUCK_AFTER_MINUTES=150' "${WORKSPACE_DIR}/config/dispatcher.env" \
  || fail "default dispatcher stuck eviction must match the one-hour acpx budget"
grep -Fq 'EXECUTOR_AGENT_TIMEOUT_SECONDS=7200' "${WORKSPACE_DIR}/config/dispatcher.env" \
  || fail "default executor agent turn must match the one-hour acpx budget"
grep -Fq 'EXECUTOR_EXEC_TOOL_TIMEOUT_SECONDS=7500' "${WORKSPACE_DIR}/config/dispatcher.env" \
  || fail "default exec tool timeout must match the one-hour acpx budget"
grep -Fq 'EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS=7800' "${WORKSPACE_DIR}/config/dispatcher.env" \
  || fail "default legacy queue reclaim must match the one-hour acpx budget"
grep -Fq '`/timeout-executor` 允许调回最大 18000 秒' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must preserve the maximum runtime acpx timeout"
grep -Fq '仍应独立保持 `20400`' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must cover maximum acpx plus finalization in the global subagent timeout"
grep -Fq '命令不得修改' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must not mutate the OpenClaw global timeout"
grep -Fq 'openclaw config set agents.defaults.subagents.runTimeoutSeconds 20400 --strict-json' \
  "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must provide the effective OpenClaw timeout fix"

for historical in \
  "${WORKSPACE_DIR}/docs/superpowers/specs/2026-06-25-req_dispatcher-design.md" \
  "${WORKSPACE_DIR}/docs/superpowers/plans/2026-06-25-req_dispatcher.md" \
  "${WORKSPACE_DIR}/docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md" \
  "${WORKSPACE_DIR}/docs/superpowers/plans/2026-06-29-req_dispatcher-active-orchestration.md"
do
  [ ! -e "${historical}" ] ||
  grep -Fq '2026-07-10 兼容性说明' "${historical}" \
    || fail "historical orchestration doc lacks compatibility notice: ${historical}"
done

for active_doc in \
  "${WORKSPACE_DIR}/docs/integration/result_notify_loop.md" \
  "${WORKSPACE_DIR}/docs/integration/gitissuer_change_request.md"
do
  if grep -Fq '../superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md' \
      "${active_doc}"; then
    fail "active integration doc links to a deleted orchestration design: ${active_doc}"
  fi
done

echo "ok req_dispatcher distinguishes CLI and subagent timeout contracts"
