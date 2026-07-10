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
grep -Fq 'SKILL_VERSION=2026-07-10.5' "${SKILL_DIR}/SKILL.md" \
  || fail "req_dispatcher skill version must be bumped from the current same-day version"

for historical in \
  "${WORKSPACE_DIR}/docs/superpowers/specs/2026-06-25-req_dispatcher-design.md" \
  "${WORKSPACE_DIR}/docs/superpowers/plans/2026-06-25-req_dispatcher.md" \
  "${WORKSPACE_DIR}/docs/superpowers/specs/2026-06-29-req_dispatcher-active-orchestration-design.md" \
  "${WORKSPACE_DIR}/docs/superpowers/plans/2026-06-29-req_dispatcher-active-orchestration.md"
do
  grep -Fq '2026-07-10 兼容性说明' "${historical}" \
    || fail "historical orchestration doc lacks compatibility notice: ${historical}"
done

echo "ok req_dispatcher distinguishes CLI and subagent timeout contracts"
