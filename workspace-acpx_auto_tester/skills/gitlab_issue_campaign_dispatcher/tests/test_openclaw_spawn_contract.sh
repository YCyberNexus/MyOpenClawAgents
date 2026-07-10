#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${SKILL_DIR}/../.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

grep -Fq 'task=payload,' "${SKILL_DIR}/SKILL.md" \
  || fail "sessions_spawn must pass the rendered text as task"
grep -Fq 'runtime="subagent"' "${SKILL_DIR}/SKILL.md" \
  || fail "sessions_spawn must pin runtime=subagent"
grep -Fq 'mode="run"' "${SKILL_DIR}/SKILL.md" \
  || fail "sessions_spawn must pin mode=run"
grep -Fq 'context="isolated"' "${SKILL_DIR}/SKILL.md" \
  || fail "sessions_spawn must pin isolated context"

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
