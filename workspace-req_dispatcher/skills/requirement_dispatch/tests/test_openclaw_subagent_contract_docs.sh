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
grep -Fq '`timeout:21900` 与 `yieldMs:120000`' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must pin a long OpenClaw exec lifetime for synchronous executor intake"
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
grep -Fq 'SKILL_VERSION=2026-07-14.8' "${SKILL_DIR}/SKILL.md" \
  || fail "req_dispatcher skill version must match the current release version"
grep -Fq '/acpx-timeout <时长>' "${SKILL_DIR}/SKILL.md" \
  || fail "dispatcher skill must route runtime acpx timeout commands"
grep -Fq 'STUCK_AFTER_MINUTES=390' "${WORKSPACE_DIR}/config/dispatcher.env" \
  || fail "dispatcher stuck eviction must outlive the executor timeout chain"
grep -Fq 'EXECUTOR_AGENT_TIMEOUT_SECONDS=21600' "${WORKSPACE_DIR}/config/dispatcher.env" \
  || fail "executor agent turn must outlive the default acpx and finalization budget"
grep -Fq 'EXECUTOR_QUEUE_LAUNCH_RECLAIM_SECONDS=22200' "${WORKSPACE_DIR}/config/dispatcher.env" \
  || fail "legacy queue reclaim must outlive the executor agent turn and exec wrapper"
grep -Fq '`/acpx-timeout` 允许调回最大 18000 秒' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must preserve the maximum runtime acpx timeout"
grep -Fq '当前仍应设为 `20400`' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must cover maximum acpx plus finalization in the global subagent timeout"
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
