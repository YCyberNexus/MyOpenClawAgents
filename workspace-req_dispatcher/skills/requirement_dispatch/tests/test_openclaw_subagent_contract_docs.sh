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
grep -Fq 'openclaw agent --timeout' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must preserve the req_dispatcher CLI timeout"
grep -Fq 'agents.defaults.subagents.runTimeoutSeconds' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must describe the optional downstream subagent timeout"
grep -Fq '仅允许 `agent:req_dispatcher:<safe-session>`' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must pin callback delivery to req_dispatcher and a safe session"
grep -Fq '`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`' "${WORKSPACE_DIR}/config/README.md" \
  || fail "deployment docs must define the safe callback session grammar"
if grep -Fq '或裸 agent 名' "${WORKSPACE_DIR}/config/README.md"; then
  fail "deployment docs must not advertise an unpinned bare callback agent"
fi
grep -Fq 'SKILL_VERSION=2026-07-13.4' "${SKILL_DIR}/SKILL.md" \
  || fail "req_dispatcher skill version must match the current release version"

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
